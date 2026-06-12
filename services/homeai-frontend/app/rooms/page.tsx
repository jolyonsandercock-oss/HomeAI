'use client';

import { FreshnessBadge } from '@/components/ui/FreshnessBadge';
import { useState, useEffect, useMemo } from 'react';
import Link from 'next/link';
import { useRouter, useSearchParams, usePathname } from 'next/navigation';
import { DateRangePicker, DateRange } from '@/components/ui/DateRangePicker';
import { PollClock } from '@/components/ui/PollClock';
import { Section } from '@/components/ui/Section';
import { KPICard } from '@/components/ui/KPICard';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';

interface Room {
  room: string;
  guest_name: string | null;
  departing_today: boolean;
  arriving_today: boolean;
  nights_remaining: number | null;
  gross_amount: string | null;
  payment_status: string | null;
  source: string | null;
  source_ref: string | null;
  guest_phone: string | null;
  guest_email: string | null;
  adults: number | null;
  children: number | null;
}

interface AccomToday { arrivals: number; departures: number; staying: number }
interface WeekEcon { week_start: string; room_nights_sold: string; room_nights_capacity: string; pct_occupied: string | null; avg_stay_nights: string | null; room_nights_unsold: string }
interface RoomRevenue { room_type: string; nights_sold: string; revenue_gbp: string; avg_rate: string }

interface GuestDinner {
  room: string;
  guest_name: string | null;
  guest_email: string | null;
  guest_phone: string | null;
  has_dinner_booking: boolean;
  booking_date: string | null;
  booking_time: string | null;
  party_size: number | null;
  reminder_sent: boolean;
  reminder_replied: boolean;
  booking_id: number;
}

const ROOMS_MASTER = [
  'Room 1 - Double Room', 'Room 2 - Family Room',
  'Room 3 - Double Room', 'Room 4 - Single Room',
  'Room 5 - Double Room', 'Room 6 - Double Room',
  'Room 7 - Twin Room', 'Room 8 - Double Room',
  'Garden Suite', 'The Flat',
];

function canonRoom(r: string | null): string | null {
  if (!r) return null;
  const m = r.match(/Room\s*(\d)/i);
  if (m) return ROOMS_MASTER.find(x => x.startsWith(`Room ${m[1]} `)) ?? null;
  if (/garden/i.test(r)) return 'Garden Suite';
  if (/flat|the f/i.test(r)) return 'The Flat';
  return null;
}

const TABS = ['all', 'pub', 'cafe'] as const;
type Tab = (typeof TABS)[number];

const SOURCE_LABELS: Record<string, string> = {
  booking: 'Booking.com',
  expedia: 'Expedia',
  airbnb: 'Airbnb',
  agoda: 'Agoda',
  ctrip: 'Ctrip',
  direct: 'Direct',
  hotel_email: 'Email',
  caterbook_agoda: 'Agoda',
  caterbook_airbnb: 'Airbnb',
  caterbook_ctrip: 'Ctrip',
  agodaycs: 'Agoda',
};

function sourceLabel(src: string | null): string {
  if (!src) return '—';
  const lower = src.toLowerCase();
  for (const [key, label] of Object.entries(SOURCE_LABELS)) {
    if (lower.includes(key)) return label;
  }
  return src.slice(0, 20);
}

function sourceTier(src: string | null): 'ota' | 'direct' | 'unknown' {
  if (!src) return 'unknown';
  const lower = src.toLowerCase();
  if (lower.includes('booking') || lower.includes('expedia') || lower.includes('airbnb') || lower.includes('agoda') || lower.includes('ctrip')) return 'ota';
  if (lower.includes('direct') || lower.includes('email') || lower.includes('hotel')) return 'direct';
  return 'unknown';
}

export default function RoomsPage() {

  const [range, setRange] = useState<DateRange>({ preset: 'today', start: new Date().toISOString().slice(0, 10), end: new Date().toISOString().slice(0, 10) });

  const dateParam = useMemo(() => {
    if (range.preset === 'today') return { date: new Date().toISOString().slice(0, 10) };
    if (range.preset === 'yesterday') {
      const y = new Date(); y.setDate(y.getDate() - 1);
      return { date: y.toISOString().slice(0, 10) };
    }
    return { date: new Date().toISOString().slice(0, 10) };
  }, [range]);

  // Tomorrow's date for breakfast count
  const tomorrowDate = useMemo(() => {
    const t = new Date(); t.setDate(t.getDate() + 1);
    return t.toISOString().slice(0, 10);
  }, []);

  const rooms = useSlug<Room>('frontend_rooms_today', dateParam, { refetchInterval: 5 * 60_000 });
  const accom = useSlug<AccomToday>('frontend_accommodation_today', dateParam);
  const accomTomorrow = useSlug<AccomToday>('frontend_accommodation_today', { date: tomorrowDate });
  const weekEcon = useSlug<WeekEcon>('rooms_week_economics', {});
  const roomRev = useSlug<RoomRevenue>('revenue_by_room_type_30d', {});
  const dinners = useSlug<GuestDinner>('rooms_guest_dinners', dateParam);
  const [sendingReminder, setSendingReminder] = useState<Record<number, boolean>>({});
  const [reminderSent, setReminderSent] = useState<Record<number, string>>({});
  const [selected, setSelected] = useState<Room | null>(null);
  const router = useRouter();
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

  const occupied = new Map<string, Room>();
  rooms.data?.forEach((r) => {
    const c = canonRoom(r.room);
    if (c) occupied.set(c, r);
  });

  // #34: Room KPI computations
  const roomsToSellToday = ROOMS_MASTER.length - occupied.size;
  const weekData = weekEcon.data?.[0];
  const roomsToSellWeek = weekData?.room_nights_unsold ? parseInt(weekData.room_nights_unsold) : null;
  const avgStayNights = weekData?.avg_stay_nights ? parseFloat(weekData.avg_stay_nights) : null;
  // Average room night value from revenue data
  const totalNights = (roomRev.data ?? []).reduce((a, r) => a + parseInt(r.nights_sold || '0'), 0);
  const totalRevenue = (roomRev.data ?? []).reduce((a, r) => a + parseFloat(r.revenue_gbp || '0'), 0);
  const avgNightValue = totalNights > 0 ? totalRevenue / totalNights : null;

  // #37: Breakfast counts
  const breakfastToday = useMemo(() => {
    // Guests departing today = stayed last night = breakfast today
    let count = 0;
    rooms.data?.forEach(r => {
      if (r.departing_today) {
        count += (r.adults ?? 0) + (r.children ?? 0);
      }
    });
    return count || (rooms.data?.filter(r => r.departing_today).length ?? 0);
  }, [rooms.data]);

  const breakfastTomorrow = useMemo(() => {
    // Tomorrow's departures = guests staying tonight = breakfast tomorrow
    let count = 0;
    const tomorrowRooms = accomTomorrow.data;
    if (tomorrowRooms && tomorrowRooms.length > 0) {
      // Use raw accommodation data to find departures tomorrow
      const tomorrowDateObj = new Date(tomorrowDate);
      tomorrowRooms.forEach((r: any) => {
        const checkout = new Date(r.checkout_date);
        if (checkout.toISOString().slice(0, 10) === tomorrowDate) {
          count += (r.adults ?? 0) + (r.children ?? 0);
        }
      });
    }
    return count || (accomTomorrow.data?.filter((r: any) => {
      const checkout = new Date(r.checkout_date);
      return checkout.toISOString().slice(0, 10) === tomorrowDate;
    }).length ?? 0);
  }, [accomTomorrow.data, tomorrowDate]);

  // #36: Track return guests (guests who have stayed before)
  const allGuestNames = rooms.data?.map(r => r.guest_name).filter(Boolean) ?? [];
  const guestNameCounts = useMemo(() => {
    const counts = new Map<string, number>();
    allGuestNames.forEach(name => {
      if (name) counts.set(name, (counts.get(name) || 0) + 1);
    });
    return counts;
  }, [allGuestNames]);

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

      <SandboxWrapper id="rooms.summary" label="Today summary">
        <Section title="Today" action={<FreshnessBadge source="caterbook" />}>
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
            <KPICard label="Arrivals" value={accom.data?.[0]?.arrivals ?? '—'} />
            <KPICard label="Staying" value={accom.data?.[0]?.staying ?? '—'} />
            <KPICard label="Departures" value={accom.data?.[0]?.departures ?? '—'} />
          </div>
        </Section>
      </SandboxWrapper>

      {/* #37: Breakfast KPIs */}
      <SandboxWrapper id="rooms.breakfast" label="Breakfast forecast">
        <Section title="Breakfast forecast">
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
            <KPICard label="Breakfasts today" value={breakfastToday} loading={rooms.isLoading} />
            <KPICard label="Breakfasts tomorrow" value={breakfastTomorrow} loading={accomTomorrow.isLoading} />
            <KPICard label="Rooms occupied" value={occupied.size} loading={rooms.isLoading} />
            <KPICard label="Meal plans active" value={rooms.data?.filter(r => r.adults != null || r.children != null).length ?? '—'} loading={rooms.isLoading} />
          </div>
          <div className="text-xs text-ink-500 mt-2">
            Today = guests departing today (stayed last night). Tomorrow = guests departing tomorrow (staying tonight). Counts are guest headcount (adults + children).
          </div>
        </Section>
      </SandboxWrapper>

      {/* #40: Dinner booking tracker */}
      <SandboxWrapper id="rooms.dinners" label="Dinner bookings">
        <Section title="Dinner bookings">
          {/* Scoreboard */}
          {dinners.data && (
            <div className="mb-3 flex flex-wrap gap-2 text-xs">
              <span className="px-2 py-1 bg-good/20 text-good rounded font-mono">
                {dinners.data.filter(d => d.has_dinner_booking).length}/{dinners.data.length} booked
              </span>
              <span className="px-2 py-1 bg-amber-500/20 text-amber-400 rounded font-mono">
                {dinners.data.filter(d => d.reminder_sent).length} reminders sent
              </span>
              <span className="px-2 py-1 bg-ink-200 text-ink-600 rounded font-mono">
                {dinners.data.filter(d => d.guest_email).length} with email
              </span>
            </div>
          )}
          <div className="space-y-2">
            {dinners.isLoading && <div className="text-xs text-ink-500">Loading dinner status…</div>}
            {dinners.data?.map((d) => (
              <div key={d.booking_id} className="flex items-center justify-between gap-3 py-2 border-b border-ink-200 last:border-0">
                <div className="flex-1 min-w-0">
                  <div className="text-sm font-mono text-ink-900 truncate" title={d.guest_name ?? ''}>
                    {d.guest_name ?? '—'}
                  </div>
                  <div className="text-xs text-ink-500 truncate">{d.room}</div>
                </div>
                <div className="flex items-center gap-2 flex-shrink-0">
                  {d.has_dinner_booking ? (
                    <span className="text-xs px-2 py-0.5 bg-good/20 text-good rounded font-mono">
                      booked {d.party_size != null ? `(${d.party_size}p)` : ''}
                      {d.booking_date ? ` ${new Date(d.booking_date).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric' })}` : ''}
                      {d.booking_time ? ` ${d.booking_time.toString().slice(0, 5)}` : ''}
                    </span>
                  ) : d.guest_email ? (
                    <button
                      onClick={async () => {
                        const bid = d.booking_id;
                        setSendingReminder(prev => ({ ...prev, [bid]: true }));
                        try {
                          const resp = await fetch('/api/dinner/remind', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ booking_id: bid, guest_email: d.guest_email }),
                          });
                          const data = await resp.json();
                          setReminderSent(prev => ({ ...prev, [bid]: data.message || 'Sent' }));
                        } catch (e) {
                          setReminderSent(prev => ({ ...prev, [bid]: 'Failed' }));
                        } finally {
                          setSendingReminder(prev => ({ ...prev, [bid]: false }));
                          // Refetch after a short delay
                          setTimeout(() => dinners.refetch?.(), 1000);
                        }
                      }}
                      disabled={sendingReminder[d.booking_id] || !!reminderSent[d.booking_id] || d.reminder_sent}
                      className={'text-xs px-2 py-0.5 rounded font-mono transition-colors ' +
                        (d.reminder_sent
                          ? 'bg-amber-500/20 text-amber-400 cursor-default'
                          : reminderSent[d.booking_id]
                            ? 'bg-good/20 text-good cursor-default'
                            : 'bg-amber-500/20 text-amber-400 hover:bg-amber-500/40 cursor-pointer')}
                    >
                      {d.reminder_sent
                        ? d.reminder_replied ? 'replied' : 'reminded'
                        : reminderSent[d.booking_id]
                          ? reminderSent[d.booking_id]
                          : sendingReminder[d.booking_id]
                            ? 'sending…'
                            : 'invite to book'}
                    </button>
                  ) : (
                    <span className="text-xs px-2 py-0.5 bg-ink-200 text-ink-500 rounded font-mono">
                      no email
                    </span>
                  )}
                  {d.reminder_replied && (
                    <span className="text-xs text-good">✓</span>
                  )}
                </div>
              </div>
            ))}
            {dinners.data?.length === 0 && !dinners.isLoading && (
              <div className="text-xs text-ink-500 italic">No in-house guests today.</div>
            )}
          </div>
        </Section>
      </SandboxWrapper>

      {/* #34: Room KPIs */}
      <SandboxWrapper id="rooms.kpis" label="Room KPIs">
        <Section title="Room KPIs">
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
            <KPICard label="Rooms to sell today" value={roomsToSellToday} loading={rooms.isLoading} />
            <KPICard label="Rooms to sell this week" value={roomsToSellWeek ?? '—'} loading={weekEcon.isLoading} />
            <KPICard label="Avg stay (nights)" value={avgStayNights?.toFixed(1) ?? '—'} loading={weekEcon.isLoading} />
            <KPICard label="Avg night value" value={avgNightValue != null ? gbp(avgNightValue) : '—'} loading={roomRev.isLoading} />
          </div>
          <div className="text-xs text-ink-500 mt-2">
            <Link href="/app/invoices" className="text-amber-500 hover:text-amber-400 underline">→ View invoices / COGS</Link>
            <span className="mx-2">|</span>
            Rooms to sell = total rooms ({ROOMS_MASTER.length}) minus occupied. Avg night value from last 30 days of caterbook room nights.
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="rooms.grid" label="Room grid">
        <Section title="Room grid">
          <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-3">
            {ROOMS_MASTER.map((rname) => {
              const r = occupied.get(rname);
              const occupied_state = r && !r.arriving_today ? 'occupied' :
                                    r?.arriving_today      ? 'arriving' :
                                    r?.departing_today     ? 'departing' : 'vacant';
              const srcTier = r ? sourceTier(r.source) : null;
              return (
                <button
                  key={rname}
                  onClick={() => r && setSelected(r)}
                  className={
                    'tile text-left transition-all ' +
                    (occupied_state === 'occupied'  ? 'ring-1 ring-amber-500/60' :
                     occupied_state === 'arriving'  ? 'ring-1 ring-good/60' :
                     occupied_state === 'departing' ? 'ring-1 ring-warn/60 opacity-90' :
                     'opacity-60')
                  }>
                  <div className="text-xs text-ink-500 truncate">{rname}</div>
                  <div className="text-sm font-mono text-ink-900 mt-1 truncate">
                    {r?.guest_name ?? <span className="text-ink-500">vacant</span>}
                  </div>
                  {r && (
                    <div className="mt-1 text-xs text-ink-500 flex gap-1.5 flex-wrap">
                      {r.arriving_today && <span className="text-good">arriving</span>}
                      {r.departing_today && <span className="text-warn">departing</span>}
                      {/* #38 completed 2026-06-12: contact inline on the slab */}
                      {r.guest_phone && <span className="font-mono text-ink-700 basis-full">{r.guest_phone}</span>}
                      {r.guest_email && <span className="font-mono text-ink-700 text-2xs truncate basis-full" title={r.guest_email}>{r.guest_email}</span>}
                      {!r.arriving_today && !r.departing_today && (
                        <span>{r.nights_remaining}n remaining</span>
                      )}
                      {/* #36: Booking source badge */}
                      {r.source && (
                        <span className={'text-2xs px-1 py-0.5 rounded ' + (srcTier === 'ota' ? 'bg-blue-500/20 text-blue-300' : srcTier === 'direct' ? 'bg-green-500/20 text-green-300' : 'bg-ink-300 text-ink-500')}>
                          {sourceLabel(r.source)}
                        </span>
                      )}
                    </div>
                  )}
                </button>
              );
            })}
          </div>
        </Section>
      </SandboxWrapper>

      {selected && (
        <div onClick={() => setSelected(null)}
          className="fixed inset-0 bg-black/60 z-40 flex items-center justify-center p-4">
          <div onClick={(e) => e.stopPropagation()}
            className="bg-ink-50 border border-ink-200 rounded-lg p-5 max-w-md w-full">
            <h3 className="font-mono text-sm text-amber-500">{selected.room}</h3>
            <div className="mt-2 text-lg text-ink-900">{selected.guest_name}</div>
            {/* #36: Booking source + return guest indicator */}
            {selected.source && (
              <div className="mt-1 flex items-center gap-2 flex-wrap">
                <span className={'text-xs px-1.5 py-0.5 rounded ' + (sourceTier(selected.source) === 'ota' ? 'bg-blue-500/20 text-blue-300' : 'bg-green-500/20 text-green-300')}>
                  Booked via {sourceLabel(selected.source)}
                </span>
                {selected.source_ref && (
                  <span className="text-xs text-ink-500">ref: {selected.source_ref.slice(0, 24)}</span>
                )}
              </div>
            )}
            <div className="mt-3 grid grid-cols-2 gap-3 text-xs">
              <div><span className="text-ink-500">Nights remaining</span><br/><span className="font-mono text-ink-700">{selected.nights_remaining}</span></div>
              <div><span className="text-ink-500">Booking value</span><br/><span className="font-mono text-ink-700">{gbp(selected.gross_amount)}</span></div>
              <div><span className="text-ink-500">Payment</span><br/><span className="font-mono text-ink-700">{selected.payment_status ?? '—'}</span></div>
              <div><span className="text-ink-500">State</span><br/><span className="font-mono text-ink-700">
                {selected.arriving_today ? 'arriving today' :
                 selected.departing_today ? 'departing today' : 'in residence'}
              </span></div>
              {/* #38: Phone number and email */}
              <div><span className="text-ink-500">Phone</span><br/><span className="font-mono text-ink-700">{selected.guest_phone ?? '—'}</span></div>
              <div><span className="text-ink-500">Email</span><br/><span className="font-mono text-ink-700 text-2xs truncate" title={selected.guest_email ?? ''}>{selected.guest_email ?? '—'}</span></div>
              {/* Guest count */}
              <div><span className="text-ink-500">Guests</span><br/><span className="font-mono text-ink-700">
                {selected.adults != null || selected.children != null 
                  ? `${selected.adults ?? 0}A + ${selected.children ?? 0}C = ${(selected.adults ?? 0) + (selected.children ?? 0)}` 
                  : '—'}
              </span></div>
              {/* Payment status */}
              <div><span className="text-ink-500">Source ref</span><br/><span className="font-mono text-ink-700 text-2xs truncate" title={selected.source_ref ?? ''}>{selected.source_ref?.slice(0, 20) ?? '—'}</span></div>
            </div>
            <div className="mt-4 flex gap-2">
              <button className="text-xs px-2.5 py-1.5 bg-ink-100 hover:bg-ink-200 text-ink-700 rounded">Add memo</button>
              <button className="text-xs px-2.5 py-1.5 bg-ink-100 hover:bg-ink-200 text-ink-700 rounded">Add task</button>
              <button onClick={() => setSelected(null)} className="text-xs px-2.5 py-1.5 bg-amber-500 text-ink-0 rounded ml-auto">Close</button>
            </div>
            <p className="mt-2 text-xs text-ink-500">
              Memo + task actions land in action_queue in next sprint.
            </p>
          </div>
        </div>
      )}
    </div>
  );
}
