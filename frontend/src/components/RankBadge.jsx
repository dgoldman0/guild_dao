import { RANK_NAMES, RANK_COLORS, RANK_BG, RANK_TEXT } from "../lib/constants";

/**
 * Coloured rank badge.
 * `rank` is a uint8 index (0–9).
 * `size` can be "sm" | "md" | "lg".
 */
export default function RankBadge({ rank, size = "md" }) {
  const idx = Number(rank);
  const name = RANK_NAMES[idx] ?? "?";
  const color = RANK_COLORS[idx] ?? "#6b7280";
  const bg = RANK_BG[idx] ?? "bg-gray-500/20";
  const text = RANK_TEXT[idx] ?? "text-gray-400";

  const sizes = {
    sm: "px-1.5 py-0.5 text-[10px]",
    md: "px-2 py-0.5 text-xs",
    lg: "px-3 py-1 text-sm",
  };

  return (
    <span
      className={`inline-flex items-center justify-center rounded-md font-bold tracking-wider ${bg} ${text} ${sizes[size]}`}
    >
      {name}
    </span>
  );
}

/** Big decorative rank badge for profile/detail views */
export function RankBadgeLarge({ rank }) {
  const idx = Number(rank);
  const name = RANK_NAMES[idx] ?? "?";
  const color = RANK_COLORS[idx] ?? "#6b7280";

  return (
    <div
      className="flex h-16 w-16 items-center justify-center rounded-2xl text-xl font-extrabold"
      style={{
        backgroundColor: `${color}20`,
        color: color,
        boxShadow: `0 0 24px -4px ${color}40`,
      }}
    >
      {name}
    </div>
  );
}
