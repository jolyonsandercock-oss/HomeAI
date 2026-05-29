'use client';

/**
 * U187 — Waterfall chart for P&L decomposition.
 *
 * Pure SVG. Inputs: ordered steps where positive bars stack up and
 * negative bars drag down; final bar (subtotal) is highlighted.
 */
interface WaterfallStep {
  label: string;
  value: number;   // positive = revenue/add, negative = cost
  isSubtotal?: boolean;
  colour?: string;
}
interface WaterfallProps {
  steps: WaterfallStep[];
  height?: number;
  format?: (n: number) => string;
}

export function Waterfall({ steps, height = 120, format }: WaterfallProps) {
  const fmt = format ?? ((n: number) => `£${Math.round(n).toLocaleString()}`);

  // Compute running total + min/max for scaling
  let running = 0;
  const bars: { x: number; w: number; y: number; h: number; v: number; lbl: string; col: string; sub: boolean }[] = [];
  const w_per_bar = 100 / steps.length;
  let lo = 0, hi = 0;

  for (let i = 0; i < steps.length; i++) {
    const s = steps[i];
    const start = s.isSubtotal ? 0 : running;
    const end   = s.isSubtotal ? s.value : running + s.value;
    if (!s.isSubtotal) running += s.value;
    else running = s.value;
    bars.push({
      x: i * w_per_bar + w_per_bar * 0.1,
      w: w_per_bar * 0.8,
      y: Math.min(start, end),
      h: Math.abs(end - start),
      v: s.value,
      lbl: s.label,
      col: s.colour ?? (s.isSubtotal ? '#f59e0b' : s.value >= 0 ? '#16a34a' : '#dc2626'),
      sub: !!s.isSubtotal,
    });
    lo = Math.min(lo, Math.min(start, end));
    hi = Math.max(hi, Math.max(start, end));
  }

  const range = hi - lo || 1;
  const scaleY = (v: number) => 100 - ((v - lo) / range) * 100;

  return (
    <div>
      <svg viewBox="0 0 100 100" preserveAspectRatio="none" style={{ height, width: '100%' }}>
        {bars.map((b, i) => {
          const y = scaleY(b.y + b.h);
          const h = (b.h / range) * 100;
          return (
            <g key={i}>
              <rect
                x={b.x} y={y} width={b.w} height={h}
                fill={b.col}
                opacity={b.sub ? 1 : 0.85}
                stroke={b.sub ? '#fbbf24' : 'none'}
                strokeWidth={b.sub ? 0.5 : 0}
                vectorEffect="non-scaling-stroke"
              />
            </g>
          );
        })}
      </svg>
      <div className="grid mt-1" style={{ gridTemplateColumns: `repeat(${steps.length}, 1fr)` }}>
        {bars.map((b, i) => (
          <div key={i} className="text-xs text-center">
            <div className="text-ink-500 truncate">{b.lbl}</div>
            <div className="font-mono text-ink-700">{fmt(b.v)}</div>
          </div>
        ))}
      </div>
    </div>
  );
}
