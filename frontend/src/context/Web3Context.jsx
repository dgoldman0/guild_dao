import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import { BrowserProvider, Contract } from "ethers";
import { DAO_ABI, GOVERNANCE_ABI, TREASURY_ABI, FEE_ROUTER_ABI } from "../contracts/abis";
import { getAddresses } from "../contracts/config";
import { EPOCH_SECONDS } from "../lib/constants";
import { decodeContractError } from "../lib/errors";

const Web3Ctx = createContext(null);

export function useWeb3() {
  return useContext(Web3Ctx);
}

export function Web3Provider({ children }) {
  const [account, setAccount] = useState(null);
  const [chainId, setChainId] = useState(null);
  const [provider, setProvider] = useState(null);
  const [signer, setSigner] = useState(null);
  const [error, setError] = useState(null);

  // ── Contracts ────────────────────────────────
  const [dao, setDao] = useState(null);
  const [governance, setGovernance] = useState(null);
  const [treasury, setTreasury] = useState(null);
  const [feeRouter, setFeeRouter] = useState(null);

  // ── Current user membership ──────────────────
  const [myMemberId, setMyMemberId] = useState(0);
  const [myMember, setMyMember] = useState(null);
  const [myPower, setMyPower] = useState(0n);
  const [myFeePaidUntil, setMyFeePaidUntil] = useState(0n);
  const [myActive, setMyActive] = useState(false);

  // ── DAO aggregate state ──────────────────────
  const [daoState, setDaoState] = useState({
    epoch: 0n,
    memberCount: 0,
    totalPower: 0n,
    votingPeriod: 0n,
    quorumBps: 0,
    orderDelay: 0n,
    inviteExpiry: 0n,
    executionDelay: 0n,
    feeToken: null,
    baseFee: 0n,
    gracePeriod: 0n,
    payoutTreasury: null,
    bootstrapFinalized: false,
  });

  // ── Loading / notification state ─────────────
  const [loading, setLoading] = useState(false);
  const [toast, setToast] = useState(null);

  const showToast = useCallback((msg, type = "info", extra = null) => {
    setToast({ msg, type, ...extra });
    // errors stay longer, can also be dismissed manually
    const delay = type === "error" ? 10000 : 4000;
    const timer = setTimeout(() => setToast(null), delay);
    // store dismiss fn so the toast can be closed early
    setToast((prev) => prev ? { ...prev, dismiss: () => { clearTimeout(timer); setToast(null); } } : null);
  }, []);

  // ── Connect wallet ───────────────────────────
  const connect = useCallback(async () => {
    if (!window.ethereum) {
      setError("MetaMask not detected");
      return;
    }
    try {
      setLoading(true);
      const prov = new BrowserProvider(window.ethereum);
      const accounts = await prov.send("eth_requestAccounts", []);
      const network = await prov.getNetwork();
      const s = await prov.getSigner();

      setProvider(prov);
      setSigner(s);
      setAccount(accounts[0]);
      setChainId(Number(network.chainId));
      setError(null);
    } catch (e) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  }, []);

  const disconnect = useCallback(() => {
    setAccount(null);
    setSigner(null);
    setProvider(null);
    setDao(null);
    setGovernance(null);
    setTreasury(null);
    setFeeRouter(null);
    setMyMemberId(0);
    setMyMember(null);
  }, []);

  // ── Listen for account / chain changes ───────
  useEffect(() => {
    if (!window.ethereum) return;
    const onAccounts = (accs) => {
      if (accs.length === 0) disconnect();
      else setAccount(accs[0]);
    };
    const onChain = (hex) => setChainId(Number(hex));
    window.ethereum.on("accountsChanged", onAccounts);
    window.ethereum.on("chainChanged", onChain);
    return () => {
      window.ethereum.removeListener("accountsChanged", onAccounts);
      window.ethereum.removeListener("chainChanged", onChain);
    };
  }, [disconnect]);

  // ── Build contract instances when chain changes ─
  useEffect(() => {
    if (!signer || !chainId) return;
    const addrs = getAddresses(chainId);
    if (!addrs) {
      setError(`Unsupported chain (${chainId}). Deploy contracts and add addresses to config.js`);
      return;
    }
    const zero = "0x0000000000000000000000000000000000000000";
    if (addrs.dao === zero) {
      setError("Contract addresses not configured. Update frontend/src/contracts/config.js");
      return;
    }
    try {
      setDao(new Contract(addrs.dao, DAO_ABI, signer));
      setGovernance(new Contract(addrs.governance, GOVERNANCE_ABI, signer));
      setTreasury(new Contract(addrs.treasury, TREASURY_ABI, signer));
      setFeeRouter(new Contract(addrs.feeRouter, FEE_ROUTER_ABI, signer));
      setError(null);
    } catch (e) {
      setError(`Contract init failed: ${e.message}`);
    }
  }, [signer, chainId]);

  // ── Load DAO state + current user ────────────
  const refresh = useCallback(async () => {
    if (!dao || !account) return;
    try {
      const [
        epoch, nextId, totalPower, votingPeriod, quorumBps,
        orderDelay, inviteExpiry, executionDelay,
        feeTokenAddr, baseFee, gracePeriod, payoutTreasury, finalized,
      ] = await Promise.all([
        dao.EPOCH(),
        dao.nextMemberId(),
        dao.totalVotingPower(),
        dao.votingPeriod(),
        dao.quorumBps(),
        dao.orderDelay(),
        dao.inviteExpiry(),
        dao.executionDelay(),
        dao.feeToken(),
        dao.baseFee(),
        dao.gracePeriod(),
        dao.payoutTreasury(),
        dao.bootstrapFinalized(),
      ]);

      setDaoState({
        epoch,
        memberCount: Number(nextId) - 1,
        totalPower,
        votingPeriod,
        quorumBps: Number(quorumBps),
        orderDelay,
        inviteExpiry,
        executionDelay,
        feeToken: feeTokenAddr,
        baseFee,
        gracePeriod,
        payoutTreasury,
        bootstrapFinalized: finalized,
      });

      // Current user
      const memberId = await dao.memberIdByAuthority(account);
      const mid = Number(memberId);
      setMyMemberId(mid);

      if (mid > 0) {
        const [member, power, active, paidUntil] = await Promise.all([
          dao.getMember(mid),
          dao.votingPowerOfMember(mid),
          dao.isMemberActive(mid),
          dao.feePaidUntil(mid),
        ]);
        setMyMember(member);
        setMyPower(power);
        setMyActive(active);
        setMyFeePaidUntil(paidUntil);
      } else {
        setMyMember(null);
        setMyPower(0n);
        setMyActive(false);
        setMyFeePaidUntil(0n);
      }
    } catch (e) {
      console.error("refresh error:", e);
    }
  }, [dao, account]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  // ── Tx helper ────────────────────────────────
  const sendTx = useCallback(
    async (label, txPromise) => {
      try {
        setLoading(true);
        showToast(`Sending ${label}…`, "info");
        const tx = await txPromise;
        showToast(`Confirming ${label}…`, "info");
        await tx.wait();
        showToast(`${label} confirmed!`, "success");
        await refresh();
        return tx;
      } catch (e) {
        const decoded = decodeContractError(e);
        showToast(`${label} failed`, "error", {
          errorTitle: decoded.title,
          errorHint: decoded.hint,
          errorRaw: decoded.raw ?? null,
          errorSignature: decoded.signature ?? null,
        });
        console.error(`[${label}]`, decoded.title, "—", decoded.hint, e);
        return null;
      } finally {
        setLoading(false);
      }
    },
    [refresh, showToast]
  );

  const value = useMemo(
    () => ({
      account,
      chainId,
      provider,
      signer,
      dao,
      governance,
      treasury,
      feeRouter,
      myMemberId,
      myMember,
      myPower,
      myActive,
      myFeePaidUntil,
      daoState,
      loading,
      error,
      toast,
      isConnected: !!account,
      isMember: myMemberId > 0,
      connect,
      disconnect,
      refresh,
      sendTx,
      showToast,
    }),
    [
      account, chainId, provider, signer,
      dao, governance, treasury, feeRouter,
      myMemberId, myMember, myPower, myActive, myFeePaidUntil,
      daoState, loading, error, toast,
      connect, disconnect, refresh, sendTx, showToast,
    ]
  );

  return <Web3Ctx.Provider value={value}>{children}</Web3Ctx.Provider>;
}
