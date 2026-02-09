import { formatEther as fmtEther } from "ethers";
import { RANK_NAMES } from "./constants";

/** Truncate an address: 0x1234…5678 */
export function shortAddress(addr) {
  if (!addr) return "—";
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/** Human-readable rank name from uint8 index */
export function rankName(index) {
  return RANK_NAMES[Number(index)] ?? `?${index}`;
}

/** Format wei → "1.234 ETH" */
export function formatETH(wei) {
  if (wei == null) return "—";
  const str = fmtEther(wei);
  const num = parseFloat(str);
  if (num === 0) return "0 ETH";
  if (num < 0.0001) return "<0.0001 ETH";
  return `${num.toFixed(4)} ETH`;
}

/** Format a BigInt token amount (18 decimals) → "12.34" */
export function formatTokens(amount, decimals = 18) {
  if (amount == null) return "—";
  const divisor = 10n ** BigInt(decimals);
  const whole = amount / divisor;
  const frac = amount % divisor;
  const fracStr = frac.toString().padStart(decimals, "0").slice(0, 4);
  return `${whole}.${fracStr}`;
}

/** Unix timestamp → "Feb 15, 2026" */
export function formatDate(ts) {
  if (!ts) return "—";
  return new Date(Number(ts) * 1000).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

/** Unix timestamp → "Feb 15, 2026 14:30" */
export function formatDateTime(ts) {
  if (!ts) return "—";
  return new Date(Number(ts) * 1000).toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

/** Seconds remaining → "3d 14h" or "2h 30m" or "45m" */
export function formatTimeRemaining(seconds) {
  const s = Number(seconds);
  if (s <= 0) return "Expired";
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

/** Voting power as formatted number */
export function formatPower(power) {
  return Number(power).toLocaleString();
}

/** Percentage string: "52.3%" */
export function pct(value, total) {
  if (!total || total === 0n) return "0%";
  const v = Number(value);
  const t = Number(total);
  if (t === 0) return "0%";
  return `${((v / t) * 100).toFixed(1)}%`;
}
