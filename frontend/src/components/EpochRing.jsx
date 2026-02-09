/**
 * Circular SVG ring showing progress through the current 100-day epoch.
 */
export default function EpochRing({
  progress = 0,
  label = "",
  sublabel = "",
  size = 140,
  strokeWidth = 10,
  color = "#d4a843",
  trackColor = "#1f2937",
}) {
  const r = (size - strokeWidth) / 2;
  const circ = 2 * Math.PI * r;
  const offset = circ * (1 - Math.min(Math.max(progress, 0), 1));

  return (
    <div className="flex flex-col items-center gap-2">
      <div className="relative" style={{ width: size, height: size }}>
        <svg width={size} height={size} className="-rotate-90">
          {/* Track */}
          <circle
            cx={size / 2}
            cy={size / 2}
            r={r}
            stroke={trackColor}
            strokeWidth={strokeWidth}
            fill="none"
          />
          {/* Progress arc */}
          <circle
            cx={size / 2}
            cy={size / 2}
            r={r}
            stroke={color}
            strokeWidth={strokeWidth}
            fill="none"
            strokeDasharray={circ}
            strokeDashoffset={offset}
            strokeLinecap="round"
            className="transition-all duration-700 ease-out"
          />
        </svg>
        {/* Centered label (overlaid) */}
        <div className="absolute inset-0 flex flex-col items-center justify-center">
          <span className="text-2xl font-bold text-white">
            {Math.round(progress * 100)}%
          </span>
          {label && (
            <span className="text-[11px] font-medium text-gray-400">{label}</span>
          )}
        </div>
      </div>
      {sublabel && (
        <p className="text-xs text-gray-500">{sublabel}</p>
      )}
    </div>
  );
}
