'use client';

import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import { KPICard } from '@/components/ui/KPICard';
import { WagePctBadge } from '@/components/ui/WagePctBadge';
import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { PollClock } from '@/components/ui/PollClock';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { KpiTrafficLight } from '@/components/ui/KpiTrafficLight';
import { useSlug } from '@/lib/hooks';
import { gbp, fmtDay, formatRoom } from '@/lib/format';
import {
  Sunset, CloudRain, Cloud, Sun, CloudSnow,
  Bed, UtensilsCrossed, Wine, Waves,
  Users, PoundSterling, ShieldCheck, ArrowLeft,
  Upload,
} from 'lucide-react';

interface TodayGross { site: string; gross: string; as_of?: string }
interface LabourRow {
  window_days: number;
  pub_labour_avg: string | null;  pub_sales_avg: string | null;
  cafe_labour_avg: string | null; cafe_sales_avg: string | null;
  pub_labour_total: string | null;  pub_sales_total: string | null;
  cafe_labour_total: string | null; cafe_sales_total: string | null;
  days_with_data: number | null;
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
  if (/^\d{2}:\d{2}:\d{2}$/.test(iso)) {
    const [h, m] = iso.split(':');
    const hh = parseInt(h, 10);
    const ampm = hh >= 12 ? 'pm' : 'am';
    const h12 = hh % 12 || 12;
    return `${h12}:${m}${ampm}`;
  }
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '—';
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
  // U211 — reviews 30d
  const reviewsSpk  = useSlug<{ rating_spark: number[]; count_spark: string[]; total_reviews_30d: number; avg_rating_30d: string | null }>('reviews_rating_spark_30d', {}, { refetchInterval: 30 * 60_000 });
  // U212 — email tasks (OAuth confirmed healthy)
  const emailKpis   = useSlug<{ tasks_open: string; instructions_pending: string; last_instruction_at: string | null }>('work_email_kpis', {}, { refetchInterval: 5 * 60_000 });
  const priorityEmail = useSlug<any>('dashboard_email_priority', {}, { refetchInterval: 5 * 60_000 });
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
  const freshness = useSlug<{ source: string; age_h: string; expected_hours: number; status: string }>('data_source_freshness', {}, { refetchInterval: 5 * 60_000 });
  const staleSources = (freshness.data ?? []).filter(f => f.status === 'STALE' || f.status === 'stale' || f.status === 'never');
  // U234 — Hermes-flagged: surface the daily manual-upload list on the dashboard
  // so it's not only visible via the 08:00 Telegram + morning email.
  const manualUploads = useSlug<{ kind: string; source: string; label: string; last_dated: string | null; days_stale: number | null; status: string }>(
    'manual_data_pending_uploads', {}, { refetchInterval: 10 * 60_000 });
  const manualStaleCount = (manualUploads.data ?? []).filter(r => r.status === 'stale' || r.status === 'never').length;
  const manualWarnCount  = (manualUploads.data ?? []).filter(r => r.status === 'warn').length;
  const manualWorst = (manualUploads.data ?? [])[0]; // slug already orders worst-first
  const polls = useSlug<{ source: string; last_poll: string | null }>('sales_last_poll_per_source', {}, { refetchInterval: 60_000 });
  const pubPoll = polls.data?.find(p => p.source === 'touchoffice_malthouse')?.last_poll ?? null;

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

  // Hermes B3: persistent day-view banner so the historical context is
  // visible above the fold regardless of scroll position.
  const viewedDate = new Date(viewDate + 'T00:00:00');
  const viewedLabel = viewedDate.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'long', year: 'numeric' });

  return (
    <div className="space-y-6">
      {!isToday && (
        <div
          role="status"
          className="rounded border border-amber-600/60 bg-amber-950/40 px-3 py-2 text-sm text-amber-200 flex items-center justify-between gap-3 flex-wrap"
        >
          <div>
            <strong className="text-amber-300">📅 Viewing {viewedLabel}</strong>
            <span className="ml-2 text-amber-200/80">— historical data (no live updates)</span>
          </div>
          <Link
            href="/"
            className="inline-flex items-center gap-1 px-2.5 py-1 rounded bg-amber-500 text-ink-0 text-xs font-medium hover:bg-amber-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-300"
          >
            <ArrowLeft size={12} /> Back to today
          </Link>
        </div>
      )}
      {staleSources.length > 0 && (
        <div className="rounded border border-red-600 bg-red-950/40 px-3 py-2 text-sm text-red-200">
          <strong className="text-red-300">⚠ Stale data:</strong>{' '}
          {staleSources.map(s => {
            const h = parseFloat(String(s.age_h));
            const hStr = Number.isFinite(h) ? `${Math.round(h)}h` : '?';
            return `${s.source} (${hStr}, expected ${s.expected_hours}h)`;
          }).join(' · ')}
          {' — '}
          <span className="text-red-300">numbers on this page may be out-of-date.</span>
        </div>
      )}
      {/* KPI traffic-light band (U234) — management + operational, with levers */}
      {isToday && (
        <SandboxWrapper id="dashboard.kpis" label="KPI traffic light">
          <KpiTrafficLight />
        </SandboxWrapper>
      )}

      {/* ROW 1: Revenue tile + Labour tile */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-3">
        <SandboxWrapper id="dashboard.revenue" label="Revenue today">
          <Link href={isToday ? '/sales' : `/sales?date=${viewDate}`} className="block">
            <div className="tile group">
              <div className="label flex items-center gap-2">
                <span>{isToday ? 'Gross today' : `Gross — ${viewDate}`}</span>
                <PollClock lastPoll={pubPoll} label="touchoffice pub" redAtMin={15} greenBelowMin={3} />
              </div>
              <div className={'kpi-xl mt-1 ' + (gross.isLoading ? '' : grossClass(total))}>
                {gross.isLoading ? <span className="inline-block w-32 h-10 bg-ink-200 rounded animate-pulse" /> : gbp(total)}
              </div>
              {(() => {
                const asOf = pub?.as_of ?? cafe?.as_of;
                const today = new Date().toISOString().slice(0, 10);
                if (!asOf || asOf === today) return null;
                return (
                  <div className="mt-1 text-sm text-red-400 flex items-center gap-1">
                    ⚠ figures are for {asOf} (no till data for today yet)
                  </div>
                );
              })()}
              <div className="mt-2 flex gap-5 text-sm font-mono">
                <span><span className="text-ink-500">Pub (food+bar)</span> <strong className="text-ink-900">{gbp(pub?.gross ?? 0)}</strong></span>
                <span><span className="text-ink-500">Café</span> <strong className="text-ink-900">{gbp(cafe?.gross ?? 0)}</strong></span>
              </div>
              <div className="mt-2 text-sm text-amber-500 group-hover:text-amber-400">→ Click for Sales detail</div>
            </div>
          </Link>
        </SandboxWrapper>

        <SandboxWrapper id="dashboard.labour" label="Labour vs sales">
          <Link href="/staff" className="block">
            <div className="tile group">
              <div className="label flex items-center gap-2">Labour vs sales <span className="text-ink-600 text-xs normal-case tracking-normal">yesterday + rolling avg</span></div>
              <div className="mt-2 grid grid-cols-3 gap-2 text-xs">
                {[{w: 1, name: 'Yesterday'}, {w: 7, name: '7 day'}, {w: 30, name: '30 day'}].map(({w, name}) => {
                  const r = lab(w);
                  const pubR = ratio(r?.pub_labour_avg, r?.pub_sales_avg);
                  const cafR = ratio(r?.cafe_labour_avg, r?.cafe_sales_avg);
                  const combL = (parseFloat(r?.pub_labour_avg ?? '0') + parseFloat(r?.cafe_labour_avg ?? '0'));
                  const combS = (parseFloat(r?.pub_sales_avg ?? '0') + parseFloat(r?.cafe_sales_avg ?? '0'));
                  const combR = combS > 0 ? (combL / combS) * 100 : null;
                  const totL = (parseFloat(r?.pub_labour_total ?? '0') + parseFloat(r?.cafe_labour_total ?? '0'));
                  const totS = (parseFloat(r?.pub_sales_total ?? '0')  + parseFloat(r?.cafe_sales_total ?? '0'));
                  const showTotalsRow = w > 1;
                  return (
                    <div key={w} className="bg-ink-100 rounded p-2">
                      <div className="text-xs text-ink-500 uppercase tracking-wider">{name}{r?.days_with_data ? ` (${r.days_with_data}d data)` : ''}</div>
                      <div className={'mt-1 text-base font-mono font-semibold ' + labourClass(combR)}>
                        {combR === null ? '—' : `${combR.toFixed(1)}%`}
                      </div>
                      {showTotalsRow && (
                        <div className="mt-1 grid grid-cols-2 gap-1 text-xs leading-tight">
                          <div>
                            <div className="text-ink-500 uppercase tracking-wider">Total L</div>
                            <div className="font-mono text-ink-900">{totS > 0 ? gbp(totL, 0) : '—'}</div>
                          </div>
                          <div>
                            <div className="text-ink-500 uppercase tracking-wider">Total S</div>
                            <div className="font-mono text-ink-900">{totS > 0 ? gbp(totS, 0) : '—'}</div>
                          </div>
                        </div>
                      )}
                      <div className="mt-1 grid grid-cols-2 gap-1 text-xs leading-tight">
                        <div>
                          <div className="text-ink-500 uppercase tracking-wider">{showTotalsRow ? 'Avg L/d' : 'Labour'}</div>
                          <div className="font-mono text-ink-900">{combS > 0 ? gbp(combL, 0) : '—'}</div>
                        </div>
                        <div>
                          <div className="text-ink-500 uppercase tracking-wider">{showTotalsRow ? 'Avg S/d' : 'Sales'}</div>
                          <div className="font-mono text-ink-900">{combS > 0 ? gbp(combS, 0) : '—'}</div>
                        </div>
                      </div>
                      <div className="mt-1 flex gap-2 text-xs">
                        <WagePctBadge pct={pubR} label="pub" />
                        <WagePctBadge pct={cafR} label="cafe" />
                      </div>
                    </div>
                  );
                })}
              </div>
              <div className="mt-2 text-sm text-amber-500 group-hover:text-amber-400">→ Click for Staff detail</div>
            </div>
          </Link>
        </SandboxWrapper>
      </div>

      {/* ROW 2: 7-day week strip (today + 6 forward) — each day is a Link */}
      <SandboxWrapper id="dashboard.week" label="Week strip">
        <Section title="Week ahead — click a day to drill in">
          {week.isLoading ? <PlaceholderState message="Loading week strip…" /> :
           week.data && week.data.length > 0 ? (
            <div className="grid grid-cols-7 gap-2 scroll-snap-x md:overflow-visible">
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
                  <Link key={d.day} href={href} className={`tile flex flex-col text-sm gap-1 cursor-pointer transition-shadow hover:ring-2 hover:ring-amber-500 ${ring} ${pulse}`} title={anomTitle}>
                    {/* Day header + weather icon */}
                    <div className="flex items-center justify-between">
                      <span className={'label ' + (dIsActive ? 'text-amber-500' : dIsToday && !isToday ? 'text-good font-semibold' : '')}>
                        {fmtDay(d.day)}
                      </span>
                      <Icon size={14} className={cls === 'good' ? 'text-amber-500' : cls === 'bad' ? 'text-warn' : 'text-ink-500'} />
                    </div>
                    {/* Back-to-today CTA on today-tile when in day-view */}
                    {dIsToday && !isToday && (
                      <div className="flex items-center gap-1 text-xs uppercase tracking-wider text-good font-semibold">
                        <ArrowLeft size={9} /> Back to today
                      </div>
                    )}
                    {/* Temp + rain */}
                    <div className="font-mono text-ink-900">
                      {d.max_temp ? `${parseFloat(d.max_temp).toFixed(0)}°` : '—'}{' '}
                      <span className="text-ink-500 text-xs">
                        {d.precipitation_probability != null ? `${d.precipitation_probability}%🌧` :
                         d.rain_mm ? `${parseFloat(d.rain_mm).toFixed(1)}mm` : ''}
                      </span>
                    </div>
                    <div className="text-xs text-ink-500">{weatherLabel(d.weather_code)}</div>
                    {/* Sunset */}
                    <div className="flex items-center gap-1 text-xs text-ink-700">
                      <Sunset size={11} className="text-amber-500" />
                      <span className="font-mono">{timeOnly(d.sunset)}</span>
                    </div>
                    {/* Tides */}
                    {dayTides.length > 0 && (
                      <div className="text-xs text-ink-600 leading-tight flex items-start gap-1">
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
                      <div className="flex items-center gap-1 text-xs text-ink-700">
                        <Bed size={11} className="text-ink-500" />
                        <span>
                          {dayExtras.rooms_booked}/{dayExtras.rooms_total}
                          {dayExtras.rooms_left > 0 && <span className="text-amber-500"> · {dayExtras.rooms_left} left</span>}
                        </span>
                      </div>
                    )}
                    {/* Covers */}
                    {(d.lunch_count > 0 || d.dinner_count > 0) && (
                      <div className="flex items-center gap-1 text-xs text-ink-700">
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
                        <div className="flex items-center gap-1 text-xs text-ink-700">
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
                        <div className="flex items-center gap-1 text-xs text-ink-700">
                          <PoundSterling size={11} className="text-ink-500" />
                          <span className="font-mono">{gbp(dayExtras.rota_cost, 0)}</span>
                        </div>
                      </>
                    )}
                    {/* Specials + deposit-bearing reservations */}
                    {daySpecials.length > 0 && (
                      <div className="mt-1 pt-1 border-t border-ink-200 text-xs text-ink-700">
                        <div className="flex items-center gap-1 text-amber-500 uppercase tracking-wider text-xs mb-0.5">
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
                          <div className="text-xs text-ink-500">+{daySpecials.length - 3} more</div>
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
        <Section title={`Rooms — next 7 nights from ${roomsWeek?.week_start ? new Date(roomsWeek.week_start).toLocaleDateString('en-GB', {day:'2-digit', month:'short'}) : '…'}`}>
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
              />
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

      {/* ROW 4: Check-in / Stayover / Check-out lists */}
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
                    <div className="mt-1 text-sm text-ink-500 font-mono">
                      {r.tasks_completed ?? 0}/{r.tasks_total ?? 0} tasks
                      {(r.tasks_overdue ?? 0) > 0 && <span className="text-warn"> · {r.tasks_overdue} overdue</span>}
                    </div>
                  </div>
                );
              })}
            </div>
          ) : (
            <PlaceholderState
              message="No Trail reports for this date"
              hint="Trail checks run at 7:30 am, 1:30 pm, and 7:30 pm. Most recent results shown." />
          )}
        </Section>
      </SandboxWrapper>

      {/* ROW 7: Email + Manual uploads + Reviews */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
        <SandboxWrapper id="dashboard.email" label="Email tasks">
          <Section title="Email tasks">
            <div className="tile">
              <div className="flex items-center justify-between mb-3">
                <div>
                  <div className="label">Total flagged</div>
                  <div className="kpi-xl mt-1">{emailKpis.data?.[0]?.tasks_open ?? '—'}</div>
                </div>
                <div className="text-right text-xs text-ink-500">
                  <div>{emailKpis.data?.[0]?.instructions_pending ?? 0} bot pending</div>
                  <div className="font-semibold text-warn">{priorityEmail.data?.length ?? 0} need action</div>
                </div>
              </div>
              <div className="grid grid-cols-2 gap-2 mb-3">
                {(() => {
                  const byKw: Record<string, { items: any[]; maxSev: number }> = {};
                  for (const e of priorityEmail.data ?? []) {
                    const kw = e.matched_keyword || 'other';
                    if (!byKw[kw]) byKw[kw] = { items: [], maxSev: 0 };
                    byKw[kw].items.push(e);
                    if (e.severity > byKw[kw].maxSev) byKw[kw].maxSev = e.severity;
                  }
                  const kwOrder = ['urgent', 'complaint', 'overdue', 'dissatisfied', 'salary', 'credit control', 'final reminder'];
                  const sorted = Object.entries(byKw).sort(([a], [b]) => {
                    const ia = kwOrder.indexOf(a), ib = kwOrder.indexOf(b);
                    return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib);
                  });
                  return sorted.map(([kw, info]) => (
                    <div key={kw} className={'rounded px-2 py-1.5 border ' + (
                      info.maxSev >= 5 ? 'bg-red-900/20 border-red-800/40' :
                      info.maxSev >= 4 ? 'bg-orange-900/20 border-orange-800/40' :
                      'bg-amber-900/15 border-amber-800/30'
                    )}>
                      <div className={'text-2xs uppercase tracking-wider font-medium ' + (
                        info.maxSev >= 5 ? 'text-red-400' :
                        info.maxSev >= 4 ? 'text-orange-400' : 'text-amber-400'
                      )}>{kw}</div>
                      <div className="flex items-baseline gap-1 mt-0.5">
                        <span className="text-sm font-bold text-ink-900">{info.items.length}</span>
                        <span className="text-2xs text-ink-500">open</span>
                      </div>
                      <div className="text-2xs text-ink-500 truncate mt-0.5" title={info.items.map((i: any) => i.subject).join(' | ')}>
                        {info.items[0]?.subject.slice(0, 40) || ''}
                      </div>
                    </div>
                  ));
                })()}
              </div>
              <Link href="/comms" className="block text-sm text-amber-500 hover:text-amber-400 font-medium">
                → Manage all flagged emails
              </Link>
            </div>
          </Section>
        </SandboxWrapper>
        <SandboxWrapper id="dashboard.manual-uploads" label="Manual uploads">
          <Section title="Manual uploads pending">
            {manualUploads.isLoading ? (
              <PlaceholderState message="Loading…" />
            ) : (manualUploads.data ?? []).length === 0 ? (
              <div className="tile">
                <div className="label">All caught up</div>
                <div className="kpi-xl mt-1 text-good">✓ 0</div>
                <div className="mt-1 text-sm text-ink-500">
                  Bank, card, mortgage, and Dojo all within window.
                </div>
              </div>
            ) : (
              <Link
                href="/admin"
                className="block focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500 rounded"
              >
                <div className="tile group">
                  <div className="label flex items-center gap-2">
                    <Upload size={14} className={manualStaleCount > 0 ? 'text-warn' : 'text-amber-500'} />
                    <span>Items to upload</span>
                  </div>
                  <div className={'kpi-xl mt-1 ' + (manualStaleCount > 0 ? 'text-warn' : 'text-amber-500')}>
                    {(manualUploads.data ?? []).length}
                  </div>
                  <div className="mt-1 text-sm text-ink-500">
                    {manualStaleCount} stale · {manualWarnCount} warn
                  </div>
                  {manualWorst && (
                    <div className="mt-1 text-sm text-ink-600 truncate" title={`${manualWorst.source} · ${manualWorst.label}`}>
                      worst: {manualWorst.source}{manualWorst.days_stale != null ? ` (${manualWorst.days_stale}d)` : ''}
                    </div>
                  )}
                  <div className="mt-2 text-sm text-amber-500 group-hover:text-amber-400">→ Check this morning's email</div>
                </div>
              </Link>
            )}
          </Section>
        </SandboxWrapper>
        <SandboxWrapper id="dashboard.reviews" label="Reviews">
          <Section title="Reviews — 30d trend">
            {reviewsSpk.isLoading ? <PlaceholderState message="Loading reviews…" /> :
             reviewsSpk.data?.[0]?.total_reviews_30d ? (
              <Link href="/comms" className="block">
                <div className="tile group">
                  <div className="flex items-baseline justify-between gap-2">
                    <div>
                      <div className="label">30d avg</div>
                      <div className="kpi-xl">{reviewsSpk.data[0].avg_rating_30d ? `${parseFloat(reviewsSpk.data[0].avg_rating_30d).toFixed(2)}★` : '—'}</div>
                    </div>
                    <div className="text-right">
                      <div className="label">count</div>
                      <div className="kpi">{reviewsSpk.data[0].total_reviews_30d}</div>
                    </div>
                  </div>

                  <div className="mt-2 text-sm text-amber-500 group-hover:text-amber-400">→ Click for full reviews</div>
                </div>
              </Link>
            ) : <PlaceholderState message="No reviews in last 30 days." />}
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
        <thead className="text-xs text-ink-500 uppercase tracking-wider">
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
              <td className="text-ink-700 text-xs font-mono">{formatRoom(g.room)}</td>
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
