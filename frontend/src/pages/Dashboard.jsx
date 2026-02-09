import { useEffect, useState } from "react";
import { Users, Zap, Landmark, Clock, AlertTriangle, ArrowRight } from "lucide-react";
import { Link } from "react-router-dom";
import { useWeb3 } from "../context/Web3Context";
import EpochRing from "../components/EpochRing";
import { RankBadgeLarge } from "../components/RankBadge";
import StatCard from "../components/StatCard";
import { formatETH, formatPower, formatDate, formatTimeRemaining, rankName, isBootstrapFee } from "../lib/format";
import { EPOCH_SECONDS } from "../lib/constants";

export default function Dashboard() {
  const {
    isConnected, isMember, dao, treasury, governance, provider,
    myMember, myMemberId, myPower, myActive, myFeePaidUntil, daoState,
  } = useWeb3();

  const [treasuryETH, setTreasuryETH] = useState(0n);
  const [epochProgress, setEpochProgress] = useState(0);
  const [epochDay, setEpochDay] = useState(0);
  const [feeRemaining, setFeeRemaining] = useState(0);
  const [now, setNow] = useState(Math.floor(Date.now() / 1000));
  const [activeProposals, setActiveProposals] = useState(0);
  const [activeOrders, setActiveOrders] = useState(0);

  // Update clock every 30s
  useEffect(() => {
    const timer = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 30000);
    return () => clearInterval(timer);
  }, []);

  // Calculate epoch progress
  useEffect(() => {
    const epoch = EPOCH_SECONDS;
    const elapsed = now % epoch;
    setEpochProgress(elapsed / epoch);
    setEpochDay(Math.floor(elapsed / 86400));
  }, [now]);

  // Fee remaining
  useEffect(() => {
    if (!isMember || !myFeePaidUntil) return;
    const paidUntil = Number(myFeePaidUntil);
    setFeeRemaining(paidUntil - now);
  }, [isMember, myFeePaidUntil, now]);

  // Treasury balance
  useEffect(() => {
    if (!treasury) return;
    treasury.balanceETH().then(setTreasuryETH).catch(() => {});
  }, [treasury]);

  // Active proposals / orders counts
  useEffect(() => {
    if (!governance) return;
    (async () => {
      try {
        const nextP = Number(await governance.nextProposalId());
        const nextO = Number(await governance.nextOrderId());
        let pCount = 0, oCount = 0;
        const pPromises = [];
        for (let i = 1; i < nextP; i++) {
          pPromises.push(governance.getProposal(i).then(p => {
            if (p.exists && !p.finalized) pCount++;
          }).catch(() => {}));
        }
        const oPromises = [];
        for (let i = 1; i < nextO; i++) {
          oPromises.push(governance.getOrder(i).then(o => {
            if (o.exists && !o.executed && !o.blocked) oCount++;
          }).catch(() => {}));
        }
        await Promise.all([...pPromises, ...oPromises]);
        setActiveProposals(pCount);
        setActiveOrders(oCount);
      } catch (e) {
        console.error(e);
      }
    })();
  }, [governance]);

  if (!isConnected) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-6 text-center">
        <div className="flex h-20 w-20 items-center justify-center rounded-2xl bg-gold-400/20 animate-pulse-gold">
          <Zap size={36} className="text-gold-400" />
        </div>
        <div>
          <h2 className="text-2xl font-bold text-white">Welcome to The Guild</h2>
          <p className="mt-2 text-gray-400">Connect your wallet to get started</p>
        </div>
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-6xl animate-fade-in space-y-6">
      <h2 className="text-2xl font-bold text-white">Dashboard</h2>

      {/* ── Top row: Member card + Epoch Ring ── */}
      <div className="grid gap-5 lg:grid-cols-3">
        {/* Member card */}
        <div className="card lg:col-span-2">
          {isMember ? (
            <div className="flex items-center gap-5">
              <RankBadgeLarge rank={myMember?.rank ?? 0} />
              <div>
                <h3 className="text-lg font-bold text-white">
                  Rank {rankName(myMember?.rank)} — Member #{myMemberId}
                </h3>
                <p className="mt-1 text-sm text-gray-400">
                  Voting Power: <span className="font-semibold text-white">{formatPower(myPower)}</span>
                </p>
                <div className="mt-2 flex items-center gap-2">
                  {myActive ? (
                    <span className="inline-flex items-center gap-1 rounded-full bg-emerald-500/15 px-2.5 py-0.5 text-xs font-medium text-emerald-400">
                      <span className="h-1.5 w-1.5 rounded-full bg-emerald-400" /> Active
                    </span>
                  ) : (
                    <span className="inline-flex items-center gap-1 rounded-full bg-red-500/15 px-2.5 py-0.5 text-xs font-medium text-red-400">
                      <span className="h-1.5 w-1.5 rounded-full bg-red-400" /> Inactive
                    </span>
                  )}
                </div>
              </div>
            </div>
          ) : (
            <div className="text-center py-4">
              <p className="text-gray-400">You are not a member of this guild.</p>
              <p className="text-sm text-gray-500 mt-1">Ask an existing member for an invite.</p>
            </div>
          )}
        </div>

        {/* Epoch ring */}
        <div className="card flex items-center justify-center">
          <div className="relative">
            <EpochRing
              progress={epochProgress}
              label={`Day ${epochDay}`}
              sublabel="of 100-day epoch"
              size={130}
            />
          </div>
        </div>
      </div>

      {/* ── Stats row ── */}
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <StatCard icon={Users} label="Members" value={daoState.memberCount} />
        <StatCard icon={Zap} label="Total Power" value={formatPower(daoState.totalPower)} />
        <StatCard icon={Landmark} label="Treasury" value={formatETH(treasuryETH)} />
        <StatCard
          icon={Clock}
          label="Voting Period"
          value={`${Number(daoState.votingPeriod) / 86400}d`}
          sub={`Quorum: ${(daoState.quorumBps / 100).toFixed(0)}%`}
        />
      </div>

      {/* ── Fee status (only for members with baseFee > 0) ── */}
      {isMember && daoState.baseFee > 0n && (
        <div className="card">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-xs font-medium uppercase tracking-wider text-gray-500">
                Fee Status
              </p>
              {isBootstrapFee(myFeePaidUntil) ? (
                <p className="mt-1 text-sm text-gray-400">
                  Bootstrap member —{" "}
                  <span className="font-semibold text-emerald-400">no fee required</span>
                </p>
              ) : feeRemaining > 0 ? (
                <p className="mt-1 text-sm text-gray-300">
                  Paid until{" "}
                  <span className="font-semibold text-white">
                    {formatDate(myFeePaidUntil)}
                  </span>{" "}
                  <span className="text-gray-500">
                    ({formatTimeRemaining(feeRemaining)} remaining)
                  </span>
                </p>
              ) : (
                <p className="mt-1 text-sm text-red-400 flex items-center gap-1">
                  <AlertTriangle size={14} />
                  Fee expired — pay now to stay active
                </p>
              )}
            </div>
            {!isBootstrapFee(myFeePaidUntil) && (
              <Link to="/profile" className="btn-gold text-xs">
                Pay Fee <ArrowRight size={14} />
              </Link>
            )}
          </div>
          {/* Progress bar */}
          {!isBootstrapFee(myFeePaidUntil) && feeRemaining > 0 && (
            <div className="mt-3 h-1.5 rounded-full bg-gray-800">
              <div
                className={`h-full rounded-full transition-all ${
                  feeRemaining > 14 * 86400
                    ? "bg-emerald-500"
                    : feeRemaining > 7 * 86400
                    ? "bg-yellow-500"
                    : "bg-red-500"
                }`}
                style={{
                  width: `${Math.min(100, (feeRemaining / EPOCH_SECONDS) * 100)}%`,
                }}
              />
            </div>
          )}
        </div>
      )}

      {/* ── Action items ── */}
      <div className="grid gap-4 lg:grid-cols-2">
        <Link to="/governance" className="card-hover group flex items-center justify-between">
          <div>
            <p className="text-sm font-medium text-gray-300">Active Proposals</p>
            <p className="text-2xl font-bold text-white">{activeProposals}</p>
          </div>
          <ArrowRight size={18} className="text-gray-600 transition-transform group-hover:translate-x-1 group-hover:text-gold-400" />
        </Link>
        <Link to="/orders" className="card-hover group flex items-center justify-between">
          <div>
            <p className="text-sm font-medium text-gray-300">Pending Orders</p>
            <p className="text-2xl font-bold text-white">{activeOrders}</p>
          </div>
          <ArrowRight size={18} className="text-gray-600 transition-transform group-hover:translate-x-1 group-hover:text-gold-400" />
        </Link>
      </div>

      {/* ── Governance params ── */}
      <div className="card">
        <h3 className="mb-3 text-sm font-semibold uppercase tracking-wider text-gray-500">
          Governance Parameters
        </h3>
        <div className="grid grid-cols-2 gap-x-8 gap-y-2 text-sm lg:grid-cols-3">
          {[
            ["Voting Period", `${Number(daoState.votingPeriod) / 86400} days`],
            ["Quorum", `${(daoState.quorumBps / 100).toFixed(0)}%`],
            ["Order Delay", `${Number(daoState.orderDelay) / 3600} hours`],
            ["Invite Expiry", `${Number(daoState.inviteExpiry) / 3600} hours`],
            ["Execution Delay", `${Number(daoState.executionDelay) / 3600} hours`],
            ["Grace Period", `${Number(daoState.gracePeriod) / 86400} days`],
          ].map(([k, v]) => (
            <div key={k} className="flex justify-between py-1">
              <span className="text-gray-500">{k}</span>
              <span className="font-medium text-gray-200">{v}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
