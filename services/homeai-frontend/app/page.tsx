'use client';

import Link from 'next/link';
import { KPICard } from '@/components/ui/KPICard';
import { WagePctBadge } from '@/components/ui/WagePctBadge';
import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import { gbp, fmtDay } from '@/lib/format';
import {
  Sunset, CloudRain, Cloud, Sun, CloudSnow,
  Bed, UtensilsCrossed, Wine, Waves,
} from 'lucide-react';

interface TodayGross { site: string; gross: string; as_of?: string }
interface LabourRow {
  window_days: number;
  pub_labour_avg: string | null;  pub_sales_avg: string | null;
  cafe_labour_avg: string | null; cafe_sales_avg: string | null;
}
interface WeekDay {
  day: string;
  max_temp: string | null;
  rain_mm: string | null;
  precipitation_probability: number | null;
  weather_code: number | null;
  sunrise: string | null;
  sunset: string | null;
  rooms_booked: number;
  lunch_count: number;
  dinner_count: number;
  sunday_count: number;
}
interface AccomToday { arrivals: number; departures: number; staying: number }
interface CoversToday {
  lunch_count: number; dinner_count: number; sunday_count: number;
  lunch_pax: number | null; dinner_pax: number | null; group_count: number;
}
interface Special { kind: string; label: string; detail: number; notes: string }
interface SpecialWeek {
  day: string; kind: string; label: string;
  party_size: number; payment_status: string | null;
}
interface GuestRow {
  guest_name: string; room: string; amount: string | number; payment_status: string | null;
  party_size?: number | null;
}
interface TideRow {
  day: string; high_low: 'high' | 'low';
  tide_time: string; height_m: string | number;
}

// WMO code → short label + lucide icon
function weatherIcon(code: number | null) {
  if (code === null) return Cloud;
  if (code === 0 || code === 1) return Sun;
  if (code >= 71 && code <= 86) return CloudSnow;
  if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) return CloudRain;
  return Cloud;
}
function weatherLabel(code: number | null) {
  if (code === null) return '—';
  if (code === 0) return 'clear';
  if (code === 1 || code === 2) return 'partly cloudy';
  if (code === 3) return 'overcast';
  if (code >= 45 && code <= 48) return 'fog';
  if (code >= 51 && code <= 57) return 'drizzle';
  if (code >= 61 && code <= 65) return 'rain';
  if (code >= 71 && code <= 75) return 'snow';
  if (code >= 80 && code <= 82) return 'showers';
  if (code >= 95) return 'storm';
  return '—';
}
function weatherClass(code: number | null, rain: number | null, temp: number | null) {
  if (temp != null && temp >= 18 && (rain == null || parseFloat(String(rain)) < 1)) return 'good';
  if (rain != null && parseFloat(String(rain)) > 5) return 'bad';
  if (temp != null && temp < 8) return 'bad';
  return 'mid';
}
function timeOnly(iso: string | null): string {
  if (!iso) return '—';
  const d = new Date(iso);
  return d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
}
function timeShort(t: string | null): string {
  if (!t) return '—';
  return t.length >= 5 ? t.substring(0, 5) : t;
}

// Traffic-light thresholds. Tuned to Olde Malthouse run-rate; tweak in static_context
// later if Jo wants them server-driven.
function grossClass(total: number): string {
  if (total >= 2000) return 'text-good';
  if (total >= 1500) return 'text-amber-500';
  return 'text-warn';
}
function labourClass(pct: number | null): string {
  if (pct == null) return 'text-ink-500';
  if (pct < 30) return 'text-good';
  if (pct <= 35) return 'text-amber-500';
  return 'text-warn';
}

export default function DashboardPage() {
  const today    = useSlug<TodayGross>('frontend_today_gross', {}, { refetchInterval: 60_000 });
  const labour   = useSlug<LabourRow>('dashboard_labour_yesterday');
  const week     = useSlug<WeekDay>('dashboard_week_strip', {}, { refetchInterval: 5 * 60_000 });
  const tides    = useSlug<TideRow>('dashboard_tides_next_7d', {}, { refetchInterval: 60 * 60_000 });
  const specials = useSlug<SpecialWeek>('dashboard_specials_next_7d', {}, { refetchInterval: 5 * 60_000 });
  const accom    = useSlug<AccomToday>('frontend_accommodation_today', {}, { refetchInterval: 60_000 });
  const covers   = useSlug<CoversToday>('dashboard_covers_today', {}, { refetchInterval: 60_000 });
  const special  = useSlug<Special>('dashboard_special_today');
  const checkins  = useSlug<GuestRow>('dashboard_checkins_today');
  const stayovers = useSlug<GuestRow>('dashboard_stayovers_today');
  const checkouts = useSlug<GuestRow>('dashboard_checkouts_today');

  const pub  = today.data?.find(r => r.site === 'malthouse');
  const cafe = today.data?.find(r => r.site === 'sandwich');
  const total = (parseFloat(pub?.gross ?? '0') + parseFloat(cafe?.gross ?? '0')) || 0;

  // Labour rows are keyed by window_days = 1 (yesterday), 7, 30
  const lab = (w: number) => labour.data?.find(r => Number(r.window_days) === w);

  function ratio(c: string | null | undefined, s: string | null | undefined): number | null {
    const cn = parseFloat(c ?? ''); const sn = parseFloat(s ?? '');
    if (!Number.isFinite(cn) || !Number.isFinite(sn) || sn === 0) return null;
    return (cn / sn) * 100;
  }

  // Group week-strip context by day for tide + specials lookup
  const tidesByDay: Record<string, TideRow[]> = {};
  (tides.data ?? []).forEach(t => {
    (tidesByDay[t.day] ||= []).push(t);
  });
  const specialsByDay: Record<string, SpecialWeek[]> = {};
  (specials.data ?? []).forEach(s => {
    (specialsByDay[s.day] ||= []).push(s);
  });

  return (
    <div className="space-y-5">
      {/* ROW 1: Revenue tile + Labour tile */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-3">
        <SandboxWrapper id="dashboard.revenue" label="Revenue today">
          <Link href="/sales" className="block">
            <div className="tile group">
              <div className="label">Gross today</div>
              <div className={'kpi-xl mt-1 ' + (today.isLoading ? '' : grossClass(total))}>
                {today.isLoading ? <span className="inline-block w-32 h-10 bg-ink-200 rounded animate-pulse" /> : gbp(total)}
              </div>
              <div className="mt-2 flex gap-5 text-sm font-mono">
                <span><span className="text-ink-500">Pub</span> <strong className="text-ink-900">{gbp(pub?.gross ?? 0)}</strong></span>
                <span><span className="text-ink-500">Café</span> <strong className="text-ink-900">{gbp(cafe?.gross ?? 0)}</strong></span>
              </div>
              <div className="mt-2 text-[11px] text-amber-500 group-hover:text-amber-400">→ Click for Sales detail</div>
            </div>
          </Link>
        </SandboxWrapper>

        <SandboxWrapper id="dashboard.labour" label="Labour vs sales">
          <Link href="/staff" className="block">
            <div className="tile group">
              <div className="label flex items-center gap-2">Labour vs sales <span className="text-ink-600 text-[10px] normal-case tracking-normal">yesterday + rolling avg</span></div>
              <div className="mt-2 grid grid-cols-3 gap-2 text-xs">
                {[{w: 1, name: 'Yesterday'}, {w: 7, name: '7 day avg'}, {w: 30, name: '30 day avg'}].map(({w, name}) => {
                  const r = lab(w);
                  const pubR = ratio(r?.pub_labour_avg, r?.pub_sales_avg);
                  const cafR = ratio(r?.cafe_labour_avg, r?.cafe_sales_avg);
                  const combL = (parseFloat(r?.pub_labour_avg ?? '0') + parseFloat(r?.cafe_labour_avg ?? '0'));
                  const combS = (parseFloat(r?.pub_sales_avg ?? '0') + parseFloat(r?.cafe_sales_avg ?? '0'));
                  const combR = combS > 0 ? (combL / combS) * 100 : null;
                  return (
                    <div key={w} className="bg-ink-100 rounded p-2">
                      <div className="text-[10px] text-ink-500 uppercase tracking-wider">{name}</div>
                      <div className={'mt-1 text-base font-mono font-semibold ' + labourClass(combR)}>
                        {combR === null ? '—' : `${combR.toFixed(1)}%`}
                      </div>
                      <div className="mt-1 grid grid-cols-2 gap-1 text-[10px] leading-tight">
                        <div>
                          <div className="text-ink-500 uppercase tracking-wider">Labour</div>
                          <div className="font-mono text-ink-900">{combS > 0 ? gbp(combL, 0) : '—'}</div>
                        </div>
                        <div>
                          <div className="text-ink-500 uppercase tracking-wider">Sales</div>
                          <div className="font-mono text-ink-900">{combS > 0 ? gbp(combS, 0) : '—'}</div>
                        </div>
                      </div>
                      <div className="mt-1 flex gap-2 text-[10px]">
                        <WagePctBadge pct={pubR} label="pub" />
                        <WagePctBadge pct={cafR} label="cafe" />
                      </div>
                    </div>
                  );
                })}
              </div>
              <div className="mt-2 text-[11px] text-amber-500 group-hover:text-amber-400">→ Click for Staff detail</div>
            </div>
          </Link>
        </SandboxWrapper>
      </div>

      {/* ROW 2: 7-day week strip (today + 6 forward) */}
      <SandboxWrapper id="dashboard.week" label="Week strip">
        <Section title="Week ahead — weather · tides · bookings">
          {week.isLoading ? <PlaceholderState message="Loading week strip…" /> :
           week.data && week.data.length > 0 ? (
            <div className="grid grid-cols-7 gap-2">
              {week.data.map((d) => {
                const isToday = new Date(d.day).toDateString() === new Date().toDateString();
                const cls = weatherClass(d.weather_code, d.rain_mm ? parseFloat(d.rain_mm) : null, d.max_temp ? parseFloat(d.max_temp) : null);
                const Icon = weatherIcon(d.weather_code);
                const ring = cls === 'good' ? 'ring-1 ring-good/70' :
                             cls === 'bad'  ? 'ring-1 ring-warn/70' :
                             isToday ? 'ring-2 ring-amber-500' : '';
                const dayTides    = tidesByDay[d.day] ?? [];
                const daySpecials = specialsByDay[d.day] ?? [];
                return (
                  <div key={d.day} className={`tile flex flex-col text-[11px] gap-1 ${ring}`}>
                    {/* Day header + weather icon */}
                    <div className="flex items-center justify-between">
                      <span className={'label ' + (isToday ? 'text-amber-500' : '')}>{fmtDay(d.day)}</span>
                      <Icon size={14} className={cls === 'good' ? 'text-amber-500' : cls === 'bad' ? 'text-warn' : 'text-ink-500'} />
                    </div>
                    {/* Temp + rain */}
                    <div className="font-mono text-ink-900">
                      {d.max_temp ? `${parseFloat(d.max_temp).toFixed(0)}°` : '—'}{' '}
                      <span className="text-ink-500 text-[10px]">
                        {d.precipitation_probability != null ? `${d.precipitation_probability}%🌧` :
                         d.rain_mm ? `${parseFloat(d.rain_mm).toFixed(1)}mm` : ''}
                      </span>
                    </div>
                    <div className="text-[10px] text-ink-500">{weatherLabel(d.weather_code)}</div>
                    {/* Sunset (prominent, sunrise dropped) */}
                    <div className="flex items-center gap-1 text-[10px] text-ink-700">
                      <Sunset size={11} className="text-amber-500" />
                      <span className="font-mono">{timeOnly(d.sunset)}</span>
                    </div>
                    {/* Tides */}
                    {dayTides.length > 0 && (
                      <div className="text-[10px] text-ink-600 leading-tight flex items-start gap-1">
                        <Waves size={11} className="text-info mt-0.5 shrink-0" />
                        <div className="font-mono">
                          {dayTides.map((t, i) => (
                            <span key={i} className="block">
                              {t.high_low === 'high' ? 'H' : 'L'} {timeShort(t.tide_time)}
                            </span>
                          ))}
                        </div>
                      </div>
                    )}
                    {/* Labelled occupancy / covers */}
                    {d.rooms_booked > 0 && (
                      <div className="flex items-center gap-1 text-[10px] text-ink-700">
                        <Bed size={11} className="text-ink-500" />
                        <span>{d.rooms_booked} {d.rooms_booked === 1 ? 'room' : 'rooms'}</span>
                      </div>
                    )}
                    {(d.lunch_count > 0 || d.dinner_count > 0) && (
                      <div className="flex items-center gap-1 text-[10px] text-ink-700">
                        <UtensilsCrossed size={11} className="text-ink-500" />
                        <span>
                          {d.lunch_count > 0 && `${d.lunch_count} lunch`}
                          {d.lunch_count > 0 && d.dinner_count > 0 && ' · '}
                          {d.dinner_count > 0 && `${d.dinner_count} dinner`}
                        </span>
                      </div>
                    )}
                    {/* Specials inline */}
                    {daySpecials.length > 0 && (
                      <div className="mt-1 pt-1 border-t border-ink-200 text-[10px] text-ink-700">
                        <div className="flex items-center gap-1 text-amber-500 uppercase tracking-wider text-[9px] mb-0.5">
                          <Wine size={10} />Groups
                        </div>
                        {daySpecials.slice(0, 3).map((s, i) => (
                          <div key={i} className="leading-tight truncate">
                            {s.label} · {s.party_size}
                          </div>
                        ))}
                        {daySpecials.length > 3 && (
                          <div className="text-[10px] text-ink-500">+{daySpecials.length - 3} more</div>
                        )}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          ) : <PlaceholderState message="No week data — weather forecast cache may need refresh." />}
        </Section>
      </SandboxWrapper>

      {/* ROW 3: Quick counts */}
      <SandboxWrapper id="dashboard.counts" label="Today counts">
        <Section title="Today at a glance">
          <div className="grid grid-cols-2 sm:grid-cols-5 gap-3">
            <KPICard label="Rooms booked" value={accom.data?.[0]?.staying ?? '—'} loading={accom.isLoading} />
            <KPICard label="Arrivals"    value={accom.data?.[0]?.arrivals ?? '—'} loading={accom.isLoading} />
            <KPICard label="Departures"  value={accom.data?.[0]?.departures ?? '—'} loading={accom.isLoading} />
            <KPICard label="Lunches"
              value={covers.data?.[0]?.lunch_count ?? 0}
              loading={covers.isLoading}
              rollingAvg={covers.data?.[0]?.lunch_pax ? [{label: 'pax', value: covers.data[0].lunch_pax}] : undefined} />
            <KPICard label="Dinners"
              value={covers.data?.[0]?.dinner_count ?? 0}
              loading={covers.isLoading}
              rollingAvg={covers.data?.[0]?.dinner_pax ? [{label: 'pax', value: covers.data[0].dinner_pax}] : undefined} />
          </div>
        </Section>
      </SandboxWrapper>

      {/* ROW 4: Special occasions */}
      <SandboxWrapper id="dashboard.special" label="Special occasions">
        <Section title="Special occasions">
          {special.isLoading ? <PlaceholderState message="Loading…" /> :
           special.data && special.data.length > 0 ? (
            <div className="tile space-y-2 text-sm">
              {special.data.map((s, i) => (
                <div key={i} className="flex items-center gap-3 border-b border-ink-200 pb-2 last:border-0 last:pb-0">
                  <span className={
                    'px-2 py-0.5 rounded text-[10px] uppercase tracking-wider font-mono ' +
                    (s.kind === 'group_booking' ? 'bg-amber-500/20 text-amber-500' : 'bg-info/20 text-info')
                  }>
                    {s.kind === 'group_booking' ? 'group booking' : 'group stay'}
                  </span>
                  <strong className="text-ink-900">{s.label}</strong>
                  <span className="text-ink-500 font-mono">{s.detail} pax</span>
                  <span className="text-xs text-ink-500 ml-auto">{s.notes}</span>
                </div>
              ))}
            </div>
           ) : <PlaceholderState message="No special occasions today." />}
          <p className="mt-2 text-[10px] text-ink-500">Bank holidays via gov.uk API: pending integration.</p>
        </Section>
      </SandboxWrapper>

      {/* ROW 5: Check-in / Stayover / Check-out lists */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-3">
        <SandboxWrapper id="dashboard.checkins" label="Check-ins">
          <Section title={`Check-ins today (${checkins.data?.length ?? 0})`}>
            <GuestList data={checkins.data} loading={checkins.isLoading} emptyMessage="No check-ins today." />
          </Section>
        </SandboxWrapper>

        <SandboxWrapper id="dashboard.stayovers" label="Stayovers">
          <Section title={`Stayovers tonight (${stayovers.data?.length ?? 0})`}>
            <GuestList data={stayovers.data} loading={stayovers.isLoading} emptyMessage="No stayovers tonight." />
          </Section>
        </SandboxWrapper>

        <SandboxWrapper id="dashboard.checkouts" label="Check-outs">
          <Section title={`Check-outs today (${checkouts.data?.length ?? 0})`}>
            <GuestList data={checkouts.data} loading={checkouts.isLoading} emptyMessage="No check-outs today." />
          </Section>
        </SandboxWrapper>
      </div>

      {/* ROW 6: Email + reviews */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-3">
        <SandboxWrapper id="dashboard.email" label="info@ inbox">
          <Section title="info@malthousetintagel.com">
            <PlaceholderState
              message="Unread count pending Gmail OAuth for info@ identity"
              hint="info account isn't in Vault (admin/info Workspace accounts need DWD migration — see GMAIL_OAUTH_RUNBOOK §B). Once seeded, /api/slug/info_unread_count returns the live number." />
          </Section>
        </SandboxWrapper>

        <SandboxWrapper id="dashboard.reviews" label="Reviews">
          <Section title="Reviews trend — last 3 days">
            <PlaceholderState
              message="Review aggregation surfaces in /comms"
              hint="Reviews scraper (U133 T8) lands data in guest_reviews. /comms shows recent reviews + 30d average per source. Add listings via review_listings table." />
          </Section>
        </SandboxWrapper>
      </div>
    </div>
  );
}

// Shared 3-column guest list component (check-ins / stayovers / check-outs).
function GuestList({ data, loading, emptyMessage }: {
  data: GuestRow[] | undefined;
  loading: boolean;
  emptyMessage: string;
}) {
  if (loading) return <PlaceholderState message="Loading…" />;
  if (!data || data.length === 0) return <PlaceholderState message={emptyMessage} />;
  return (
    <div className="tile">
      <table className="w-full text-sm">
        <thead className="text-[10px] text-ink-500 uppercase tracking-wider">
          <tr>
            <th className="text-left py-1.5 font-medium">Guest</th>
            <th className="text-left font-medium">Room</th>
            <th className="text-right font-medium">£</th>
            <th className="text-right font-medium">Pay</th>
          </tr>
        </thead>
        <tbody>
          {data.map((g, i) => (
            <tr key={i} className="border-t border-ink-200">
              <td className="py-1.5 font-medium text-ink-900">{g.guest_name}</td>
              <td className="text-ink-700 text-xs">{g.room}</td>
              <td className="text-right font-mono text-ink-700">{gbp(g.amount)}</td>
              <td className={'text-right text-xs ' + (g.payment_status === 'paid' ? 'text-good' : g.payment_status === 'unpaid' ? 'text-warn' : 'text-ink-500')}>
                {g.payment_status ?? '—'}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
