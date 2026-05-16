'use client';

import { Section } from '@/components/ui/Section';
import { KPICard } from '@/components/ui/KPICard';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';

interface TodayGross { site: string; gross: string }

export default function CafePage() {
  const today = useSlug<TodayGross>('frontend_today_gross');
  const cafe = today.data?.find(r => r.site === 'sandwich');

  return (
    <div className="space-y-6">
      <SandboxWrapper id="cafe.kpi" label="Café KPIs">
        <Section title="Café — today">
          <div className="grid grid-cols-3 gap-3">
            <KPICard label="Café gross today" size="xl" value={gbp(cafe?.gross ?? 0)} loading={today.isLoading} />
            <KPICard label="Ice cream"   value={<span className="text-ink-500">live tomorrow</span> as unknown as string} />
            <KPICard label="Soft drinks" value={<span className="text-ink-500">live tomorrow</span> as unknown as string} />
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="cafe.product">
        <Section title="Category split">
          <PlaceholderState
            message="Cafe Ice Cream / Soft Drinks / Hot Drinks split"
            hint="Captured in touchoffice_department_sales — surfaced in daily reality email forecast. Per-day slug coming in next iteration." />
        </Section>
      </SandboxWrapper>
    </div>
  );
}
