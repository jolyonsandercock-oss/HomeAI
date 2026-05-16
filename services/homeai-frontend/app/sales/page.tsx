'use client';

import { useState } from 'react';
import { DateRangePicker, DateRange } from '@/components/ui/DateRangePicker';
import { KPICard } from '@/components/ui/KPICard';
import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';
import { BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid } from 'recharts';

interface TodayGross { site: string; gross: string }

const TABS = ['all', 'pub', 'cafe'] as const;
type Tab = (typeof TABS)[number];

export default function SalesPage() {
  const [range, setRange] = useState<DateRange>({ preset: 'today', start: new Date().toISOString().slice(0, 10), end: new Date().toISOString().slice(0, 10) });
  const [tab, setTab] = useState<Tab>('all');

  // For today we have a slug; multi-day range will use the same slug iterated client-side
  // (full multi-day query slug is a follow-up — for now render the today single-day view)
  const today = useSlug<TodayGross>('frontend_today_gross');
  const pub  = today.data?.find(r => r.site === 'malthouse');
  const cafe = today.data?.find(r => r.site === 'sandwich');
  const total = (parseFloat(pub?.gross ?? '0') + parseFloat(cafe?.gross ?? '0')) || 0;

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between flex-wrap gap-3">
        <DateRangePicker value={range} onChange={setRange} />
        <div className="flex bg-ink-100 border border-ink-200 rounded-md overflow-hidden text-xs">
          {TABS.map((t) => (
            <button key={t} onClick={() => setTab(t)}
              className={'px-3 py-1.5 capitalize ' + (tab === t ? 'bg-amber-500 text-ink-0' : 'text-ink-600 hover:text-ink-800')}>{t}</button>
          ))}
        </div>
      </div>

      <SandboxWrapper id="sales.kpi" label="Sales KPI row">
        <Section title="KPIs">
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <KPICard label="Gross today" size="xl"
              value={today.isLoading ? null : gbp(tab === 'all' ? total : (tab === 'pub' ? pub?.gross ?? 0 : cafe?.gross ?? 0))} />
            <KPICard label="Pub" value={gbp(pub?.gross ?? 0)} />
            <KPICard label="Café" value={gbp(cafe?.gross ?? 0)} />
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="sales.chart" label="Sales chart">
        <Section title="Hourly breakdown today">
          {today.isLoading ? (
            <PlaceholderState message="Loading hourly data…" />
          ) : (
            <div className="tile h-64">
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={today.data ?? []}>
                  <CartesianGrid stroke="#2a2a2a" vertical={false} />
                  <XAxis dataKey="site" stroke="#737373" fontSize={11} />
                  <YAxis stroke="#737373" fontSize={11} tickFormatter={(v) => `£${v}`} />
                  <Tooltip contentStyle={{ background: '#171717', border: '1px solid #2a2a2a' }} />
                  <Bar dataKey="gross" fill="#f59e0b" />
                </BarChart>
              </ResponsiveContainer>
              <p className="mt-2 text-xs text-ink-500">
                Hour-by-hour split: pending touchoffice_hourly_sales view. Currently shown: site totals.
              </p>
            </div>
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="sales.dept-split" label="Department split">
        <Section title="Department split (ICRTouch)">
          <PlaceholderState
            message="Department split not yet wired"
            hint="touchoffice_department_sales is captured but the per-department slug for arbitrary date ranges is in the next sprint. The values are already used in /sales > pub/cafe totals and in the daily reality email."
          />
        </Section>
      </SandboxWrapper>
    </div>
  );
}
