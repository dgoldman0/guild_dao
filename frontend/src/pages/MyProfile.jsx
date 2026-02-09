import { useEffect, useState, useCallback } from "react";
import { RefreshCw, Send, CreditCard, KeyRound, UserPlus, AlertTriangle } from "lucide-react";
import { Contract, parseEther, ZeroAddress } from "ethers";
import { useWeb3 } from "../context/Web3Context";
import { RankBadgeLarge } from "../components/RankBadge";
import Modal from "../components/Modal";
import {
  shortAddress, rankName, formatETH, formatDate, formatPower,
  formatTimeRemaining, formatTokens,
} from "../lib/format";
import { EPOCH_SECONDS, RANK_NAMES } from "../lib/constants";
import { ERC20_ABI } from "../contracts/abis";

export default function MyProfile() {
  const {
    isConnected, isMember, dao, governance, feeRouter, signer,
    myMember, myMemberId, myPower, myActive, myFeePaidUntil,
    daoState, account, sendTx, refresh,
  } = useWeb3();

  const [showPayFee, setShowPayFee] = useState(false);
  const [showAuthority, setShowAuthority] = useState(false);
  const [showInvite, setShowInvite] = useState(false);
  const [newAuthority, setNewAuthority] = useState("");
  const [inviteAddress, setInviteAddress] = useState("");
  const [feeTokenInfo, setFeeTokenInfo] = useState(null);
  const [feeAmount, setFeeAmount] = useState(0n);
  const [allowance, setAllowance] = useState(0n);
  const [now, setNow] = useState(Math.floor(Date.now() / 1000));

  // Invites state
  const [invites, setInvites] = useState([]);

  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 30000);
    return () => clearInterval(t);
  }, []);

  // Load fee info
  useEffect(() => {
    if (!dao || !isMember || !myMember || !signer) return;
    (async () => {
      try {
        const fee = await dao.feeOfRank(Number(myMember.rank));
        setFeeAmount(fee);

        const tokenAddr = daoState.feeToken;
        if (tokenAddr && tokenAddr !== ZeroAddress) {
          const erc20 = new Contract(tokenAddr, ERC20_ABI, signer);
          const [name, symbol, decimals, allow] = await Promise.all([
            erc20.name(),
            erc20.symbol(),
            erc20.decimals(),
            erc20.allowance(account, await feeRouter.getAddress()),
          ]);
          setFeeTokenInfo({ name, symbol, decimals: Number(decimals), address: tokenAddr });
          setAllowance(allow);
        } else {
          setFeeTokenInfo(null);
          setAllowance(0n);
        }
      } catch (e) {
        console.error("fee info:", e);
      }
    })();
  }, [dao, isMember, myMember, signer, daoState.feeToken, account, feeRouter]);

  // Load user's invites
  const loadInvites = useCallback(async () => {
    if (!governance || !myMemberId) return;
    try {
      const nextId = Number(await governance.nextInviteId());
      const results = await Promise.all(
        Array.from({ length: nextId - 1 }, (_, i) => i + 1).map((id) =>
          governance.getInvite(id).then((inv) => ({ ...inv, _id: id })).catch(() => null)
        )
      );
      setInvites(
        results
          .filter(Boolean)
          .filter((inv) => inv.exists && Number(inv.issuerId) === myMemberId)
          .reverse()
      );
    } catch (e) {
      console.error(e);
    }
  }, [governance, myMemberId]);

  useEffect(() => { loadInvites(); }, [loadInvites]);

  // ── Actions ──────────────────────────────────
  async function handlePayFee() {
    if (!feeRouter || !myMemberId) return;
    const isETH = !feeTokenInfo;

    if (isETH) {
      await sendTx("Pay Fee", feeRouter.payMembershipFee(myMemberId, { value: feeAmount }));
    } else {
      // Check allowance, approve if needed
      if (allowance < feeAmount) {
        const erc20 = new Contract(feeTokenInfo.address, ERC20_ABI, signer);
        await sendTx("Approve Token", erc20.approve(await feeRouter.getAddress(), feeAmount));
      }
      await sendTx("Pay Fee", feeRouter.payMembershipFee(myMemberId));
    }
    setShowPayFee(false);
    refresh();
  }

  async function handleChangeAuthority() {
    await sendTx("Change Authority", dao.changeMyAuthority(newAuthority));
    setShowAuthority(false);
    setNewAuthority("");
    refresh();
  }

  async function handleIssueInvite() {
    await sendTx("Issue Invite", governance.issueInvite(inviteAddress));
    setShowInvite(false);
    setInviteAddress("");
    loadInvites();
  }

  async function handleReclaimInvite(inviteId) {
    await sendTx("Reclaim Invite", governance.reclaimExpiredInvite(inviteId));
    loadInvites();
  }

  if (!isConnected) {
    return <p className="text-gray-500">Connect wallet to view your profile.</p>;
  }

  if (!isMember) {
    return (
      <div className="mx-auto max-w-2xl animate-fade-in space-y-6">
        <h2 className="text-2xl font-bold text-white">My Profile</h2>
        <div className="card text-center py-8">
          <AlertTriangle size={32} className="mx-auto text-gray-600" />
          <p className="mt-3 text-gray-400">You are not a guild member.</p>
          <p className="text-sm text-gray-500">Ask an existing member to send you an invite.</p>
          <p className="mt-2 text-xs text-gray-600 font-mono">{account}</p>
        </div>
      </div>
    );
  }

  const feeRemaining = Number(myFeePaidUntil) - now;
  const isBootstrap = Number(myFeePaidUntil) > 1e15;

  return (
    <div className="mx-auto max-w-4xl animate-fade-in space-y-6">
      <h2 className="text-2xl font-bold text-white">My Profile</h2>

      {/* ── Member card ── */}
      <div className="card">
        <div className="flex items-start gap-5">
          <RankBadgeLarge rank={myMember?.rank ?? 0} />
          <div className="flex-1 space-y-2">
            <h3 className="text-xl font-bold text-white">
              Rank {rankName(myMember?.rank)} — Member #{myMemberId}
            </h3>
            <div className="grid grid-cols-2 gap-x-8 gap-y-1 text-sm">
              <div className="flex justify-between">
                <span className="text-gray-500">Authority</span>
                <span className="font-mono text-gray-300">{shortAddress(myMember?.authority)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-gray-500">Voting Power</span>
                <span className="font-semibold text-white">{formatPower(myPower)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-gray-500">Joined</span>
                <span className="text-gray-300">{formatDate(myMember?.joinedAt)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-gray-500">Status</span>
                {myActive ? (
                  <span className="text-emerald-400">Active</span>
                ) : (
                  <span className="text-red-400">Inactive</span>
                )}
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* ── Fee Status + Pay ── */}
      <div className="card">
        <div className="flex items-center justify-between">
          <div>
            <h4 className="text-sm font-semibold text-white">Membership Fee</h4>
            {isBootstrap ? (
              <p className="text-sm text-gray-400 mt-1">Bootstrap member — no fee required</p>
            ) : feeRemaining > 0 ? (
              <p className="text-sm text-gray-400 mt-1">
                Paid until <span className="text-white">{formatDate(myFeePaidUntil)}</span>
                {" "}({formatTimeRemaining(feeRemaining)} remaining)
              </p>
            ) : (
              <p className="text-sm text-red-400 mt-1 flex items-center gap-1">
                <AlertTriangle size={14} /> Expired — pay now to reactivate
              </p>
            )}
            {daoState.baseFee > 0n && (
              <p className="text-xs text-gray-600 mt-1">
                Fee: {feeTokenInfo
                  ? `${formatTokens(feeAmount, feeTokenInfo.decimals)} ${feeTokenInfo.symbol}`
                  : formatETH(feeAmount)
                } per epoch
              </p>
            )}
          </div>
          {!isBootstrap && daoState.baseFee > 0n && (
            <button onClick={() => setShowPayFee(true)} className="btn-gold text-xs">
              <CreditCard size={14} /> Pay Fee
            </button>
          )}
        </div>
      </div>

      {/* ── Quick Actions ── */}
      <div className="grid gap-4 sm:grid-cols-2">
        <button
          onClick={() => setShowAuthority(true)}
          className="card-hover flex items-center gap-3 text-left"
        >
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-gray-800">
            <KeyRound size={18} className="text-gray-400" />
          </div>
          <div>
            <p className="text-sm font-medium text-gray-200">Change Authority</p>
            <p className="text-xs text-gray-500">Migrate to a new wallet address</p>
          </div>
        </button>
        <button
          onClick={() => setShowInvite(true)}
          className="card-hover flex items-center gap-3 text-left"
        >
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-gray-800">
            <UserPlus size={18} className="text-gray-400" />
          </div>
          <div>
            <p className="text-sm font-medium text-gray-200">Issue Invite</p>
            <p className="text-xs text-gray-500">Invite a new member to the guild</p>
          </div>
        </button>
      </div>

      {/* ── My Invites ── */}
      {invites.length > 0 && (
        <div className="card space-y-3">
          <h4 className="text-sm font-semibold text-white">Your Invites</h4>
          {invites.map((inv) => {
            const expired = now > Number(inv.expiresAt);
            return (
              <div key={inv._id} className="flex items-center justify-between rounded-lg bg-gray-800/50 px-3 py-2 text-sm">
                <div>
                  <span className="font-mono text-xs text-gray-400">#{inv._id}</span>{" "}
                  <span className="text-gray-300">{shortAddress(inv.to)}</span>
                  {inv.claimed && <span className="ml-2 text-emerald-400 text-xs">Claimed</span>}
                  {inv.reclaimed && <span className="ml-2 text-gray-500 text-xs">Reclaimed</span>}
                  {!inv.claimed && !inv.reclaimed && expired && <span className="ml-2 text-red-400 text-xs">Expired</span>}
                  {!inv.claimed && !inv.reclaimed && !expired && <span className="ml-2 text-gold-400 text-xs">Pending</span>}
                </div>
                {expired && !inv.claimed && !inv.reclaimed && (
                  <button
                    onClick={() => handleReclaimInvite(inv._id)}
                    className="btn-outline text-xs"
                  >
                    Reclaim
                  </button>
                )}
              </div>
            );
          })}
        </div>
      )}

      {/* ── Pay Fee Modal ── */}
      <Modal open={showPayFee} onClose={() => setShowPayFee(false)} title="Pay Membership Fee">
        <div className="space-y-4">
          <p className="text-sm text-gray-400">
            Pay one epoch ({EPOCH_SECONDS / 86400} days) of membership fees.
          </p>
          <div className="rounded-lg bg-gray-800 p-4">
            <p className="text-xs text-gray-500">Amount</p>
            <p className="text-lg font-bold text-white">
              {feeTokenInfo
                ? `${formatTokens(feeAmount, feeTokenInfo.decimals)} ${feeTokenInfo.symbol}`
                : formatETH(feeAmount)}
            </p>
          </div>
          {feeTokenInfo && allowance < feeAmount && (
            <p className="text-xs text-yellow-400">
              Token approval required before payment.
            </p>
          )}
          <div className="flex justify-end gap-2">
            <button onClick={() => setShowPayFee(false)} className="btn-outline text-xs">Cancel</button>
            <button onClick={handlePayFee} className="btn-gold text-xs">
              {feeTokenInfo && allowance < feeAmount ? "Approve & Pay" : "Pay Now"}
            </button>
          </div>
        </div>
      </Modal>

      {/* ── Change Authority Modal ── */}
      <Modal open={showAuthority} onClose={() => setShowAuthority(false)} title="Change Authority">
        <div className="space-y-4">
          <p className="text-sm text-gray-400">
            Migrate your membership to a new wallet address. This is immediate and irreversible.
          </p>
          <div>
            <label className="label">New Authority Address</label>
            <input
              className="input"
              value={newAuthority}
              onChange={(e) => setNewAuthority(e.target.value)}
              placeholder="0x…"
            />
          </div>
          <div className="flex justify-end gap-2">
            <button onClick={() => setShowAuthority(false)} className="btn-outline text-xs">Cancel</button>
            <button onClick={handleChangeAuthority} className="btn-danger text-xs">Change Authority</button>
          </div>
        </div>
      </Modal>

      {/* ── Issue Invite Modal ── */}
      <Modal open={showInvite} onClose={() => setShowInvite(false)} title="Issue Invite">
        <div className="space-y-4">
          <p className="text-sm text-gray-400">
            Invite an address to join the guild as a Rank G member.
          </p>
          <div>
            <label className="label">Invitee Address</label>
            <input
              className="input"
              value={inviteAddress}
              onChange={(e) => setInviteAddress(e.target.value)}
              placeholder="0x…"
            />
          </div>
          <div className="flex justify-end gap-2">
            <button onClick={() => setShowInvite(false)} className="btn-outline text-xs">Cancel</button>
            <button onClick={handleIssueInvite} className="btn-gold text-xs">
              <Send size={14} /> Send Invite
            </button>
          </div>
        </div>
      </Modal>
    </div>
  );
}
