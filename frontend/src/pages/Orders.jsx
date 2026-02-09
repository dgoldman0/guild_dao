import { useEffect, useState, useCallback } from "react";
import { RefreshCw, Plus, Play, ShieldOff, Undo2, Check } from "lucide-react";
import { useWeb3 } from "../context/Web3Context";
import RankBadge from "../components/RankBadge";
import Modal from "../components/Modal";
import { shortAddress, formatDateTime, formatTimeRemaining, rankName } from "../lib/format";
import { ORDER_TYPES, RANK_NAMES } from "../lib/constants";

function orderStatus(o, now) {
  if (o.executed) return <span className="rounded-full bg-emerald-500/15 px-2 py-0.5 text-[10px] font-semibold text-emerald-400">Executed</span>;
  if (o.blocked) return <span className="rounded-full bg-red-500/15 px-2 py-0.5 text-[10px] font-semibold text-red-400">Blocked</span>;
  if (now < Number(o.executeAfter)) return <span className="rounded-full bg-gold-400/15 px-2 py-0.5 text-[10px] font-semibold text-gold-400">Timelocked</span>;
  return <span className="rounded-full bg-blue-500/15 px-2 py-0.5 text-[10px] font-semibold text-blue-400">Ready</span>;
}

function orderDescription(o) {
  const type = Number(o.orderType);
  if (type === 0) return `Promote Member #${Number(o.targetId)} to ${rankName(o.newRank)}`;
  if (type === 1) return `Demote Member #${Number(o.targetId)} by 1 rank`;
  if (type === 2) return `Change Member #${Number(o.targetId)} authority to ${shortAddress(o.newAuthority)}`;
  return `Order Type ${type}`;
}

export default function Orders() {
  const { governance, isConnected, isMember, myMemberId, sendTx } = useWeb3();
  const [orders, setOrders] = useState([]);
  const [loading, setLoading] = useState(false);
  const [filter, setFilter] = useState("all");
  const [showCreate, setShowCreate] = useState(false);
  const [now, setNow] = useState(Math.floor(Date.now() / 1000));

  // Form
  const [orderType, setOrderType] = useState(0);
  const [target, setTarget] = useState("");
  const [rank, setRank] = useState(0);
  const [authority, setAuthority] = useState("");

  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 30000);
    return () => clearInterval(t);
  }, []);

  const load = useCallback(async () => {
    if (!governance) return;
    setLoading(true);
    try {
      const nextId = Number(await governance.nextOrderId());
      const results = await Promise.all(
        Array.from({ length: nextId - 1 }, (_, i) => i + 1).map((id) =>
          governance.getOrder(id).then((o) => ({ ...o, _id: id })).catch(() => null)
        )
      );
      setOrders(results.filter(Boolean).filter((o) => o.exists).reverse());
    } catch (e) {
      console.error(e);
    } finally {
      setLoading(false);
    }
  }, [governance]);

  useEffect(() => { load(); }, [load]);

  const filtered = orders.filter((o) => {
    if (filter === "pending") return !o.executed && !o.blocked;
    if (filter === "executed") return o.executed;
    if (filter === "blocked") return o.blocked;
    return true;
  });

  async function handleAccept(orderId) {
    await sendTx("Accept Promotion", governance.acceptPromotionGrant(orderId));
    load();
  }
  async function handleExecute(orderId) {
    await sendTx("Execute Order", governance.executeOrder(orderId));
    load();
  }
  async function handleBlock(orderId) {
    await sendTx("Block Order", governance.blockOrder(orderId));
    load();
  }
  async function handleRescind(orderId) {
    await sendTx("Rescind Order", governance.rescindOrder(orderId));
    load();
  }

  async function handleCreate() {
    let txP;
    if (orderType === 0) txP = governance.issuePromotionGrant(Number(target), Number(rank));
    else if (orderType === 1) txP = governance.issueDemotionOrder(Number(target));
    else if (orderType === 2) txP = governance.issueAuthorityOrder(Number(target), authority);
    else return;
    await sendTx("Issue Order", txP);
    setShowCreate(false);
    load();
  }

  if (!isConnected) return <p className="text-gray-500">Connect wallet to view orders.</p>;

  return (
    <div className="mx-auto max-w-6xl animate-fade-in space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-bold text-white">Timelocked Orders</h2>
          <p className="text-sm text-gray-500">{orders.length} total orders</p>
        </div>
        <div className="flex gap-2">
          <button onClick={load} disabled={loading} className="btn-outline text-xs">
            <RefreshCw size={14} className={loading ? "animate-spin" : ""} /> Refresh
          </button>
          {isMember && (
            <button onClick={() => setShowCreate(true)} className="btn-gold text-xs">
              <Plus size={14} /> New Order
            </button>
          )}
        </div>
      </div>

      {/* Filters */}
      <div className="flex gap-2">
        {["all", "pending", "executed", "blocked"].map((f) => (
          <button
            key={f}
            onClick={() => setFilter(f)}
            className={`rounded-lg px-3 py-1.5 text-xs font-medium transition-colors ${
              filter === f ? "bg-gray-800 text-white" : "text-gray-500 hover:text-gray-300"
            }`}
          >
            {f.charAt(0).toUpperCase() + f.slice(1)}
          </button>
        ))}
      </div>

      {/* Order list */}
      <div className="space-y-3">
        {filtered.map((o) => {
          const isPending = !o.executed && !o.blocked;
          const isReady = isPending && now >= Number(o.executeAfter);
          const isTimelocked = isPending && now < Number(o.executeAfter);
          const timeLeft = Number(o.executeAfter) - now;
          const isPromotion = Number(o.orderType) === 0;

          return (
            <div key={o._id} className="card space-y-3">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <span className="text-xs font-mono text-gray-600">#{o._id}</span>
                  <span className="text-xs font-medium text-gray-400">
                    {ORDER_TYPES[Number(o.orderType)] ?? "Unknown"}
                  </span>
                  {orderStatus(o, now)}
                </div>
                <div className="flex items-center gap-2 text-xs text-gray-500">
                  <span>by Member #{Number(o.issuerId)}</span>
                  <RankBadge rank={o.issuerRankAtCreation} size="sm" />
                </div>
              </div>

              <p className="text-sm text-gray-200">{orderDescription(o)}</p>

              <div className="flex items-center justify-between">
                <span className="text-xs text-gray-600">
                  {isTimelocked && `Executable in ${formatTimeRemaining(timeLeft)}`}
                  {isReady && "Ready to execute"}
                  {o.executed && `Executed ${formatDateTime(o.executeAfter)}`}
                  {o.blocked && `Blocked by Member #${Number(o.blockedById) || "governance"}`}
                </span>
                <div className="flex gap-2">
                  {isReady && isPromotion && isMember && Number(myMemberId) === Number(o.targetId) && (
                    <button onClick={() => handleAccept(o._id)} className="btn-success text-xs">
                      <Check size={12} /> Accept
                    </button>
                  )}
                  {isReady && !isPromotion && (
                    <button onClick={() => handleExecute(o._id)} className="btn-success text-xs">
                      <Play size={12} /> Execute
                    </button>
                  )}
                  {isPending && isTimelocked && isMember && (
                    <button onClick={() => handleBlock(o._id)} className="btn-danger text-xs">
                      <ShieldOff size={12} /> Block
                    </button>
                  )}
                  {isPending && isMember && Number(o.issuerId) === myMemberId && (
                    <button onClick={() => handleRescind(o._id)} className="btn-outline text-xs">
                      <Undo2 size={12} /> Rescind
                    </button>
                  )}
                </div>
              </div>
            </div>
          );
        })}
        {filtered.length === 0 && (
          <p className="py-12 text-center text-gray-500">No orders found.</p>
        )}
      </div>

      {/* ── Create Order Modal ── */}
      <Modal open={showCreate} onClose={() => setShowCreate(false)} title="Issue Order">
        <div className="space-y-4">
          <div>
            <label className="label">Order Type</label>
            <select className="input" value={orderType} onChange={(e) => setOrderType(Number(e.target.value))}>
              {ORDER_TYPES.map((name, i) => <option key={i} value={i}>{name}</option>)}
            </select>
          </div>
          <div>
            <label className="label">Target Member ID</label>
            <input className="input" type="number" value={target} onChange={(e) => setTarget(e.target.value)} placeholder="e.g. 2" />
          </div>
          {orderType === 0 && (
            <div>
              <label className="label">New Rank</label>
              <select className="input" value={rank} onChange={(e) => setRank(Number(e.target.value))}>
                {RANK_NAMES.map((name, i) => <option key={i} value={i}>{name}</option>)}
              </select>
            </div>
          )}
          {orderType === 2 && (
            <div>
              <label className="label">New Authority Address</label>
              <input className="input" value={authority} onChange={(e) => setAuthority(e.target.value)} placeholder="0x…" />
            </div>
          )}
          <div className="flex justify-end gap-2 pt-2">
            <button onClick={() => setShowCreate(false)} className="btn-outline text-xs">Cancel</button>
            <button onClick={handleCreate} className="btn-gold text-xs">Issue Order</button>
          </div>
        </div>
      </Modal>
    </div>
  );
}
