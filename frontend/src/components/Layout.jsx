import { useState } from "react";
import { NavLink, useLocation } from "react-router-dom";
import {
  LayoutDashboard, Users, Vote, ScrollText, Landmark,
  UserCircle, Wallet, LogOut, Shield, AlertCircle, CheckCircle, Info, X,
  AlertTriangle, ChevronDown,
} from "lucide-react";
import { useWeb3 } from "../context/Web3Context";
import { shortAddress, rankName } from "../lib/format";
import { RANK_COLORS, CHAINS } from "../lib/constants";

const NAV = [
  { to: "/", icon: LayoutDashboard, label: "Dashboard" },
  { to: "/members", icon: Users, label: "Members" },
  { to: "/governance", icon: Vote, label: "Governance" },
  { to: "/orders", icon: ScrollText, label: "Orders" },
  { to: "/treasury", icon: Landmark, label: "Treasury" },
  { to: "/profile", icon: UserCircle, label: "My Profile" },
];

function SidebarLink({ to, icon: Icon, label }) {
  return (
    <NavLink
      to={to}
      end={to === "/"}
      className={({ isActive }) =>
        `flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium transition-colors ${
          isActive
            ? "bg-gold-400/10 text-gold-400"
            : "text-gray-400 hover:bg-gray-800 hover:text-gray-200"
        }`
      }
    >
      <Icon size={18} />
      {label}
    </NavLink>
  );
}

function ToastBar() {
  const { toast } = useWeb3();
  const [showRaw, setShowRaw] = useState(false);

  if (!toast) return null;

  const isRichError = toast.type === "error" && toast.errorTitle;

  const colors = {
    info: "border-blue-500/50 bg-blue-500/10 text-blue-300",
    success: "border-emerald-500/50 bg-emerald-500/10 text-emerald-300",
    error: "border-red-500/50 bg-red-900/30 text-red-200",
  };
  const icons = {
    info: <Info size={16} className="shrink-0 mt-0.5" />,
    success: <CheckCircle size={16} className="shrink-0 mt-0.5" />,
    error: <AlertTriangle size={16} className="shrink-0 mt-0.5 text-red-400" />,
  };

  return (
    <div className="fixed bottom-6 right-6 z-50 animate-slide-up max-w-md">
      <div
        className={`rounded-lg border shadow-2xl ${colors[toast.type]}`}
      >
        {/* Main content row */}
        <div className="flex items-start gap-3 px-4 py-3">
          {icons[toast.type]}
          <div className="flex-1 min-w-0">
            {isRichError ? (
              <>
                {/* Label line */}
                <p className="text-xs font-medium text-red-400/70">{toast.msg}</p>
                {/* Error title */}
                <p className="text-sm font-semibold text-red-200 mt-0.5">
                  {toast.errorTitle}
                </p>
                {/* Actionable hint */}
                <p className="text-xs text-red-300/80 mt-1 leading-relaxed">
                  {toast.errorHint}
                </p>
                {/* Raw error data (collapsible) */}
                {toast.errorRaw && (
                  <button
                    onClick={() => setShowRaw((p) => !p)}
                    className="mt-1.5 flex items-center gap-1 text-[10px] text-red-400/50 hover:text-red-400/80 transition-colors"
                  >
                    <ChevronDown size={10} className={`transition-transform ${showRaw ? "rotate-180" : ""}`} />
                    Technical details
                  </button>
                )}
                {showRaw && toast.errorRaw && (
                  <code className="mt-1 block break-all rounded bg-red-950/50 px-2 py-1 text-[10px] font-mono text-red-400/60">
                    {toast.errorRaw}
                  </code>
                )}
              </>
            ) : (
              <p className="text-sm">{toast.msg}</p>
            )}
          </div>
          {/* Dismiss button */}
          {toast.dismiss && (
            <button
              onClick={toast.dismiss}
              className="shrink-0 rounded p-0.5 hover:bg-white/10 transition-colors"
            >
              <X size={14} />
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

export default function Layout({ children }) {
  const { isConnected, account, chainId, myMember, connect, disconnect, loading, error } = useWeb3();
  const chainInfo = CHAINS[chainId];

  return (
    <div className="flex h-screen overflow-hidden">
      {/* ── Sidebar ──────────────────────────── */}
      <aside className="flex w-60 flex-col border-r border-gray-800 bg-gray-950">
        {/* Logo */}
        <div className="flex items-center gap-3 border-b border-gray-800 px-5 py-5">
          <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-gold-400/20">
            <Shield size={20} className="text-gold-400" />
          </div>
          <div>
            <h1 className="text-gold-gradient text-lg font-bold leading-tight">
              The Guild
            </h1>
            <p className="text-[10px] font-medium uppercase tracking-widest text-gray-500">
              DAO
            </p>
          </div>
        </div>

        {/* Navigation */}
        <nav className="flex-1 space-y-1 overflow-y-auto px-3 py-4">
          {NAV.map((n) => (
            <SidebarLink key={n.to} {...n} />
          ))}
        </nav>

        {/* Network indicator */}
        {chainInfo && (
          <div className="border-t border-gray-800 px-4 py-3">
            <div className="flex items-center gap-2 text-xs text-gray-500">
              <span className="h-2 w-2 rounded-full bg-emerald-500" />
              {chainInfo.name}
            </div>
          </div>
        )}
      </aside>

      {/* ── Main area ────────────────────────── */}
      <div className="flex flex-1 flex-col overflow-hidden">
        {/* Header */}
        <header className="flex h-16 items-center justify-between border-b border-gray-800 bg-gray-950/80 px-6 backdrop-blur">
          <div />
          <div className="flex items-center gap-3">
            {isConnected && myMember && (
              <div className="flex items-center gap-2 rounded-lg border border-gray-800 px-3 py-1.5 text-sm">
                <span
                  className="inline-block h-2 w-2 rounded-full"
                  style={{ backgroundColor: RANK_COLORS[Number(myMember.rank)] }}
                />
                <span className="font-medium" style={{ color: RANK_COLORS[Number(myMember.rank)] }}>
                  {rankName(myMember.rank)}
                </span>
                <span className="text-gray-500">#{Number(myMember.id)}</span>
              </div>
            )}
            {isConnected ? (
              <div className="flex items-center gap-2">
                <span className="rounded-lg border border-gray-800 px-3 py-1.5 text-sm text-gray-300">
                  {shortAddress(account)}
                </span>
                <button
                  onClick={disconnect}
                  className="rounded-lg p-2 text-gray-500 hover:bg-gray-800 hover:text-gray-300"
                  title="Disconnect"
                >
                  <LogOut size={16} />
                </button>
              </div>
            ) : (
              <button onClick={connect} disabled={loading} className="btn-gold">
                <Wallet size={16} />
                Connect Wallet
              </button>
            )}
          </div>
        </header>

        {/* Error banner */}
        {error && (
          <div className="border-b border-red-500/30 bg-red-500/10 px-6 py-3 text-sm text-red-300">
            <AlertCircle size={14} className="mr-2 inline" />
            {error}
          </div>
        )}

        {/* Page content */}
        <main className="flex-1 overflow-y-auto px-6 py-6">{children}</main>
      </div>

      <ToastBar />
    </div>
  );
}
