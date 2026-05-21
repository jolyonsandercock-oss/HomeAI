'use client';

/**
 * U190 — Stratified action queue.
 *
 * Groups action queue by urgency_bucket (overdue / today / this_week / backlog).
 */
import clsx from 'clsx';

interface ActionRow {
  urgency_bucket: 'overdue' | 'today' | 'this_week' | 'backlog';
  source: string;
  ref: string;
  severity: string;
  kind: string;
  title: string;
  age_days: number;
  realm: string;
}

const BUCKETS: { key: ActionRow['urgency_bucket']; label: string; tone: string }[] = [
  { key: 'overdue',   label: 'OVERDUE',   tone: 'text-warn' },
  { key: 'today',     label: 'TODAY',     tone: 'text-amber-500' },
  { key: 'this_week', label: 'THIS WEEK', tone: 'text-amber-400' },
  { key: 'backlog',   label: 'BACKLOG',   tone: 'text-ink-500' },
];

function sevBadge(sev: string) {
  if (sev === 'critical') return 'bg-warn/20 text-warn';
  if (sev === 'high')     return 'bg-amber-500/20 text-amber-500';
  if (sev === 'medium')   return 'bg-amber-400/15 text-amber-400';
  return 'bg-ink-200 text-ink-500';
}

export function StratifiedActionQueue({ rows }: { rows: ActionRow[] }) {
  if (!rows || rows.length === 0) {
    return <div className="text-ink-500 text-sm">No actions outstanding.</div>;
  }

  const grouped: Record<string, ActionRow[]> = {};
  for (const r of rows) (grouped[r.urgency_bucket] ||= []).push(r);

  return (
    <div className="space-y-4">
      {BUCKETS.map(b => {
        const items = grouped[b.key] ?? [];
        if (items.length === 0) return null;
        return (
          <div key={b.key}>
            <div className={clsx('label mb-1', b.tone)}>
              {b.label} <span className="text-ink-500">· {items.length}</span>
            </div>
            <div className="space-y-1">
              {items.slice(0, 20).map((r, i) => (
                <div key={`${r.source}-${r.ref}-${i}`} className="flex items-center gap-2 text-xs">
                  <span className={clsx('inline-block px-1.5 py-0.5 rounded text-[10px] uppercase tracking-wider', sevBadge(r.severity))}>
                    {r.severity}
                  </span>
                  <span className="text-ink-700 truncate flex-1" title={r.title}>{r.title}</span>
                  <span className="text-ink-500 font-mono text-[10px]">
                    {r.kind}{r.age_days > 0 ? ` · ${r.age_days}d` : ''}
                  </span>
                </div>
              ))}
              {items.length > 20 && (
                <div className="text-ink-500 text-[10px]">+{items.length - 20} more</div>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}
