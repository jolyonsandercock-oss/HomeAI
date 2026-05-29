'use client';

/**
 * U186 — RangeBand: today vs typical P10/P50/P90 range.
 *
 * Shows a horizontal bar from min..max with shaded p10..p90 region and a
 * dot for today. Tells "where today sits in typical range" at a glance.
 */
interface RangeBandProps {
  value: number;
  lo: number;
  p10: number;
  p50: number;
  p90: number;
  hi: number;
  label?: string;
  format?: (n: number) => string;
}

export function RangeBand({ value, lo, p10, p50, p90, hi, label, format }: RangeBandProps) {
  const fmt = format ?? ((n: number) => `£${n.toFixed(0)}`);
  const range = hi - lo || 1;
  const pct = (n: number) => Math.max(0, Math.min(100, ((n - lo) / range) * 100));

  return (
    <div className="space-y-1">
      {label && <div className="label">{label}</div>}
      <div className="relative h-2 bg-ink-200 rounded">
        {/* P10-P90 typical band */}
        <div
          className="absolute h-2 bg-amber-500/30 rounded"
          style={{ left: `${pct(p10)}%`, width: `${pct(p90) - pct(p10)}%` }}
        />
        {/* P50 median tick */}
        <div
          className="absolute h-2 w-px bg-amber-400"
          style={{ left: `${pct(p50)}%` }}
        />
        {/* Today dot */}
        <div
          className={
            'absolute w-3 h-3 rounded-full border-2 border-ink-50 -top-0.5 ' +
            (value >= p90 ? 'bg-good' : value <= p10 ? 'bg-warn' : 'bg-amber-400')
          }
          style={{ left: `calc(${pct(value)}% - 6px)` }}
          title={`Today: ${fmt(value)} (P10=${fmt(p10)}, P50=${fmt(p50)}, P90=${fmt(p90)})`}
        />
      </div>
      <div className="flex justify-between text-xs text-ink-500 font-mono">
        <span>{fmt(lo)}</span>
        <span className="text-ink-700">{fmt(value)}</span>
        <span>{fmt(hi)}</span>
      </div>
    </div>
  );
}
