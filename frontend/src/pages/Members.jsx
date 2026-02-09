import { useEffect, useState, useCallback } from "react";
import { RefreshCw } from "lucide-react";
import { useWeb3 } from "../context/Web3Context";
import RankBadge from "../components/RankBadge";
import { shortAddress, formatDate, formatPower, formatTimeRemaining } from "../lib/format";
import { RANK_COLORS } from "../lib/constants";

export default function Members() {
  const { dao, isConnected } = useWeb3();
  const [members, setMembers] = useState([]);
  const [loading, setLoading] = useState(false);

  const load = useCallback(async () => {
    if (!dao) return;
    setLoading(true);
    try {
      const nextId = Number(await dao.nextMemberId());
      const results = await Promise.all(
        Array.from({ length: nextId - 1 }, (_, i) => i + 1).map((id) =>
          Promise.all([
            dao.getMember(id),
            dao.votingPowerOfMember(id),
            dao.isMemberActive(id),
            dao.feePaidUntil(id),
          ]).then(([m, power, active, paidUntil]) => ({
            id: Number(m.id),
            rank: Number(m.rank),
            authority: m.authority,
            joinedAt: Number(m.joinedAt),
            power: Number(power),
            active,
            paidUntil: Number(paidUntil),
          }))
        )
      );
      setMembers(results);
    } catch (e) {
      console.error("loadMembers:", e);
    } finally {
      setLoading(false);
    }
  }, [dao]);

  useEffect(() => { load(); }, [load]);

  if (!isConnected) {
    return <p className="text-gray-500">Connect wallet to view members.</p>;
  }

  return (
    <div className="mx-auto max-w-6xl animate-fade-in space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-bold text-white">Members</h2>
          <p className="text-sm text-gray-500">{members.length} total members</p>
        </div>
        <button onClick={load} disabled={loading} className="btn-outline text-xs">
          <RefreshCw size={14} className={loading ? "animate-spin" : ""} />
          Refresh
        </button>
      </div>

      {/* Grid */}
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {members.map((m) => {
          const now = Math.floor(Date.now() / 1000);
          const feeRemaining = m.paidUntil - now;
          const isBootstrap = m.paidUntil > 1e15; // type(uint64).max = huge number
          return (
            <div key={m.id} className="card-hover space-y-3">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <div
                    className="flex h-10 w-10 items-center justify-center rounded-xl text-sm font-bold"
                    style={{
                      backgroundColor: `${RANK_COLORS[m.rank]}20`,
                      color: RANK_COLORS[m.rank],
                    }}
                  >
                    #{m.id}
                  </div>
                  <div>
                    <p className="text-sm font-medium text-white">
                      {shortAddress(m.authority)}
                    </p>
                    <p className="text-xs text-gray-500">
                      Joined {formatDate(m.joinedAt)}
                    </p>
                  </div>
                </div>
                <RankBadge rank={m.rank} />
              </div>

              <div className="flex items-center justify-between text-xs">
                <span className="text-gray-500">
                  Power: <span className="font-medium text-gray-300">{formatPower(m.power)}</span>
                </span>
                <span className="flex items-center gap-1.5">
                  <span
                    className={`h-2 w-2 rounded-full ${m.active ? "bg-emerald-500" : "bg-red-500"}`}
                  />
                  <span className={m.active ? "text-emerald-400" : "text-red-400"}>
                    {m.active ? "Active" : "Inactive"}
                  </span>
                </span>
              </div>

              {/* Fee bar */}
              {!isBootstrap && (
                <div>
                  <div className="mb-1 flex justify-between text-[10px] text-gray-500">
                    <span>Fee</span>
                    <span>
                      {feeRemaining > 0
                        ? formatTimeRemaining(feeRemaining)
                        : "Expired"}
                    </span>
                  </div>
                  <div className="h-1 rounded-full bg-gray-800">
                    <div
                      className={`h-full rounded-full ${
                        feeRemaining > 14 * 86400
                          ? "bg-emerald-500"
                          : feeRemaining > 0
                          ? "bg-yellow-500"
                          : "bg-red-500"
                      }`}
                      style={{
                        width: `${Math.max(0, Math.min(100, (feeRemaining / (100 * 86400)) * 100))}%`,
                      }}
                    />
                  </div>
                </div>
              )}
              {isBootstrap && (
                <p className="text-[10px] text-gray-600">Bootstrap member — no fee</p>
              )}
            </div>
          );
        })}
      </div>

      {members.length === 0 && !loading && (
        <p className="text-center text-gray-500 py-12">No members found.</p>
      )}
    </div>
  );
}
