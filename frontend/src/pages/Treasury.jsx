import { useEffect, useState, useCallback } from "react";
import { RefreshCw, Plus, ThumbsUp, ThumbsDown, Check, Play, Lock, Unlock } from "lucide-react";
import { parseEther, AbiCoder } from "ethers";
import { useWeb3 } from "../context/Web3Context";
import Modal from "../components/Modal";
import { formatETH, formatDateTime, formatTimeRemaining, pct, shortAddress, resultToObject } from "../lib/format";
import { ACTION_TYPES } from "../lib/constants";

export default function Treasury() {
  const { treasury, isConnected, isMember, myMemberId, sendTx } = useWeb3();
  const [ethBalance, setEthBalance] = useState(0n);
  const [locked, setLocked] = useState(false);
  const [proposals, setProposals] = useState([]);
  const [loading, setLoading] = useState(false);
  const [showCreate, setShowCreate] = useState(false);
  const [now, setNow] = useState(Math.floor(Date.now() / 1000));

  // Create form
  const [actionType, setActionType] = useState(0);
  const [formTo, setFormTo] = useState("");
  const [formAmount, setFormAmount] = useState("");
  const [formToken, setFormToken] = useState("");

  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 30000);
    return () => clearInterval(t);
  }, []);

  const load = useCallback(async () => {
    if (!treasury) return;
    setLoading(true);
    try {
      const [bal, isLocked, nextId] = await Promise.all([
        treasury.balanceETH(),
        treasury.treasuryLocked(),
        treasury.nextProposalId(),
      ]);
      setEthBalance(bal);
      setLocked(isLocked);

      const results = await Promise.all(
        Array.from({ length: Number(nextId) - 1 }, (_, i) => i + 1).map(async (id) => {
          try {
            const p = await treasury.getProposal(id);
            return { ...resultToObject(p), _id: id };
          } catch {
            return null;
          }
        })
      );
      setProposals(results.filter(Boolean).reverse());
    } catch (e) {
      console.error(e);
    } finally {
      setLoading(false);
    }
  }, [treasury]);

  useEffect(() => { load(); }, [load]);

  async function handleVote(proposalId, support) {
    await sendTx(`Vote ${support ? "Yes" : "No"}`, treasury.castVote(proposalId, support));
    load();
  }
  async function handleFinalize(proposalId) {
    await sendTx("Finalize", treasury.finalize(proposalId));
    load();
  }
  async function handleExecute(proposalId) {
    await sendTx("Execute", treasury.execute(proposalId));
    load();
  }

  async function handleCreate() {
    const coder = AbiCoder.defaultAbiCoder();
    let data;
    if (actionType === 0) {
      data = coder.encode(["address", "uint256"], [formTo, parseEther(formAmount || "0")]);
    } else if (actionType === 1) {
      data = coder.encode(["address", "address", "uint256"], [formToken, formTo, parseEther(formAmount || "0")]);
    } else if (actionType === 20) {
      data = coder.encode(["bool"], [true]); // lock
    } else {
      data = "0x";
    }
    await sendTx("Create Proposal", treasury.propose(actionType, data));
    setShowCreate(false);
    load();
  }

  if (!isConnected) return <p className="text-gray-500">Connect wallet to view treasury.</p>;

  return (
    <div className="mx-auto max-w-6xl animate-fade-in space-y-6">
      <div className="flex items-center justify-between">
        <h2 className="text-2xl font-bold text-white">Treasury</h2>
        <div className="flex gap-2">
          <button onClick={load} disabled={loading} className="btn-outline text-xs">
            <RefreshCw size={14} className={loading ? "animate-spin" : ""} /> Refresh
          </button>
          {isMember && (
            <button onClick={() => setShowCreate(true)} className="btn-gold text-xs">
              <Plus size={14} /> New Proposal
            </button>
          )}
        </div>
      </div>

      {/* Balance cards */}
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <div className="card">
          <p className="text-xs font-medium uppercase tracking-wider text-gray-500">ETH Balance</p>
          <p className="mt-1 text-2xl font-bold text-white">{formatETH(ethBalance)}</p>
        </div>
        <div className="card">
          <p className="text-xs font-medium uppercase tracking-wider text-gray-500">Status</p>
          <div className="mt-1 flex items-center gap-2">
            {locked ? (
              <>
                <Lock size={16} className="text-red-400" />
                <span className="text-lg font-bold text-red-400">Locked</span>
              </>
            ) : (
              <>
                <Unlock size={16} className="text-emerald-400" />
                <span className="text-lg font-bold text-emerald-400">Active</span>
              </>
            )}
          </div>
        </div>
        <div className="card">
          <p className="text-xs font-medium uppercase tracking-wider text-gray-500">Proposals</p>
          <p className="mt-1 text-2xl font-bold text-white">{proposals.length}</p>
        </div>
      </div>

      {/* Proposal list */}
      <h3 className="text-lg font-semibold text-white">Proposals</h3>
      <div className="space-y-3">
        {proposals.map((p) => {
          const totalVotes = p.yesVotes + p.noVotes;
          const yesPct = totalVotes > 0n ? Number((p.yesVotes * 10000n) / totalVotes) / 100 : 0;
          const isActive = !p.finalized && now >= Number(p.startTime) && now <= Number(p.endTime);
          const canFinalize = !p.finalized && now > Number(p.endTime);
          const canExecute = p.finalized && p.succeeded && !p.executed && now >= Number(p.executableAfter);
          const timeLeft = Number(p.endTime) - now;

          return (
            <div key={p._id} className="card space-y-3">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <span className="text-xs font-mono text-gray-600">#{p._id}</span>
                  <span className="text-xs font-medium text-gray-400">
                    {ACTION_TYPES[Number(p.actionType)] ?? `Action ${Number(p.actionType)}`}
                  </span>
                  {p.executed && <span className="rounded-full bg-emerald-500/15 px-2 py-0.5 text-[10px] font-semibold text-emerald-400">Executed</span>}
                  {p.finalized && p.succeeded && !p.executed && <span className="rounded-full bg-blue-500/15 px-2 py-0.5 text-[10px] font-semibold text-blue-400">Awaiting Execution</span>}
                  {p.finalized && !p.succeeded && <span className="rounded-full bg-red-500/15 px-2 py-0.5 text-[10px] font-semibold text-red-400">Failed</span>}
                  {isActive && <span className="rounded-full bg-gold-400/15 px-2 py-0.5 text-[10px] font-semibold text-gold-400">Active</span>}
                </div>
                <span className="text-xs text-gray-600">by Member #{Number(p.proposerId)}</span>
              </div>

              <div className="flex h-2 rounded-full bg-gray-800 overflow-hidden">
                {totalVotes > 0n && (
                  <>
                    <div className="bg-emerald-500 transition-all" style={{ width: `${yesPct}%` }} />
                    <div className="bg-red-500 flex-1" />
                  </>
                )}
              </div>

              <div className="flex items-center justify-between">
                <span className="text-xs text-gray-600">
                  {isActive && `${formatTimeRemaining(timeLeft)} remaining`}
                  {canFinalize && "Ready to finalize"}
                  {canExecute && "Ready to execute"}
                </span>
                <div className="flex gap-2">
                  {isActive && isMember && (
                    <>
                      <button onClick={() => handleVote(p._id, true)} className="btn-success text-xs">
                        <ThumbsUp size={12} /> Yes
                      </button>
                      <button onClick={() => handleVote(p._id, false)} className="btn-danger text-xs">
                        <ThumbsDown size={12} /> No
                      </button>
                    </>
                  )}
                  {canFinalize && (
                    <button onClick={() => handleFinalize(p._id)} className="btn-outline text-xs">
                      <Check size={12} /> Finalize
                    </button>
                  )}
                  {canExecute && (
                    <button onClick={() => handleExecute(p._id)} className="btn-gold text-xs">
                      <Play size={12} /> Execute
                    </button>
                  )}
                </div>
              </div>
            </div>
          );
        })}
        {proposals.length === 0 && (
          <p className="py-12 text-center text-gray-500">No treasury proposals yet.</p>
        )}
      </div>

      {/* ── Create Proposal Modal ── */}
      <Modal open={showCreate} onClose={() => setShowCreate(false)} title="Create Treasury Proposal">
        <div className="space-y-4">
          <div>
            <label className="label">Action Type</label>
            <select className="input" value={actionType} onChange={(e) => setActionType(Number(e.target.value))}>
              <option value={0}>Transfer ETH</option>
              <option value={1}>Transfer ERC-20</option>
              <option value={20}>Lock/Unlock Treasury</option>
            </select>
          </div>
          {actionType === 0 && (
            <>
              <div>
                <label className="label">Recipient</label>
                <input className="input" value={formTo} onChange={(e) => setFormTo(e.target.value)} placeholder="0x…" />
              </div>
              <div>
                <label className="label">Amount (ETH)</label>
                <input className="input" value={formAmount} onChange={(e) => setFormAmount(e.target.value)} placeholder="0.1" />
              </div>
            </>
          )}
          {actionType === 1 && (
            <>
              <div>
                <label className="label">Token Address</label>
                <input className="input" value={formToken} onChange={(e) => setFormToken(e.target.value)} placeholder="0x…" />
              </div>
              <div>
                <label className="label">Recipient</label>
                <input className="input" value={formTo} onChange={(e) => setFormTo(e.target.value)} placeholder="0x…" />
              </div>
              <div>
                <label className="label">Amount (tokens, in ether units)</label>
                <input className="input" value={formAmount} onChange={(e) => setFormAmount(e.target.value)} placeholder="100" />
              </div>
            </>
          )}
          <div className="flex justify-end gap-2 pt-2">
            <button onClick={() => setShowCreate(false)} className="btn-outline text-xs">Cancel</button>
            <button onClick={handleCreate} className="btn-gold text-xs">Create Proposal</button>
          </div>
        </div>
      </Modal>
    </div>
  );
}
