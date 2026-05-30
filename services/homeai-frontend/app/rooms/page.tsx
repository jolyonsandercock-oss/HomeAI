'use client';

import { useState, useEffect } from 'react';
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
}

interface AccomToday { arrivals: number; departures: number; staying: number }

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

export default function RoomsPage() {
  const rooms = useSlug<Room>('frontend_rooms_today', {}, { refetchInterval: 5 * 60_000 });
  const accom = useSlug<AccomToday>('frontend_accommodation_today');
  const [selected, setSelected] = useState<Room | null>(null);
  const [range, setRange] = useState<DateRange>({ preset: 'today', start: new Date().toISOString().slice(0, 10), end: new Date().toISOString().slice(0, 10) });
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
        <Section title="Today">
          <div className="grid grid-cols-3 gap-3">
            <KPICard label="Arrivals" value={accom.data?.[0]?.arrivals ?? '—'} />
            <KPICard label="Staying" value={accom.data?.[0]?.staying ?? '—'} />
            <KPICard label="Departures" value={accom.data?.[0]?.departures ?? '—'} />
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
                    <div className="mt-1 text-xs text-ink-500 flex gap-1.5">
                      {r.arriving_today && <span className="text-good">arriving</span>}
                      {r.departing_today && <span className="text-warn">departing</span>}
                      {!r.arriving_today && !r.departing_today && (
                        <span>{r.nights_remaining}n remaining</span>
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
            <div className="mt-3 grid grid-cols-2 gap-3 text-xs">
              <div><span className="text-ink-500">Nights remaining</span><br/><span className="font-mono text-ink-700">{selected.nights_remaining}</span></div>
              <div><span className="text-ink-500">Booking value</span><br/><span className="font-mono text-ink-700">{gbp(selected.gross_amount)}</span></div>
              <div><span className="text-ink-500">Payment</span><br/><span className="font-mono text-ink-700">{selected.payment_status ?? '—'}</span></div>
              <div><span className="text-ink-500">State</span><br/><span className="font-mono text-ink-700">
                {selected.arriving_today ? 'arriving today' :
                 selected.departing_today ? 'departing today' : 'in residence'}
              </span></div>
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
