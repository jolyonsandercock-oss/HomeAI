'use client';

import { Section } from '@/components/ui/Section';
import { KPICard } from '@/components/ui/KPICard';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { SparkLine } from '@/components/ui/SparkLine';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';

interface TodayGross { site: string; gross: string }
interface CafeDeptToday { department: string; report_date: string; value: string; quantity: string }
interface CafeDeptSpark { department: string; values: number[]; total_value: string }

// Friendly labels + colours per cafe department.
const DEPT_LABEL: Record<string, string> = {
  'Cafe Ice Cream':   'Ice cream',
  'Cafe Soft Drinks': 'Soft drinks',
  'HOT DRINKS':       'Hot drinks',
  'ALCOHOL SALES':    'Alcohol',
  'SNACK':            'Snacks',
};
const DEPT_COLOUR: Record<string, string> = {
  'Cafe Ice Cream':   '#06b6d4',
  'Cafe Soft Drinks': '#84cc16',
  'HOT DRINKS':       '#f59e0b',
  'ALCOHOL SALES':    '#a78bfa',
  'SNACK':            '#ec4899',
};

const HEADLINE_DEPTS = ['Cafe Ice Cream', 'Cafe Soft Drinks', 'HOT DRINKS'];

export default function CafePage() {
  const today    = useSlug<TodayGross>('frontend_today_gross');
  const todayDpt = useSlug<CafeDeptToday>('cafe_today_depts');
  const spark7d  = useSlug<CafeDeptSpark>('cafe_dept_spark_7d');
  const cafe     = today.data?.find(r => r.site === 'sandwich');

  const findToday = (dept: string) => todayDpt.data?.find(r => r.department === dept);

  return (
    <div className="space-y-6">
      <SandboxWrapper id="cafe.kpi" label="Café KPIs">
        <Section title="Café — today">
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
            <KPICard label="Café gross today" size="xl" value={gbp(cafe?.gross ?? 0)} loading={today.isLoading} />
            {HEADLINE_DEPTS.map(dept => {
              const r = findToday(dept);
              const v = r?.value ? parseFloat(r.value) : 0;
              const q = r?.quantity ? parseFloat(r.quantity) : 0;
              return (
                <KPICard
                  key={dept}
                  label={DEPT_LABEL[dept] ?? dept}
                  value={gbp(v)}
                  loading={todayDpt.isLoading}
                  rollingAvg={q > 0 ? [{ label: 'units', value: Math.round(q) }] : undefined}
                />
              );
            })}
          </div>
          {todayDpt.data && todayDpt.data.length > 0 && (
            <div className="text-[10px] text-ink-500 mt-2">
              From most recent scrape · {todayDpt.data[0]?.report_date}
            </div>
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="cafe.till-sparks">
        <Section title="Till — 7-day £ per cafe department">
          {spark7d.isLoading ? <PlaceholderState message="Loading till data…" /> :
           spark7d.data && spark7d.data.length > 0 ? (
            <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
              {spark7d.data
                .filter(g => parseFloat(g.total_value) > 0)
                .map(g => (
                <div key={g.department} className="tile">
                  <div className="label">{DEPT_LABEL[g.department] ?? g.department}</div>
                  <div className="kpi mt-1">{gbp(Number(g.total_value) || 0, 0)}</div>
                  <div className="text-[10px] text-ink-500 mt-0.5">£ over 7 days</div>
                  <div className="mt-2 h-8 opacity-70">
                    <SparkLine values={g.values.map(v => Number(v) || 0)} colour={DEPT_COLOUR[g.department] ?? '#94a3b8'} />
                  </div>
                </div>
              ))}
            </div>
          ) : <PlaceholderState message="No cafe till data scraped yet." />}
        </Section>
      </SandboxWrapper>
    </div>
  );
}
