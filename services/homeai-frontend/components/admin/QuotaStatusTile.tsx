'use client';

import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';
import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { ShieldCheck, AlertTriangle } from 'lucide-react';

interface QuotaRow {
  tier: string;
  ceiling_gbp: string;
  spent_gbp: string;
  enforce_mode: boolean;
  at_ceiling: boolean;
  call_count_today: string;
  shadow_blocked_today: string;
  remaining_gbp: string;
  spent_gbp_7d: string;
  call_count_7d: string;
}

const TIER_DESC: Record<string, string> = {
  P0: 'Financial recon · bank surveillance · cashup (30% floor)',
  P1: 'Email triage · compliance · invoice extraction',
  P2: 'RAG queries · knowledge lookups · Karpathy reads',
  P3: 'News digest · exploratory · Storyblok',
};

export function QuotaStatusTile() {
  const q = useSlug<QuotaRow>('quota_status_today', {}, { refetchInterval: 60_000 });

  if (q.isLoading) return <PlaceholderState message="Loading quota…" />;
  if (!q.data || q.data.length === 0) return null;

  const total_spent  = q.data.reduce((acc, r) => acc + Number(r.spent_gbp), 0);
  const total_ceiling = q.data.reduce((acc, r) => acc + Number(r.ceiling_gbp), 0);
  const anyEnforce = q.data.some((r) => r.enforce_mode);

  return (
    <Section
      title="AI quota — today"
      action={
        <span className={'text-xs inline-flex items-center gap-1 ' +
          (anyEnforce ? 'text-emerald-400' : 'text-amber-500')}>
          {anyEnforce ? <ShieldCheck size={12}/> : <AlertTriangle size={12}/>}
          {anyEnforce ? 'enforcing' : 'shadow mode'}
        </span>
      }
    >
      <div className="tile p-0 overflow-hidden">
        <div className="px-3 py-2.5 flex items-baseline justify-between border-b border-ink-200">
          <div>
            <div className="text-[10px] uppercase tracking-wider text-ink-500">Total today</div>
            <div className="text-lg font-mono text-ink-800">
              {gbp(total_spent, 4)} <span className="text-xs text-ink-500">/ {gbp(total_ceiling, 2)}</span>
            </div>
          </div>
          <div className="text-xs text-ink-500 max-w-md text-right">
            {anyEnforce
              ? 'Enforce mode active — calls past tier ceiling will return 429.'
              : 'Shadow mode — would-have-blocked decisions logged to ai_usage.would_block_reason but not enforced. Flip enforce_mode in quota_allocations after legacy import settles.'}
          </div>
        </div>
        <table className="w-full text-sm">
          <thead className="text-xs text-ink-500 uppercase tracking-wider">
            <tr>
              <th className="text-left font-medium px-3 py-1.5">Tier</th>
              <th className="text-left font-medium">Use</th>
              <th className="text-right font-medium px-3">Today</th>
              <th className="text-right font-medium px-3">Ceiling</th>
              <th className="text-right font-medium px-3">Remaining</th>
              <th className="text-right font-medium px-3">7d £</th>
              <th className="text-right font-medium px-3">7d calls</th>
              <th className="text-right font-medium px-3">Shadow 429</th>
            </tr>
          </thead>
          <tbody>
            {q.data.map((r) => {
              const pct = Number(r.spent_gbp) / Math.max(Number(r.ceiling_gbp), 1e-6) * 100;
              return (
                <tr key={r.tier} className="border-t border-ink-200">
                  <td className="px-3 py-1.5 font-mono text-ink-800">{r.tier}</td>
                  <td className="text-xs text-ink-500 max-w-[18rem]">{TIER_DESC[r.tier] ?? ''}</td>
                  <td className="px-3 text-right font-mono">
                    <div className={r.at_ceiling ? 'text-red-400' : 'text-ink-700'}>
                      {gbp(r.spent_gbp, 4)}
                      <span className="text-xs text-ink-500 ml-1">· {r.call_count_today}</span>
                    </div>
                    <div className="h-1 bg-ink-100 rounded mt-1">
                      <div className={'h-1 rounded ' + (r.at_ceiling ? 'bg-red-500' : 'bg-amber-500')}
                           style={{ width: Math.min(100, pct) + '%' }} />
                    </div>
                  </td>
                  <td className="px-3 text-right font-mono text-ink-500">{gbp(r.ceiling_gbp, 2)}</td>
                  <td className="px-3 text-right font-mono text-ink-700">{gbp(r.remaining_gbp, 4)}</td>
                  <td className="px-3 text-right font-mono text-ink-700">{gbp(r.spent_gbp_7d, 4)}</td>
                  <td className="px-3 text-right text-xs text-ink-500">{r.call_count_7d}</td>
                  <td className="px-3 text-right text-xs">
                    {Number(r.shadow_blocked_today) > 0
                      ? <span className="text-amber-500">{r.shadow_blocked_today}</span>
                      : <span className="text-ink-500">0</span>}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </Section>
  );
}
