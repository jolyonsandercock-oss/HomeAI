'use client';

import { KPICard } from '@/components/ui/KPICard';
import { WagePctBadge } from '@/components/ui/WagePctBadge';
import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import { gbp, fmtDay } from '@/lib/format';
import Link from 'next/link';

interface TodayGross { site: string; gross: string }
interface WagePct { days: number; labour: string | null; sales: string | null; pct: string | null }
interface SevenDayRow { day: string; gross: string; rooms: number; covers: number }
interface AccomToday { arrivals: number; departures: number; staying: number }

export default function DashboardPage() {
  const today = useSlug<TodayGross>('frontend_today_gross', {}, { refetchInterval: 60_000 });
  const wage  = useSlug<WagePct>('frontend_wage_pct_summary');
  const week  = useSlug<SevenDayRow>('frontend_seven_day_strip', {}, { refetchInterval: 5 * 60_000 });
  const accom = useSlug<AccomToday>('frontend_accommodation_today', {}, { refetchInterval: 60_000 });

  const pub  = today.data?.find(r => r.site === 'malthouse');
  const cafe = today.data?.find(r => r.site === 'sandwich');
  const total = (parseFloat(pub?.gross ?? '0') + parseFloat(cafe?.gross ?? '0')) || 0;

  return (
    <div className="space-y-6">
      <SandboxWrapper id="dashboard.row1.revenue" label="Revenue KPIs">
        <Section title="Revenue today">
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <KPICard label="Gross today" size="xl"
              value={today.isLoading ? null : gbp(total)} loading={today.isLoading} />
            <KPICard label="Pub" value={gbp(pub?.gross ?? 0)} loading={today.isLoading} />
            <KPICard label="Café" value={gbp(cafe?.gross ?? 0)} loading={today.isLoading} />
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="dashboard.row2.labour" label="Labour">
        <Section title="Labour">
          <div className="tile">
            <div className="flex items-center flex-wrap gap-4">
              <span className="label">Wage %</span>
              {[1, 7, 30].map((d) => {
                const r = wage.data?.find(x => Number(x.days) === d);
                const pct = r?.pct ? parseFloat(r.pct) : null;
                return <WagePctBadge key={d} pct={pct} label={d === 1 ? 'yest' : `${d}d`} />;
              })}
              <span className="text-xs text-ink-500 ml-auto">target &lt; 30%</span>
            </div>
            <div className="mt-3 text-xs text-ink-500">
              Currently on shift: <span className="text-ink-700">data via Tanda sync — live in next iteration</span>
            </div>
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="dashboard.row3.week" label="7-day strip">
        <Section title="Week strip">
          {week.data && week.data.length > 0 ? (
            <div className="grid grid-cols-7 gap-2 overflow-x-auto">
              {week.data.map((row) => {
                const dt = new Date(row.day);
                const isToday = dt.toDateString() === new Date().toDateString();
                return (
                  <div key={row.day} className={
                    'tile flex flex-col gap-0.5 ' + (isToday ? 'ring-1 ring-amber-500' : '')
                  }>
                    <div className="label">{fmtDay(row.day)}</div>
                    <div className="font-mono text-sm text-ink-900">{gbp(row.gross)}</div>
                    <div className="text-[10px] text-ink-500">
                      🛏 {row.rooms} · 🍽 {row.covers}
                    </div>
                  </div>
                );
              })}
            </div>
          ) : <PlaceholderState message="Week strip loading…" />}
          <p className="mt-2 text-xs text-ink-500">
            Weather, tides, sunset times: scheduled — wired via weather_forecast cache (Phase 2).
          </p>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="dashboard.row4.accom" label="Accommodation today">
        <Section title="Accommodation today" action={<Link className="text-xs text-amber-500 hover:text-amber-400" href="/rooms">View Rooms →</Link>}>
          <div className="grid grid-cols-3 gap-3">
            <KPICard label="Arrivals"  value={accom.data?.[0]?.arrivals  ?? '—'} loading={accom.isLoading} />
            <KPICard label="Staying"   value={accom.data?.[0]?.staying   ?? '—'} loading={accom.isLoading} />
            <KPICard label="Departures" value={accom.data?.[0]?.departures ?? '—'} loading={accom.isLoading} />
          </div>
        </Section>
      </SandboxWrapper>
    </div>
  );
}
