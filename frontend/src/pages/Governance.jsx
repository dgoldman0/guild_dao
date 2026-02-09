import { useEffect, useState, useCallback } from "react";
import { RefreshCw, Plus, ThumbsUp, ThumbsDown, Check, X } from "lucide-react";
import { useWeb3 } from "../context/Web3Context";
import RankBadge from "../components/RankBadge";
import Modal from "../components/Modal";
import { shortAddress, formatDateTime, formatTimeRemaining, rankName, pct } from "../lib/format";
import { PROPOSAL_TYPES, RANK_NAMES } from "../lib/constants";

function statusBadge(p, now) {
  if (p.finalized && p.succeeded) return <span className="rounded-full bg-emerald-500/15 px-2 py-0.5 text-[10px] font-semibold text-emerald-400">Passed</span>;
  if (p.finalized && !p.succeeded) return <span className="rounded-full bg-red-500/15 px-2 py-0.5 text-[10px] font-semibold text-red-400">Failed</span>;
  if (now < Number(p.startTime)) return <span className="rounded-full bg-blue-500/15 px-2 py-0.5 text-[10px] font-semibold text-blue-400">Pending</span>;
  if (now <= Number(p.endTime)) return <span className="rounded-full bg-gold-400/15 px-2 py-0.5 text-[10px] font-semibold text-gold-400">Active</span>;
  return <span className="rounded-full bg-gray-500/15 px-2 py-0.5 text-[10px] font-semibold text-gray-400">Ended</span>;
}

function proposalDescription(p) {
  const t = Number(p.proposalType);
  switch (t) {
    case 0: return `Grant ${rankName(p.rankValue)} to Member #${Number(p.targetId)}`;
    case 1: return `Demote Member #${Number(p.targetId)} to ${rankName(p.rankValue)}`;
    case 2: return `Change Member #${Number(p.targetId)} authority to ${shortAddress(p.addressValue)}`;
    case 3: return `Change voting period to ${Number(p.parameterValue) / 86400}d`;
    case 4: return `Change quorum to ${Number(p.parameterValue) / 100}%`;
    case 5: return `Change order delay to ${Number(p.parameterValue) / 3600}h`;
    case 6: return `Change invite expiry to ${Number(p.parameterValue) / 3600}h`;
    case 7: return `Change execution delay to ${Number(p.parameterValue) / 3600}h`;
    case 8: return `Block Order #${Number(p.orderIdToBlock)}`;
    case 9: return `Transfer ERC-20 to ${shortAddress(p.erc20Recipient)}`;
    default: return `Proposal Type ${t}`;
  }
}

export default function Governance() {
  const { governance, dao, isConnected, isMember, myMemberId, sendTx } = useWeb3();
  const [proposals, setProposals] = useState([]);
  const [loading, setLoading] = useState(false);
  const [filter, setFilter] = useState("all"); // all, active, passed, failed
  const [showCreate, setShowCreate] = useState(false);
  const [now, setNow] = useState(Math.floor(Date.now() / 1000));

  // Form state
  const [formType, setFormType] = useState(0);
  const [formTarget, setFormTarget] = useState("");
  const [formRank, setFormRank] = useState(0);
  const [formAddress, setFormAddress] = useState("");
  const [formValue, setFormValue] = useState("");
  const [formOrderId, setFormOrderId] = useState("");
  const [formToken, setFormToken] = useState("");
  const [formAmount, setFormAmount] = useState("");
  const [formRecipient, setFormRecipient] = useState("");

  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 30000);
    return () => clearInterval(t);
  }, []);

  const load = useCallback(async () => {
    if (!governance) return;
    setLoading(true);
    try {
      const nextId = Number(await governance.nextProposalId());
      const results = await Promise.all(
        Array.from({ length: nextId - 1 }, (_, i) => i + 1).map((id) =>
          governance.getProposal(id).then((p) => ({ ...p, _id: id })).catch(() => null)
        )
      );
      setProposals(results.filter(Boolean).filter((p) => p.exists).reverse());
    } catch (e) {
      console.error(e);
    } finally {
      setLoading(false);
    }
  }, [governance]);

  useEffect(() => { load(); }, [load]);

  const filtered = proposals.filter((p) => {
    if (filter === "active") return !p.finalized && now >= Number(p.startTime) && now <= Number(p.endTime);
    if (filter === "passed") return p.finalized && p.succeeded;
    if (filter === "failed") return p.finalized && !p.succeeded;
    return true;
  });

  async function handleVote(proposalId, support) {
    await sendTx(`Vote ${support ? "Yes" : "No"}`, governance.castVote(proposalId, support));
    load();
  }

  async function handleFinalize(proposalId) {
    await sendTx("Finalize", governance.finalizeProposal(proposalId));
    load();
  }

  async function handleCreate() {
    const t = Number(formType);
    let txP;
    if (t === 0) txP = governance.createProposalGrantRank(Number(formTarget), Number(formRank));
    else if (t === 1) txP = governance.createProposalDemoteRank(Number(formTarget), Number(formRank));
    else if (t === 2) txP = governance.createProposalChangeAuthority(Number(formTarget), formAddress);
    else if (t >= 3 && t <= 7) txP = governance.createProposalChangeParameter(t, BigInt(formValue));
    else if (t === 8) txP = governance.createProposalBlockOrder(Number(formOrderId));
    else if (t === 9) txP = governance.createProposalTransferERC20(formToken, BigInt(formAmount), formRecipient);
    else return;

    await sendTx("Create Proposal", txP);
    setShowCreate(false);
    load();
  }

  if (!isConnected) return <p className="text-gray-500">Connect wallet to view governance.</p>;

  return (
    <div className="mx-auto max-w-6xl animate-fade-in space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-bold text-white">Governance</h2>
          <p className="text-sm text-gray-500">{proposals.length} proposals</p>
        </div>
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

      {/* Filters */}
      <div className="flex gap-2">
        {["all", "active", "passed", "failed"].map((f) => (
          <button
            key={f}
            onClick={() => setFilter(f)}
            className={`rounded-lg px-3 py-1.5 text-xs font-medium transition-colors ${
              filter === f
                ? "bg-gray-800 text-white"
                : "text-gray-500 hover:text-gray-300"
            }`}
          >
            {f.charAt(0).toUpperCase() + f.slice(1)}
          </button>
        ))}
      </div>

      {/* Proposal list */}
      <div className="space-y-3">
        {filtered.map((p) => {
          const totalVotes = p.yesVotes + p.noVotes;
          const yesPct = totalVotes > 0n ? Number((p.yesVotes * 10000n) / totalVotes) / 100 : 0;
          const isActive = !p.finalized && now >= Number(p.startTime) && now <= Number(p.endTime);
          const canFinalize = !p.finalized && now > Number(p.endTime);
          const timeLeft = Number(p.endTime) - now;

          return (
            <div key={p._id} className="card space-y-3">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <span className="text-xs font-mono text-gray-600">#{p._id}</span>
                  <span className="text-xs font-medium text-gray-400">
                    {PROPOSAL_TYPES[Number(p.proposalType)] ?? "Unknown"}
                  </span>
                  {statusBadge(p, now)}
                </div>
                <span className="text-xs text-gray-600">
                  by Member #{Number(p.proposerId)}
                </span>
              </div>

              <p className="text-sm text-gray-200">{proposalDescription(p)}</p>

              {/* Vote bar */}
              <div>
                <div className="mb-1 flex justify-between text-xs text-gray-500">
                  <span className="text-emerald-400">Yes {yesPct.toFixed(1)}%</span>
                  <span className="text-red-400">No {(100 - yesPct).toFixed(1)}%</span>
                </div>
                <div className="flex h-2 rounded-full bg-gray-800 overflow-hidden">
                  {totalVotes > 0n && (
                    <>
                      <div className="bg-emerald-500 transition-all" style={{ width: `${yesPct}%` }} />
                      <div className="bg-red-500 flex-1" />
                    </>
                  )}
                </div>
                <div className="mt-1 flex justify-between text-[10px] text-gray-600">
                  <span>{Number(p.yesVotes)} power</span>
                  <span>{Number(p.noVotes)} power</span>
                </div>
              </div>

              {/* Actions */}
              <div className="flex items-center justify-between">
                <span className="text-xs text-gray-600">
                  {isActive && `${formatTimeRemaining(timeLeft)} remaining`}
                  {canFinalize && "Voting ended — ready to finalize"}
                  {p.finalized && `Finalized ${formatDateTime(p.endTime)}`}
                </span>
                <div className="flex gap-2">
                  {isActive && isMember && (
                    <>
                      <button
                        onClick={() => handleVote(p._id, true)}
                        className="btn-success text-xs"
                      >
                        <ThumbsUp size={12} /> Yes
                      </button>
                      <button
                        onClick={() => handleVote(p._id, false)}
                        className="btn-danger text-xs"
                      >
                        <ThumbsDown size={12} /> No
                      </button>
                    </>
                  )}
                  {canFinalize && (
                    <button onClick={() => handleFinalize(p._id)} className="btn-outline text-xs">
                      <Check size={12} /> Finalize
                    </button>
                  )}
                </div>
              </div>
            </div>
          );
        })}
        {filtered.length === 0 && (
          <p className="py-12 text-center text-gray-500">No proposals found.</p>
        )}
      </div>

      {/* ── Create Proposal Modal ── */}
      <Modal open={showCreate} onClose={() => setShowCreate(false)} title="Create Proposal" wide>
        <div className="space-y-4">
          <div>
            <label className="label">Proposal Type</label>
            <select
              className="input"
              value={formType}
              onChange={(e) => setFormType(Number(e.target.value))}
            >
              {PROPOSAL_TYPES.map((name, i) => (
                <option key={i} value={i}>{name}</option>
              ))}
            </select>
          </div>

          {/* Dynamic fields based on type */}
          {(formType === 0 || formType === 1) && (
            <>
              <div>
                <label className="label">Target Member ID</label>
                <input className="input" type="number" value={formTarget} onChange={(e) => setFormTarget(e.target.value)} placeholder="e.g. 2" />
              </div>
              <div>
                <label className="label">New Rank</label>
                <select className="input" value={formRank} onChange={(e) => setFormRank(Number(e.target.value))}>
                  {RANK_NAMES.map((name, i) => <option key={i} value={i}>{name} ({i})</option>)}
                </select>
              </div>
            </>
          )}
          {formType === 2 && (
            <>
              <div>
                <label className="label">Target Member ID</label>
                <input className="input" type="number" value={formTarget} onChange={(e) => setFormTarget(e.target.value)} />
              </div>
              <div>
                <label className="label">New Authority Address</label>
                <input className="input" value={formAddress} onChange={(e) => setFormAddress(e.target.value)} placeholder="0x…" />
              </div>
            </>
          )}
          {formType >= 3 && formType <= 7 && (
            <div>
              <label className="label">New Value (raw seconds / basis points)</label>
              <input className="input" value={formValue} onChange={(e) => setFormValue(e.target.value)} placeholder="e.g. 604800 for 7 days" />
            </div>
          )}
          {formType === 8 && (
            <div>
              <label className="label">Order ID to Block</label>
              <input className="input" type="number" value={formOrderId} onChange={(e) => setFormOrderId(e.target.value)} />
            </div>
          )}
          {formType === 9 && (
            <>
              <div>
                <label className="label">Token Address</label>
                <input className="input" value={formToken} onChange={(e) => setFormToken(e.target.value)} placeholder="0x…" />
              </div>
              <div>
                <label className="label">Amount (wei)</label>
                <input className="input" value={formAmount} onChange={(e) => setFormAmount(e.target.value)} />
              </div>
              <div>
                <label className="label">Recipient</label>
                <input className="input" value={formRecipient} onChange={(e) => setFormRecipient(e.target.value)} placeholder="0x…" />
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
