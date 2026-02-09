/**
 * Simple stat card used on the dashboard.
 */
export default function StatCard({ icon: Icon, label, value, sub, className = "" }) {
  return (
    <div className={`card flex items-start gap-4 ${className}`}>
      {Icon && (
        <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-gray-800">
          <Icon size={18} className="text-gray-400" />
        </div>
      )}
      <div className="min-w-0">
        <p className="text-xs font-medium uppercase tracking-wider text-gray-500">
          {label}
        </p>
        <p className="mt-0.5 truncate text-xl font-bold text-white">{value}</p>
        {sub && <p className="mt-0.5 text-xs text-gray-500">{sub}</p>}
      </div>
    </div>
  );
}
