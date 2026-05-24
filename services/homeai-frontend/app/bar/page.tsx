'use client';

import { Section } from '@/components/ui/Section';
import { KPICard } from '@/components/ui/KPICard';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { SparkLine } from '@/components/ui/SparkLine';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';
import clsx from 'clsx';

interface TodayGross { site: string; gross: string }
// U225 T5: wage summary now includes `purchases` (Beverage vendor invoices).
interface BarWage   { days: number; labour: string | null; sales: string | null; purchases: string | null; pct: string | null }
// U225 T5: till groups now expose £ value (total_value) instead of count (total_qty).
interface TillGroup { grp: string; values: number[]; total_value: string }

const GRP_LABEL: Record<string, string> = {
  beer: 'Beer', wine: 'Wine', cocktail: 'Cocktails',
  spirit: 'Spirits', hot_drink: 'Hot drinks', soft_drink: 'Soft drinks',
};
const GRP_COLOUR: Record<string, string> = {
  beer: '#f59e0b', wine: '#b91c1c', cocktail: '#ec4899',
  spirit: '#a78bfa', hot_drink: '#84cc16', soft_drink: '#06b6d4',
};

// Colour band for wage %: <30 good (green), ≥30 warn (red). Matches the
// existing WagePctBadge convention (threshold 30%, FOH only).
function wagePctTone(pct: number | null): { box: string; text: string; label: string } {
  if (pct == null) return { box: 'bg-ink-100 border-ink-200', text: 'text-ink-500', label: '—' };
  if (pct < 30)    return { box: 'bg-good/10 border-good/40', text: 'text-good', label: `${pct.toFixed(1)}%` };
  return { box: 'bg-warn/10 border-warn/40', text: 'text-warn', label: `${pct.toFixed(1)}%` };
}

const PERIOD_LABELS: Record<number, string> = { 1: 'Yesterday', 7: 'Last 7 days', 30: 'Last 30 days' };

export default function BarPage() {
  const today = useSlug<TodayGross>('frontend_today_gross');
  const wage  = useSlug<BarWage>('bar_wage_summary');
  const till  = useSlug<TillGroup>('bar_till_groups_spark_7d');
  const pub   = today.data?.find(r => r.site === 'malthouse');

  const w = (d: number) => wage.data?.find(x => Number(x.days) === d);

  return (
    <div className="space-y-6">
      <SandboxWrapper id="bar.kpi" label="Bar KPIs">
        <Section title="Bar — today">
          <KPICard label="Pub gross today" size="xl" value={gbp(pub?.gross ?? 0)} loading={today.isLoading} />
        </Section>
      </SandboxWrapper>

      {/* U225 T5: 3 period boxes (Yesterday / 7d / 30d). Each shows wage £,
          sales £, purchases £ (Beverage invoices), wage %, colour-coded. */}
      <SandboxWrapper id="bar.period-boxes">
        <Section title="Wage · sales · purchases">
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
            {[1, 7, 30].map(d => {
              const r = w(d);
              const pct = r?.pct ? parseFloat(r.pct) : null;
              const labour    = r?.labour    ? parseFloat(r.labour)    : null;
              const sales     = r?.sales     ? parseFloat(r.sales)     : null;
              const purchases = r?.purchases ? parseFloat(r.purchases) : null;
              const tone = wagePctTone(pct);
              return (
                <div key={d} className={clsx('tile border rounded-lg p-3 transition-colors', tone.box)}>
                  <div className="flex items-baseline justify-between">
                    <div className="label">{PERIOD_LABELS[d]}</div>
                    <div className={clsx('font-mono font-bold text-lg', tone.text)}>{tone.label}</div>
                  </div>
                  <div className="mt-2 grid grid-cols-3 gap-2 text-xs">
                    <div>
                      <div className="text-ink-500 uppercase text-[9px] tracking-wide">Wage</div>
                      <div className="font-mono text-ink-900 mt-0.5">
                        {labour != null ? gbp(labour, 0) : <span className="text-ink-400">—</span>}
                      </div>
                    </div>
                    <div>
                      <div className="text-ink-500 uppercase text-[9px] tracking-wide">Sales</div>
                      <div className="font-mono text-ink-900 mt-0.5">
                        {sales != null ? gbp(sales, 0) : <span className="text-ink-400">—</span>}
                      </div>
                    </div>
                    <div>
                      <div className="text-ink-500 uppercase text-[9px] tracking-wide">Purch.</div>
                      <div className="font-mono text-ink-900 mt-0.5">
                        {purchases != null ? gbp(purchases, 0) : <span className="text-ink-400">—</span>}
                      </div>
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
          <div className="text-[10px] text-ink-500 mt-1">
            Wage % = FOH labour ÷ Pub sales · threshold 30%.
            Purchases = Beverage vendor invoices.
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="bar.till-sparks">
        <Section title="Till performance — 7-day £ per drink group">
          {till.isLoading ? <PlaceholderState message="Loading till data…" /> :
           till.data && till.data.length > 0 ? (
            <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
              {till.data.map(g => (
                <div key={g.grp} className="tile">
                  <div className="label">{GRP_LABEL[g.grp] ?? g.grp}</div>
                  <div className="kpi mt-1">{gbp(Number(g.total_value) || 0, 0)}</div>
                  <div className="text-[10px] text-ink-500 mt-0.5">£ over 7 days</div>
                  <div className="mt-2 h-8 opacity-70">
                    <SparkLine values={g.values.map(v => Number(v) || 0)} colour={GRP_COLOUR[g.grp]} />
                  </div>
                </div>
              ))}
            </div>
          ) : <PlaceholderState message="No till data yet." />}
        </Section>
      </SandboxWrapper>
    </div>
  );
}
