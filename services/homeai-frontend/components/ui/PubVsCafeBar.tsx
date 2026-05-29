'use client';

/**
 * U195 — Pub vs Cafe split bar (mini horizontal bar chart).
 *
 * Replaces "Pub £X / Café £Y" raw text with a visual ratio.
 */
export function PubVsCafeBar({ pub, cafe, format }: { pub: number; cafe: number; format?: (n: number) => string }) {
  const fmt = format ?? ((n: number) => `£${Math.round(n).toLocaleString()}`);
  const total = pub + cafe;
  if (total <= 0) {
    return <div className="text-ink-500 text-xs">No revenue yet today.</div>;
  }
  const pubPct = (pub / total) * 100;

  return (
    <div className="space-y-1">
      <div className="flex h-3 rounded overflow-hidden bg-ink-200">
        <div className="bg-amber-500 transition-all" style={{ width: `${pubPct}%` }} title={`Pub ${fmt(pub)}`} />
        <div className="bg-info transition-all" style={{ width: `${100 - pubPct}%` }} title={`Cafe ${fmt(cafe)}`} />
      </div>
      <div className="flex justify-between text-xs font-mono">
        <span className="text-amber-500">Pub <strong className="text-ink-900">{fmt(pub)}</strong> · {pubPct.toFixed(0)}%</span>
        <span className="text-info">Cafe <strong className="text-ink-900">{fmt(cafe)}</strong> · {(100 - pubPct).toFixed(0)}%</span>
      </div>
    </div>
  );
}
