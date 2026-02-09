// ── Epoch ───────────────────────────────────
export const EPOCH_SECONDS = 100 * 86400; // 100 days

// ── Ranks ──────────────────────────────────
export const RANK_NAMES = [
  "G", "F", "E", "D", "C", "B", "A", "S", "SS", "SSS",
];

export const RANK_COLORS = {
  0: "#6b7280", // G  – gray
  1: "#10b981", // F  – emerald
  2: "#3b82f6", // E  – blue
  3: "#06b6d4", // D  – cyan
  4: "#8b5cf6", // C  – violet
  5: "#ec4899", // B  – pink
  6: "#f59e0b", // A  – amber
  7: "#eab308", // S  – yellow
  8: "#f97316", // SS – orange
  9: "#ef4444", // SSS – red
};

export const RANK_BG = {
  0: "bg-gray-500/20",
  1: "bg-emerald-500/20",
  2: "bg-blue-500/20",
  3: "bg-cyan-500/20",
  4: "bg-violet-500/20",
  5: "bg-pink-500/20",
  6: "bg-amber-500/20",
  7: "bg-yellow-500/20",
  8: "bg-orange-500/20",
  9: "bg-red-500/20",
};

export const RANK_TEXT = {
  0: "text-gray-400",
  1: "text-emerald-400",
  2: "text-blue-400",
  3: "text-cyan-400",
  4: "text-violet-400",
  5: "text-pink-400",
  6: "text-amber-400",
  7: "text-yellow-400",
  8: "text-orange-400",
  9: "text-red-400",
};

// ── Governance Proposal Types ──────────────
export const PROPOSAL_TYPES = [
  "Grant Rank",
  "Demote Rank",
  "Change Authority",
  "Change Voting Period",
  "Change Quorum",
  "Change Order Delay",
  "Change Invite Expiry",
  "Change Execution Delay",
  "Block Order",
  "Transfer ERC-20",
];

// ── Order Types ────────────────────────────
export const ORDER_TYPES = [
  "Promotion Grant",
  "Demotion Order",
  "Authority Order",
];

// ── Treasury Action Types ──────────────────
export const ACTION_TYPES = {
  0: "Transfer ETH",
  1: "Transfer ERC-20",
  2: "External Call",
  3: "Add Member Treasurer",
  4: "Update Member Treasurer",
  5: "Remove Member Treasurer",
  6: "Add Address Treasurer",
  7: "Update Address Treasurer",
  8: "Remove Address Treasurer",
  9: "Set Member Token Config",
  10: "Set Address Token Config",
  11: "Transfer NFT",
  12: "Grant Member NFT Access",
  13: "Revoke Member NFT Access",
  14: "Grant Address NFT Access",
  15: "Revoke Address NFT Access",
  16: "Set Call Actions",
  17: "Set Treasurer Calls",
  18: "Add Call Target",
  19: "Remove Call Target",
  20: "Set Treasury Lock",
};

// ── Supported Chain IDs ────────────────────
export const CHAINS = {
  31337: { name: "Hardhat Local", explorer: null },
  421614: { name: "Arbitrum Sepolia", explorer: "https://sepolia.arbiscan.io" },
  42161: { name: "Arbitrum One", explorer: "https://arbiscan.io" },
};
