'use client';

import { useState, useEffect, useMemo } from 'react';
import { useRouter, useSearchParams, usePathname } from 'next/navigation';
import { DateRangePicker, DateRange } from '@/components/ui/DateRangePicker';
import { PollClock } from '@/components/ui/PollClock';
import { Section } from '@/components/ui/Section';
import { KPICard } from '@/components/ui/KPICard';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';

interface Reservation {
  id: number;
  reservation_at: string;
  guest_name: string | null;
  party_size: number | null;
  booking_type: string | null;
  source_ref: string | null;
}

interface RotaRow {
  user_external_id: number;
  full_name: string;
  team: string;
  start_time: string;
  end_time: string;
  hours_worked: string;
  shift_cost: string;
}

interface MenuRow {
  site: string;
  course: 'main' | 'starter' | 'dessert' | 'side' | 'drink' | 'other';
  plu_number: string;
  descriptor: string;
  qty: string;
  gross_gbp: string;
  avg_price: string | null;
  rank_in_course: number;
}

const COURSE_ORDER: MenuRow['course'][] = ['starter', 'main', 'dessert', 'side', 'drink', 'other'];
const COURSE_LABEL: Record<MenuRow['course'], string> = {
  starter: 'Starters', main: 'Mains', dessert: 'Desserts',
  side: 'Sides', drink: 'Drinks', other: 'Other',
};

const TABS = ['all', 'pub', 'cafe'] as const;
type Tab = (typeof TABS)[number];

export default function RestaurantPage() {

  const [range, setRange] = useState<DateRange>({ preset: 'today', start: new Date().toISOString().slice(0, 10), end: new Date().toISOString().slice(0, 10) });

  const dateParam = useMemo(() => {

    if (range.preset === 'today') return { date: new Date().toISOString().slice(0, 10) };

    if (range.preset === 'yesterday') {

      const y = new Date(); y.setDate(y.getDate() - 1);

      return { date: y.toISOString().slice(0, 10) };

    }

    return { date: new Date().toISOString().slice(0, 10) };

  }, [range]);
  const list = useSlug<Reservation>('frontend_restaurant_today', dateParam, { refetchInterval: 60_000 });
  const rota = useSlug<RotaRow>('staff_on_rota_today', dateParam, { refetchInterval: 5 * 60_000 });
  const menu = useSlug<MenuRow>('menu_performance_by_course_7d', {}, { refetchInterval: 30 * 60_000 });  const router = useRouter();
  const sp = useSearchParams();
  const pathname = usePathname();
  const initialTab = (TABS.find(t => t === sp.get('tab')) as Tab | undefined) ?? 'all';
  const [tab, setTabState] = useState<Tab>(initialTab);
  const setTab = (t: Tab) => {
    setTabState(t);
    const params = new URLSearchParams(sp.toString());
    if (t === 'all') params.delete('tab'); else params.set('tab', t);
    const q = params.toString();
    router.replace(q ? `${pathname}?${q}` : pathname, { scroll: false });
  };
  useEffect(() => {
    const urlTab = sp.get('tab');
    if (urlTab && TABS.includes(urlTab as Tab) && urlTab !== tab) {
      setTabState(urlTab as Tab);
    }
  }, [sp]);
  const poller = useSlug<{ source: string; last_poll: string }>('sales_last_poll_per_source', {}, { refetchInterval: 60_000 });
  const pollFor = (source: string) => (poller.data ?? []).find((p: any) => p.source === source)?.last_poll ?? null;
  const total = list.data?.length ?? 0;
  const pax   = list.data?.reduce((s, r) => s + (r.party_size ?? 0), 0) ?? 0;

  const kitchen = (rota.data ?? []).filter(r => r.team === 'kitchen');
  const kitchenHours = kitchen.reduce((s, r) => s + parseFloat(String(r.hours_worked)), 0);
  const kitchenCost  = kitchen.reduce((s, r) => s + parseFloat(String(r.shift_cost)), 0);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between flex-wrap gap-3">
        <DateRangePicker value={range} onChange={setRange} />
        <div className="flex items-center gap-2">
          <div className="flex bg-ink-100 border border-ink-200 rounded-md overflow-hidden text-xs">
            {TABS.map((t) => (
              <button key={t} onClick={() => setTab(t)}
                className={'px-3 py-1.5 capitalize ' + (tab === t ? 'bg-amber-500 text-ink-0' : 'text-ink-600 hover:text-ink-800')}>{t}</button>
            ))}
          </div>
          <div className="flex items-center gap-1 text-xs text-ink-500">
            <span>polls:</span>
            <PollClock lastPoll={pollFor('touchoffice_malthouse')} label="touchoffice pub" />
            <PollClock lastPoll={pollFor('touchoffice_sandwich')} label="touchoffice cafe" />
          </div>
        </div>
      </div>

      <SandboxWrapper id="restaurant.kpi" label="Restaurant KPIs">
        <Section title="Tonight on the book">
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
            <KPICard label="Bookings" value={total} loading={list.isLoading} />
            <KPICard label="Pax total" value={pax} loading={list.isLoading} />
            <KPICard label="Avg party" value={total ? (pax / total).toFixed(1) : '—'} loading={list.isLoading} />
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="restaurant.runsheet" label="Run sheet">
        <Section title="Run sheet">
          {list.isLoading ? (
            <PlaceholderState message="Loading reservations…" />
          ) : list.data && list.data.length > 0 ? (
            <div className="tile max-h-[420px] overflow-y-auto">
              <table className="w-full text-sm">
                <thead className="text-xs text-ink-500 uppercase tracking-wider sticky top-0 bg-ink-0 z-10">
                  <tr>
                    <th className="text-left py-2 font-medium">Time</th>
                    <th className="text-left font-medium">Guest</th>
                    <th className="text-left font-medium">Pax</th>
                    <th className="text-left font-medium">Type</th>
                  </tr>
                </thead>
                <tbody>
                  {list.data.map((r) => (
                    <tr key={r.id} className="border-t border-ink-200">
                      <td className="py-2 font-mono text-ink-700">
                        {new Date(r.reservation_at).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}
                      </td>
                      <td className="font-medium text-ink-900">{r.guest_name ?? '—'}</td>
                      <td className="font-mono text-ink-700">{r.party_size ?? '?'}</td>
                      <td className="text-xs text-ink-500">{r.booking_type ?? r.source_ref}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <PlaceholderState message="No reservations on the book for today." />
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="restaurant.kitchen-rota" label="Kitchen on today">
        <Section title={`Kitchen team on today (${kitchen.length})`}>
          {rota.isLoading ? <PlaceholderState message="Loading rota…" /> :
           kitchen.length > 0 ? (
            <div className="tile max-h-[420px] overflow-y-auto">
              <div className="flex items-center justify-between mb-2 text-xs">
                <div className="text-ink-500 uppercase tracking-wider">{kitchenHours.toFixed(1)} hours · {gbp(kitchenCost)}</div>
              </div>
              <table className="w-full text-sm">
                <thead className="text-xs text-ink-500 uppercase tracking-wider">
                  <tr>
                    <th className="text-left py-1.5 font-medium">Chef</th>
                    <th className="text-left font-medium">Start</th>
                    <th className="text-left font-medium">End</th>
                    <th className="text-right font-medium">Hours</th>
                    <th className="text-right font-medium">Cost</th>
                  </tr>
                </thead>
                <tbody>
                  {kitchen.map(s => (
                    <tr key={s.user_external_id + s.start_time} className="border-t border-ink-200">
                      <td className="py-1.5 font-medium text-ink-900">{s.full_name}</td>
                      <td className="font-mono text-ink-700">{new Date(s.start_time).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}</td>
                      <td className="font-mono text-ink-700">{new Date(s.end_time).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}</td>
                      <td className="text-right font-mono text-ink-700">{parseFloat(String(s.hours_worked)).toFixed(1)}</td>
                      <td className="text-right font-mono text-ink-700">{gbp(parseFloat(String(s.shift_cost)))}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : <PlaceholderState message="No kitchen shifts on rota today." />}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="restaurant.menu-perf" label="Menu performance">
        <Section title="Menu performance — pub, last 7 days">
          {menu.isLoading ? <PlaceholderState message="Loading menu…" /> :
           menu.data && menu.data.length > 0 ? (
            <>
              <div className="text-xs text-ink-500 mb-2">
                Lunch/dinner split pending: TouchOffice scrape is daily-only with no transaction time.
              </div>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                {COURSE_ORDER.map(course => {
                  const items = (menu.data ?? []).filter(r => r.site === 'malthouse' && r.course === course).slice(0, 10);
                  if (items.length === 0) return null;
                  return (
                    <div key={course} className="tile">
                      <div className="label mb-2">{COURSE_LABEL[course]} <span className="text-ink-500">· {items.length}</span></div>
                      <table className="w-full text-xs">
                        <thead className="text-xs text-ink-500 uppercase tracking-wider">
                          <tr>
                            <th className="text-left font-medium pb-1">#</th>
                            <th className="text-left font-medium">Item</th>
                            <th className="text-right font-medium">Qty</th>
                            <th className="text-right font-medium">Gross</th>
                          </tr>
                        </thead>
                        <tbody>
                          {items.map(r => (
                            <tr key={r.plu_number} className="border-t border-ink-200">
                              <td className="py-1 font-mono text-ink-500">{r.rank_in_course}</td>
                              <td className="text-ink-900">{r.descriptor}</td>
                              <td className="text-right font-mono text-ink-700">{parseFloat(r.qty).toFixed(0)}</td>
                              <td className="text-right font-mono text-ink-700">{gbp(parseFloat(r.gross_gbp))}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  );
                })}
              </div>
            </>
          ) : <PlaceholderState message="No PLU sales recorded in the last 7 days." />}
        </Section>
      </SandboxWrapper>
    </div>
  );
}
