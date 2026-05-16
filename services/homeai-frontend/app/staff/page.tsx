'use client';

import { Section } from '@/components/ui/Section';
import { KPICard } from '@/components/ui/KPICard';
import { WagePctBadge } from '@/components/ui/WagePctBadge';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';

interface WagePct { days: number; labour: string | null; sales: string | null; pct: string | null }

export default function StaffPage() {
  const wage = useSlug<WagePct>('frontend_wage_pct_summary');

  return (
    <div className="space-y-6">
      <SandboxWrapper id="staff.on-shift">
        <Section title="Currently on shift">
          <PlaceholderState
            message="Live Tanda roster integration"
            hint="Tanda syncs at 02:15 + midday catch-up (u29-workforce-sync). Today's roster appears here once Tanda publishes — same data feeds the daily reality email." />
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="staff.wage-tracker">
        <Section title="Wage % tracker">
          <div className="grid grid-cols-3 gap-3">
            {[1, 7, 30].map((d) => {
              const r = wage.data?.find(x => Number(x.days) === d);
              const pct = r?.pct ? parseFloat(r.pct) : null;
              return (
                <div key={d} className="tile">
                  <div className="label">{d === 1 ? 'Yesterday' : `${d} day rolling`}</div>
                  <div className="mt-2"><WagePctBadge pct={pct} /></div>
                  <div className="mt-2 text-xs text-ink-500 font-mono">
                    {gbp(r?.labour ?? 0)} / {gbp(r?.sales ?? 0)}
                  </div>
                </div>
              );
            })}
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="staff.top-by-sales">
        <Section title="Top staff by sales">
          <PlaceholderState
            message="Per-staff sales attribution"
            hint="ICRTouch doesn't currently push staff IDs on transactions — would need staff-clock-in vs sales-window join. Captured in roadmap as U+, low priority." />
        </Section>
      </SandboxWrapper>
    </div>
  );
}
