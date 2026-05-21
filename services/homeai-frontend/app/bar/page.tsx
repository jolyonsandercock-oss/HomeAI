'use client';

import { Section } from '@/components/ui/Section';
import { KPICard } from '@/components/ui/KPICard';
import { WagePctBadge } from '@/components/ui/WagePctBadge';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { SparkLine } from '@/components/ui/SparkLine';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';

interface TodayGross { site: string; gross: string }
interface BarWage   { days: number; labour: string | null; sales: string | null; pct: string | null }
interface TillGroup { grp: string; values: number[]; total_qty: string }

const GRP_LABEL: Record<string, string> = {
  beer: 'Beer', wine: 'Wine', cocktail: 'Cocktails',
  spirit: 'Spirits', hot_drink: 'Hot drinks', soft_drink: 'Soft drinks',
};
const GRP_COLOUR: Record<string, string> = {
  beer: '#f59e0b', wine: '#b91c1c', cocktail: '#ec4899',
  spirit: '#a78bfa', hot_drink: '#84cc16', soft_drink: '#06b6d4',
};

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
          <div className="grid grid-cols-1 sm:grid-cols-4 gap-3">
            <KPICard label="Pub gross today" size="xl" value={gbp(pub?.gross ?? 0)} loading={today.isLoading} />
            {[1, 7, 30].map(d => {
              const r = w(d);
              const pct = r?.pct ? parseFloat(r.pct) : null;
              const lab = r?.labour ? parseFloat(r.labour) : null;
              return (
                <KPICard key={d}
                  label={d === 1 ? 'FOH wage — yesterday' : d === 7 ? 'FOH wage — 7d avg' : 'FOH wage — 30d avg'}
                  value={pct != null ? `${pct.toFixed(1)}%` : '—'}
                  loading={wage.isLoading}
                  rollingAvg={lab != null ? [{ label: 'cost', value: gbp(d === 1 ? lab : lab / d, 0) }] : undefined} />
              );
            })}
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="bar.wage-detail">
        <Section title="Wage % at a glance">
          <div className="tile flex items-center gap-3 flex-wrap">
            {[1, 7, 30].map((d) => {
              const r = w(d);
              const pct = r?.pct ? parseFloat(r.pct) : null;
              return <WagePctBadge key={d} pct={pct} label={`${d}d`} />;
            })}
            <span className="text-xs text-ink-500 ml-auto">threshold 30% · FOH only</span>
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="bar.till-sparks">
        <Section title="Till performance — 7-day qty per drink group">
          {till.isLoading ? <PlaceholderState message="Loading till data…" /> :
           till.data && till.data.length > 0 ? (
            <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
              {till.data.map(g => (
                <div key={g.grp} className="tile">
                  <div className="label">{GRP_LABEL[g.grp] ?? g.grp}</div>
                  <div className="kpi mt-1">{Number(g.total_qty).toLocaleString()}</div>
                  <div className="text-[10px] text-ink-500 mt-0.5">qty over 7 days</div>
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
