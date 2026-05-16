'use client';

import { Section } from '@/components/ui/Section';
import { KPICard } from '@/components/ui/KPICard';
import { WagePctBadge } from '@/components/ui/WagePctBadge';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';

interface TodayGross { site: string; gross: string }
interface WagePct { days: number; pct: string | null }

export default function BarPage() {
  const today = useSlug<TodayGross>('frontend_today_gross');
  const wage  = useSlug<WagePct>('frontend_wage_pct_summary');
  const pub   = today.data?.find(r => r.site === 'malthouse');

  return (
    <div className="space-y-6">
      <SandboxWrapper id="bar.kpi" label="Bar KPIs">
        <Section title="Bar — today">
          <div className="grid grid-cols-3 gap-3">
            <KPICard label="Pub gross today" size="xl" value={gbp(pub?.gross ?? 0)} loading={today.isLoading} />
            <KPICard label="Wage % yesterday" value={
              wage.data?.find(d => Number(d.days) === 1)?.pct
                ? `${parseFloat(wage.data!.find(d => Number(d.days) === 1)!.pct!).toFixed(1)}%`
                : '—'
            } />
            <KPICard label="7d wage %" value={
              wage.data?.find(d => Number(d.days) === 7)?.pct
                ? `${parseFloat(wage.data!.find(d => Number(d.days) === 7)!.pct!).toFixed(1)}%`
                : '—'
            } />
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="bar.wage-detail">
        <Section title="Wage %">
          <div className="tile flex items-center gap-3 flex-wrap">
            {[1, 7, 30].map((d) => {
              const r = wage.data?.find(x => Number(x.days) === d);
              const pct = r?.pct ? parseFloat(r.pct) : null;
              return <WagePctBadge key={d} pct={pct} label={`${d}d`} />;
            })}
            <span className="text-xs text-ink-500 ml-auto">threshold 30%</span>
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="bar.product">
        <Section title="Product performance">
          <PlaceholderState
            message="Per-product sales pending ICRTouch dept-level ingest"
            hint="ALCOHOL SALES department total is captured (used in daily reality email). Per-PLU breakdown needs touchoffice_plu_sales table populated." />
        </Section>
      </SandboxWrapper>
    </div>
  );
}
