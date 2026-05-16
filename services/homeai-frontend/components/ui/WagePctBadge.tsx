'use client';

import clsx from 'clsx';

export function WagePctBadge({ pct, label }: { pct: number | null; label?: string }) {
  if (pct == null) {
    return <span className="inline-flex items-baseline gap-1 text-xs text-ink-500">—{label && <span>{label}</span>}</span>;
  }
  const over = pct > 30;
  return (
    <span className={clsx(
      'inline-flex items-baseline gap-1 px-1.5 py-0.5 rounded font-mono text-xs',
      over ? 'bg-warn/10 text-warn' : 'bg-good/10 text-good',
    )}>
      <span className="font-bold">{pct.toFixed(1)}%</span>
      {label && <span className="opacity-70">{label}</span>}
    </span>
  );
}
