'use client';

import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import { KPICard } from '@/components/ui/KPICard';
import { SparkLine } from '@/components/ui/SparkLine';
import { WagePctBadge } from '@/components/ui/WagePctBadge';
import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import { gbp, fmtDay } from '@/lib/format';
import {
  Sunset, CloudRain, Cloud, Sun, CloudSnow,
  Bed, UtensilsCrossed, Wine, Waves,
  Users, PoundSterling, ShieldCheck, ArrowLeft,
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
interface WeekDayExtras {
  day: string;
  staff_total: number;
  staff_kitchen: number;  staff_foh: number;
  staff_accom: number;    staff_cafe: number;
  rota_cost: string | number;
  rooms_total: number;    rooms_booked: number;  rooms_left: number;
}
interface AccomToday { arrivals: number; departures: number; staying: number }
interface CoversToday {
  breakfast_count: number;
  lunch_count: number; dinner_count: number; sunday_count: number;
  lunch_pax: number | null; dinner_pax: number | null; group_count: number;
}
interface Special { kind: string; label: string; detail: number; notes: string }
interface SpecialWeek {
  day: string; kind: string; label: string;
  party_size: number; payment_status: string | null;
  deposit_pence?: number | null;
}
interface GuestRow {
  guest_name: string; room: string; amount: string | number; payment_status: string | null;
  party_size?: number | null;
}
interface TideRow {
  day: string; high_low: 'high' | 'low';
  tide_time: string; height_m: string | number;
}
interface TrailReport {
  trail_report_id: string;
  location: string;
  report_name: string;
  cadence: string;
  score_pct: string | number | null;
  tasks_total: number | null;
  tasks_completed: number | null;
  tasks_overdue: number | null;
}
interface RoomsWeek {
  week_start: string;
  room_nights_sold: number;
  room_nights_capacity: number;
  pct_occupied: string | number | null;
  avg_stay_nights: string | number | null;
  room_nights_unsold: number;
}

// WMO code → icon + label
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
function todayIsoLocal(): string {
  const t = new Date();
  return `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, '0')}-${String(t.getDate()).padStart(2, '0')}`;
}

// Traffic-light thresholds.
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
function trailClass(pct: number | null): string {
  if (pct == null) return 'text-ink-500';
  if (pct >= 95) return 'text-good';
  if (pct >= 80) return 'text-amber-500';
  return 'text-warn';
}

export default function DashboardPage() {
  const sp = useSearchParams();
  const today = todayIsoLocal();
  const dateParam = sp.get('date');
  const viewDate = dateParam || today;
  const isToday = viewDate === today;
  // Slug params: only pass `date` if it's a non-today view; otherwise leave
  // empty so slug COALESCEs to CURRENT_DATE on the server (avoids client/
  // server TZ drift around midnight).
  const dateArg: Record<string, string> = isToday ? {} : { date: viewDate };

  const gross    = useSlug<TodayGross>('frontend_today_gross', dateArg, { refetchInterval: 60_000 });
  const labour   = useSlug<LabourRow>('dashboard_labour_yesterday');
  const week     = useSlug<WeekDay>('dashboard_week_strip', {}, { refetchInterval: 5 * 60_000 });
  const extras   = useSlug<WeekDayExtras>('dashboard_week_strip_extras', {}, { refetchInterval: 5 * 60_000 });
  // U192 — anomaly pulse: rows with { day, daily, dow_mean, dow_sd, z_score, anomalous }
  const anomalies = useSlug<{ day: string; z_score: string | null; anomalous: boolean }>('week_strip_anomalies_7d', {}, { refetchInterval: 5 * 60_000 });
  // U185 — sparklines: 7-day arrays { values: number[] }
  const revSpark    = useSlug<{ values: number[] }>('revenue_spark_7d',    {}, { refetchInterval: 10 * 60_000 });
  const labSpark    = useSlug<{ values: number[] }>('labour_pct_spark_7d', {}, { refetchInterval: 10 * 60_000 });
  const occSpark    = useSlug<{ values: number[] }>('occupancy_spark_7d',  {}, { refetchInterval: 10 * 60_000 });
  const tides    = useSlug<TideRow>('dashboard_tides_next_7d', {}, { refetchInterval: 60 * 60_000 });
  const specials = useSlug<SpecialWeek>('dashboard_specials_next_7d', {}, { refetchInterval: 5 * 60_000 });
  const accom    = useSlug<AccomToday>('frontend_accommodation_today', dateArg, { refetchInterval: 60_000 });
  const covers   = useSlug<CoversToday>('dashboard_covers_today', dateArg, { refetchInterval: 60_000 });
  const special  = useSlug<Special>('dashboard_special_today', dateArg);
  const checkins  = useSlug<GuestRow>('dashboard_checkins_today', dateArg);
  const stayovers = useSlug<GuestRow>('dashboard_stayovers_today', dateArg);
  const checkouts = useSlug<GuestRow>('dashboard_checkouts_today', dateArg);
  const trail    = useSlug<TrailReport>('trail_reports_today', dateArg, { refetchInterval: 10 * 60_000 });
  const roomsWk  = useSlug<RoomsWeek>('rooms_week_economics', dateArg);

  const pub  = gross.data?.find(r => r.site === 'malthouse');
  const cafe = gross.data?.find(r => r.site === 'sandwich');
  const total = (parseFloat(pub?.gross ?? '0') + parseFloat(cafe?.gross ?? '0')) || 0;

  const lab = (w: number) => labour.data?.find(r => Number(r.window_days) === w);

  function ratio(c: string | null | undefined, s: string | null | undefined): number | null {
    const cn = parseFloat(c ?? ''); const sn = parseFloat(s ?? '');
    if (!Number.isFinite(cn) || !Number.isFinite(sn) || sn === 0) return null;
    return (cn / sn) * 100;
  }

  // Group week-strip context by day for tide + specials + extras lookup
  const tidesByDay: Record<string, TideRow[]> = {};
  (tides.data ?? []).forEach(t => { (tidesByDay[t.day] ||= []).push(t); });
  const specialsByDay: Record<string, SpecialWeek[]> = {};
  (specials.data ?? []).forEach(s => { (specialsByDay[s.day] ||= []).push(s); });
  const extrasByDay: Record<string, WeekDayExtras> = {};
  (extras.data ?? []).forEach(e => { extrasByDay[e.day] = e; });
  const anomaliesByDay: Record<string, { z: number }> = {};
  (anomalies.data ?? []).forEach(a => {
    if (!a.anomalous) return;
    const z = parseFloat(a.z_score ?? '0');
    // Slug returns ISO timestamps for `day`; normalise to YYYY-MM-DD
    const key = (a.day || '').slice(0, 10);
    if (key) anomaliesByDay[key] = { z };
  });

  const roomsWeek = roomsWk.data?.[0];

  return (
    <div className="space-y-5">
      {/* ROW 1: Revenue tile + Labour tile */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-3">
        <SandboxWrapper id="dashboard.revenue" label="Revenue today">
          <Link href={isToday ? '/sales' : `/sales?date=${viewDate}`} className="block">
            <div className="tile group">
              <div className="label">{isToday ? 'Gross today' : `Gross — ${viewDate}`}</div>
              <div className={'kpi-xl mt-1 ' + (gross.isLoading ? '' : grossClass(total))}>
                {gross.isLoading ? <span className="inline-block w-32 h-10 bg-ink-200 rounded animate-pulse" /> : gbp(total)}
              </div>
              <div className="mt-2 flex gap-5 text-sm font-mono">
                <span><span className="text-ink-500">Pub</span> <strong className="text-ink-900">{gbp(pub?.gross ?? 0)}</strong></span>
                <span><span className="text-ink-500">Café</span> <strong className="text-ink-900">{gbp(cafe?.gross ?? 0)}</strong></span>
              </div>
              {/* U185 — 7-day sparkline */}
              {revSpark.data?.[0]?.values && revSpark.data[0].values.length > 1 && (
                <div className="mt-2 h-6 opacity-60">
                  <SparkLine values={revSpark.data[0].values.map(v => Number(v) || 0)} />
                </div>
              )}
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
              {/* U185 — 7-day labour% sparkline */}
              {labSpark.data?.[0]?.values && labSpark.data[0].values.length > 1 && (
                <div className="mt-2 h-6 opacity-60">
                  <SparkLine values={labSpark.data[0].values.map(v => Number(v) || 0)} colour="#fbbf24" />
                </div>
              )}
              <div className="mt-2 text-[11px] text-amber-500 group-hover:text-amber-400">→ Click for Staff detail</div>
            </div>
          </Link>
        </SandboxWrapper>
      </div>

      {/* ROW 2: 7-day week strip (today + 6 forward) — each day is a Link */}
      <SandboxWrapper id="dashboard.week" label="Week strip">
        <Section title="Week ahead — click a day to drill in">
          {week.isLoading ? <PlaceholderState message="Loading week strip…" /> :
           week.data && week.data.length > 0 ? (
            <div className="grid grid-cols-7 gap-2">
              {week.data.map((d) => {
                const dIsToday = d.day === today;
                const dIsActive = d.day === viewDate;
                const cls = weatherClass(d.weather_code, d.rain_mm ? parseFloat(d.rain_mm) : null, d.max_temp ? parseFloat(d.max_temp) : null);
                const Icon = weatherIcon(d.weather_code);
                // "Today" tile is special when we're in day-view: highlight as
                // CTA (green) for "back to today". Otherwise normal ring rules.
                const ring = (dIsToday && !isToday) ? 'ring-2 ring-good' :
                             dIsActive ? 'ring-2 ring-amber-500' :
                             cls === 'good' ? 'ring-1 ring-good/70' :
                             cls === 'bad'  ? 'ring-1 ring-warn/70' : '';
                const href = dIsToday ? '/' : `/?date=${d.day}`;
                const dayTides    = tidesByDay[d.day] ?? [];
                const daySpecials = specialsByDay[d.day] ?? [];
                const dayExtras   = extrasByDay[d.day];
                const dayAnomaly  = anomaliesByDay[d.day];
                const pulse       = dayAnomaly ? 'anomaly-pulse' : '';
                const anomTitle   = dayAnomaly ? `Revenue anomaly (z=${dayAnomaly.z.toFixed(2)} vs same-DoW baseline)` : undefined;
                return (
                  <Link key={d.day} href={href} className={`tile flex flex-col text-[11px] gap-1 cursor-pointer transition-shadow hover:ring-2 hover:ring-amber-500 ${ring} ${pulse}`} title={anomTitle}>
                    {/* Day header + weather icon */}
                    <div className="flex items-center justify-between">
                      <span className={'label ' + (dIsActive ? 'text-amber-500' : dIsToday && !isToday ? 'text-good font-semibold' : '')}>
                        {fmtDay(d.day)}
                      </span>
                      <Icon size={14} className={cls === 'good' ? 'text-amber-500' : cls === 'bad' ? 'text-warn' : 'text-ink-500'} />
                    </div>
                    {/* Back-to-today CTA on today-tile when in day-view */}
                    {dIsToday && !isToday && (
                      <div className="flex items-center gap-1 text-[9px] uppercase tracking-wider text-good font-semibold">
                        <ArrowLeft size={9} /> Back to today
                      </div>
                    )}
                    {/* Temp + rain */}
                    <div className="font-mono text-ink-900">
                      {d.max_temp ? `${parseFloat(d.max_temp).toFixed(0)}°` : '—'}{' '}
                      <span className="text-ink-500 text-[10px]">
                        {d.precipitation_probability != null ? `${d.precipitation_probability}%🌧` :
                         d.rain_mm ? `${parseFloat(d.rain_mm).toFixed(1)}mm` : ''}
                      </span>
                    </div>
                    <div className="text-[10px] text-ink-500">{weatherLabel(d.weather_code)}</div>
                    {/* Sunset */}
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
                    {/* Rooms — booked / total with "left to sell" suffix */}
                    {dayExtras && dayExtras.rooms_total > 0 && (
                      <div className="flex items-center gap-1 text-[10px] text-ink-700">
                        <Bed size={11} className="text-ink-500" />
                        <span>
                          {dayExtras.rooms_booked}/{dayExtras.rooms_total}
                          {dayExtras.rooms_left > 0 && <span className="text-amber-500"> · {dayExtras.rooms_left} left</span>}
                        </span>
                      </div>
                    )}
                    {/* Covers */}
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
                    {/* Staff on rota + rota cost */}
                    {dayExtras && dayExtras.staff_total > 0 && (
                      <>
                        <div className="flex items-center gap-1 text-[10px] text-ink-700">
                          <Users size={11} className="text-ink-500" />
                          <span>
                            {dayExtras.staff_total} on rota
                            <span className="text-ink-500 ml-1">
                              {dayExtras.staff_kitchen > 0 && `K${dayExtras.staff_kitchen} `}
                              {dayExtras.staff_foh > 0 && `F${dayExtras.staff_foh} `}
                              {dayExtras.staff_accom > 0 && `A${dayExtras.staff_accom} `}
                              {dayExtras.staff_cafe > 0 && `C${dayExtras.staff_cafe}`}
                            </span>
                          </span>
                        </div>
                        <div className="flex items-center gap-1 text-[10px] text-ink-700">
                          <PoundSterling size={11} className="text-ink-500" />
                          <span className="font-mono">{gbp(dayExtras.rota_cost, 0)}</span>
                        </div>
                      </>
                    )}
                    {/* Specials + deposit-bearing reservations */}
                    {daySpecials.length > 0 && (
                      <div className="mt-1 pt-1 border-t border-ink-200 text-[10px] text-ink-700">
                        <div className="flex items-center gap-1 text-amber-500 uppercase tracking-wider text-[9px] mb-0.5">
                          <Wine size={10} />Groups · Deposits
                        </div>
                        {daySpecials.slice(0, 3).map((s, i) => (
                          <div key={i} className="leading-tight truncate">
                            {s.label} · {s.party_size}
                            {s.deposit_pence != null && s.deposit_pence > 0 && (
                              <span className="text-good"> · £{(s.deposit_pence / 100).toFixed(0)}</span>
                            )}
                          </div>
                        ))}
                        {daySpecials.length > 3 && (
                          <div className="text-[10px] text-ink-500">+{daySpecials.length - 3} more</div>
                        )}
                      </div>
                    )}
                  </Link>
                );
              })}
            </div>
          ) : <PlaceholderState message="No week data — weather forecast cache may need refresh." />}
        </Section>
      </SandboxWrapper>

      {/* ROW 2.5: Rooms — this week (bold rooms-left callout) */}
      <SandboxWrapper id="dashboard.rooms_week" label="Rooms this week">
        <Section title={`Rooms — week of ${roomsWeek?.week_start ?? '…'} (Monday-anchored)`}>
          {/* Prominent callout: rooms still to sell this week */}
          {roomsWeek && (
            <div className="mb-3">
              {roomsWeek.room_nights_unsold > 0 ? (
                <div className="text-2xl font-bold text-amber-500">
                  {roomsWeek.room_nights_unsold} room {roomsWeek.room_nights_unsold === 1 ? 'night' : 'nights'} still to sell this week
                </div>
              ) : (
                <div className="text-2xl font-bold text-good">
                  Fully booked this week 🎉
                </div>
              )}
            </div>
          )}
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
            <KPICard label="Nights sold"
              value={roomsWeek?.room_nights_sold ?? '—'}
              loading={roomsWk.isLoading}
              rollingAvg={roomsWeek ? [{ label: 'of', value: roomsWeek.room_nights_capacity }] : undefined} />
            <KPICard label="Nights unsold"
              value={roomsWeek?.room_nights_unsold ?? '—'}
              loading={roomsWk.isLoading} />
            <KPICard label="% occupied"
              value={roomsWeek?.pct_occupied != null ? `${roomsWeek.pct_occupied}%` : '—'}
              loading={roomsWk.isLoading}
              spark={occSpark.data?.[0]?.values?.map(v => Number(v) || 0)} />
            <KPICard label="Avg stay"
              value={roomsWeek?.avg_stay_nights != null ? `${parseFloat(String(roomsWeek.avg_stay_nights)).toFixed(1)} nights` : '—'}
              loading={roomsWk.isLoading} />
          </div>
        </Section>
      </SandboxWrapper>

      {/* ROW 3: Quick counts — now 6 cards (added Breakfast) */}
      <SandboxWrapper id="dashboard.counts" label="Today counts">
        <Section title={isToday ? 'Today at a glance' : `${viewDate} at a glance`}>
          <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
            <KPICard label="Rooms booked" value={accom.data?.[0]?.staying ?? '—'} loading={accom.isLoading} />
            <KPICard label="Arrivals"    value={accom.data?.[0]?.arrivals ?? '—'} loading={accom.isLoading} />
            <KPICard label="Departures"  value={accom.data?.[0]?.departures ?? '—'} loading={accom.isLoading} />
            <KPICard label="Breakfast"   value={covers.data?.[0]?.breakfast_count ?? 0} loading={covers.isLoading} />
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
           ) : <PlaceholderState message="No special occasions for this day." />}
        </Section>
      </SandboxWrapper>

      {/* ROW 5: Check-in / Stayover / Check-out lists */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-3">
        <SandboxWrapper id="dashboard.checkins" label="Check-ins">
          <Section title={`Check-ins ${isToday ? 'today' : viewDate} (${checkins.data?.length ?? 0})`}>
            <GuestList data={checkins.data} loading={checkins.isLoading} emptyMessage="No check-ins." />
          </Section>
        </SandboxWrapper>
        <SandboxWrapper id="dashboard.stayovers" label="Stayovers">
          <Section title={`Stayovers tonight (${stayovers.data?.length ?? 0})`}>
            <GuestList data={stayovers.data} loading={stayovers.isLoading} emptyMessage="No stayovers." />
          </Section>
        </SandboxWrapper>
        <SandboxWrapper id="dashboard.checkouts" label="Check-outs">
          <Section title={`Check-outs ${isToday ? 'today' : viewDate} (${checkouts.data?.length ?? 0})`}>
            <GuestList data={checkouts.data} loading={checkouts.isLoading} emptyMessage="No check-outs." />
          </Section>
        </SandboxWrapper>
      </div>

      {/* ROW 6: Trail compliance */}
      <SandboxWrapper id="dashboard.trail" label="Trail compliance">
        <Section title={`Trail — ${isToday ? 'today' : viewDate}`}>
          {trail.isLoading ? <PlaceholderState message="Loading…" /> :
           trail.data && trail.data.length > 0 ? (
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
              {trail.data.map((r) => {
                const pct = r.score_pct != null ? parseFloat(String(r.score_pct)) : null;
                return (
                  <div key={r.trail_report_id} className="tile">
                    <div className="flex items-center justify-between">
                      <div className="text-xs text-ink-500 uppercase tracking-wider">{r.location}</div>
                      <ShieldCheck size={14} className={trailClass(pct)} />
                    </div>
                    <div className="mt-1 font-medium text-ink-900 text-sm">{r.report_name}</div>
                    <div className={'mt-2 text-2xl font-mono font-semibold ' + trailClass(pct)}>
                      {pct != null ? `${pct.toFixed(0)}%` : '—'}
                    </div>
                    <div className="mt-1 text-[11px] text-ink-500 font-mono">
                      {r.tasks_completed ?? 0}/{r.tasks_total ?? 0} tasks
                      {(r.tasks_overdue ?? 0) > 0 && <span className="text-warn"> · {r.tasks_overdue} overdue</span>}
                    </div>
                  </div>
                );
              })}
            </div>
          ) : (
            <PlaceholderState
              message="No Trail reports yet"
              hint="Once the Trail API endpoint is verified and the cron runs (scripts/u134-trail-poll.py), reports populate here. Key already stashed in Vault at secret/trail." />
          )}
        </Section>
      </SandboxWrapper>

      {/* ROW 7: Email + reviews placeholders */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-3">
        <SandboxWrapper id="dashboard.email" label="info@ inbox">
          <Section title="info@malthousetintagel.com">
            <PlaceholderState
              message="Unread count pending Gmail OAuth for info@ identity"
              hint="info account isn't in Vault. Once seeded, /api/slug/info_unread_count returns the live number." />
          </Section>
        </SandboxWrapper>
        <SandboxWrapper id="dashboard.reviews" label="Reviews">
          <Section title="Reviews trend">
            <PlaceholderState
              message="Reviews surface in /comms"
              hint="Reviews scraper (U133 T8) lands data in guest_reviews. Add listings via review_listings table." />
          </Section>
        </SandboxWrapper>
      </div>
    </div>
  );
}

// Shared 3-column guest list component.
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
