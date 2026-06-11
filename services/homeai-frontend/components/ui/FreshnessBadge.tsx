'use client';

import { useSlug } from '@/lib/hooks';

interface FreshRow { source: string; last_update: string | null }

/** UX audit 2026-06-11: stale feeds kept presenting as broken pages ("why
 * isn't this populating"). Every scrape-fed surface shows when its source
 * last updated — green <6h, amber <24h, red beyond (or never). */
export function FreshnessBadge({ source, staleHours = 24 }: { source: string; staleHours?: number }) {
  const fresh = useSlug<FreshRow>('data_freshness', {}, { refetchInterval: 5 * 60_000 });
  const row = (fresh.data ?? []).find(r => r.source === source);
  if (!row) return null;
  if (!row.last_update) {
    return <span className="text-2xs px-1.5 py-0.5 rounded bg-red-900/30 text-red-400" title={`${source}: never updated`}>no data</span>;
  }
  const ageH = (Date.now() - new Date(row.last_update).getTime()) / 36e5;
  const cls = ageH < 6 ? 'bg-emerald-900/30 text-emerald-400'
            : ageH < staleHours ? 'bg-amber-900/30 text-amber-400'
            : 'bg-red-900/30 text-red-400';
  const label = ageH < 1 ? `${Math.max(1, Math.round(ageH * 60))}m ago`
              : ageH < 48 ? `${Math.round(ageH)}h ago`
              : `${Math.round(ageH / 24)}d ago`;
  return (
    <span className={`text-2xs px-1.5 py-0.5 rounded ${cls}`}
          title={`${source} last updated ${new Date(row.last_update).toLocaleString()}`}>
      {label}
    </span>
  );
}
