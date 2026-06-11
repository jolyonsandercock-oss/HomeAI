'use client';

import { FreshnessBadge } from '@/components/ui/FreshnessBadge';
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
import { CheckCircle2, AlertTriangle, Circle } from 'lucide-react';

interface TandaStatus {
  users_last_sync: string;
  active_user_count: number;
  latest_shift_date: string;
  upcoming_shifts: number;
  hours_since_user_sync: string;
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
interface AttributionRow {
  user_external_id: number;
  full_name: string;
  team: string;
  hours: string | number;
  cost: string | number;
  attributed_revenue: string | number;
  gp_per_hour: string | number | null;
}
interface HolidayRow {
  id: number;
  staff_name: string;
  requested_start: string;
  requested_end: string;
  days_requested: string;
  status: string;
  notes: string | null;
}
interface BirthdayRow {
  external_id: number;
  full_name: string;
  dob: string;
  next_bday: string;
  age_then: number;
}
interface TipsRow {
  site: string;
  tx_count: number;
  gratuity_total: string;
}
interface WagePct { days: number; labour: string | null; sales: string | null; pct: string | null }

function ago(iso: string | null | undefined): string {
  if (!iso) return '—';
  const ms = Date.now() - new Date(iso).getTime();
  const h = ms / 3_600_000;
  if (h < 1) return `${Math.round(h * 60)} min ago`;
  if (h < 24) return `${h.toFixed(1)} h ago`;
  return `${Math.round(h / 24)} d ago`;
}

function tandaPip(hours: number) {
  if (hours < 6)  return { icon: CheckCircle2, cls: 'text-good',  label: 'healthy' };
  if (hours < 24) return { icon: Circle,       cls: 'text-amber-500', label: 'stale' };
  return                  { icon: AlertTriangle, cls: 'text-warn',   label: 'BROKEN' };
}

function isoDateDaysAgo(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return d.toISOString().slice(0, 10);
}
function todayIsoLocal(): string {
  const t = new Date();
  return `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, '0')}-${String(t.getDate()).padStart(2, '0')}`;
}

const TABS = ['all', 'pub', 'cafe'] as const;
type Tab = (typeof TABS)[number];

export default function StaffPage() {
  const [dateFrom, setDateFrom] = useState(isoDateDaysAgo(6));
  const [dateTo,   setDateTo]   = useState(todayIsoLocal());
  const [teamFilter, setTeamFilter] = useState<string>('all');  const router = useRouter();
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

  const [range, setRange] = useState<DateRange>({ preset: 'today', start: new Date().toISOString().slice(0, 10), end: new Date().toISOString().slice(0, 10) });

  const dateParam = useMemo(() => {

    if (range.preset === 'today') return { date: new Date().toISOString().slice(0, 10) };

    if (range.preset === 'yesterday') {

      const y = new Date(); y.setDate(y.getDate() - 1);

      return { date: y.toISOString().slice(0, 10) };

    }

    return { date: new Date().toISOString().slice(0, 10) };

  }, [range]);
  const poller = useSlug<{ source: string; last_poll: string }>('sales_last_poll_per_source', {}, { refetchInterval: 60_000 });
  const pollFor = (source: string) => (poller.data ?? []).find((p: any) => p.source === source)?.last_poll ?? null;

  const status     = useSlug<TandaStatus>('staff_tanda_sync_status', {}, { refetchInterval: 5 * 60_000 });
  const rota       = useSlug<RotaRow>('staff_on_rota_today', dateParam);
  const attribution = useSlug<AttributionRow>('staff_attribution_per_hour', { date_from: dateFrom, date_to: dateTo });
  const holidays   = useSlug<HolidayRow>('staff_upcoming_holidays');
  const birthdays  = useSlug<BirthdayRow>('staff_birthdays_next_30d');
  const tips       = useSlug<TipsRow>('staff_dojo_tips_today');
  const wage       = useSlug<WagePct>('frontend_wage_pct_summary');

  const statusRow = status.data?.[0];
  const tandaHours = statusRow ? parseFloat(statusRow.hours_since_user_sync) : 0;
  const tandaState = tandaPip(tandaHours);
  const TandaIcon = tandaState.icon;

  const filteredAttribution = (attribution.data ?? []).filter(r =>
    teamFilter === 'all' || r.team === teamFilter
  );
  const teams = Array.from(new Set((attribution.data ?? []).map(r => r.team))).sort();

  const rotaByTeam = (rota.data ?? []).reduce<Record<string, RotaRow[]>>((acc, r) => {
    (acc[r.team] ||= []).push(r); return acc;
  }, {});

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

      {/* Tanda sync status */}
      <SandboxWrapper id="staff.tanda-status" label="Tanda sync">
        <Section title="Workforce sync — Tanda">
          {status.isLoading ? <PlaceholderState message="Loading…" /> : statusRow && (
            <div className="tile flex items-center gap-4">
              <TandaIcon size={32} className={tandaState.cls} />
              <div className="flex-1">
                <div className={`text-sm font-semibold ${tandaState.cls} uppercase tracking-wider`}>{tandaState.label}</div>
                <div className="text-xs text-ink-700 mt-0.5">Last user-sync {ago(statusRow.users_last_sync)} · {statusRow.active_user_count} active employees</div>
                <div className="text-xs text-ink-500 mt-0.5">Latest shift in DB: {statusRow.latest_shift_date ? new Date(statusRow.latest_shift_date).toLocaleDateString('en-GB') : '—'} · {statusRow.upcoming_shifts} upcoming</div>
              </div>
            </div>
          )}
        </Section>
      </SandboxWrapper>

      {/* On rota today */}
      <SandboxWrapper id="staff.on-rota" label="On rota today">
        <Section title={`On rota today (${rota.data?.length ?? 0})`} action={<FreshnessBadge source="workforce" />}>
          {rota.isLoading ? <PlaceholderState message="Loading…" /> :
           rota.data && rota.data.length > 0 ? (
            <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
              {Object.entries(rotaByTeam).sort(([a], [b]) => a.localeCompare(b)).map(([team, shifts]) => {
                const teamHours = shifts.reduce((s, x) => s + parseFloat(String(x.hours_worked)), 0);
                const teamCost  = shifts.reduce((s, x) => s + parseFloat(String(x.shift_cost)), 0);
                return (
                  <div key={team} className="tile">
                    <div className="flex items-center justify-between mb-1.5">
                      <div className="text-xs uppercase tracking-wider text-ink-500">{team}</div>
                      <div className="text-sm text-ink-700 font-mono">{teamHours.toFixed(1)}h · {gbp(teamCost)}</div>
                    </div>
                    <ul className="space-y-0.5 text-sm">
                      {shifts.map(s => (
                        <li key={s.user_external_id + '-' + s.start_time} className="flex justify-between text-xs">
                          <span className="text-ink-900">{s.full_name}</span>
                          <span className="text-ink-500 font-mono">
                            {new Date(s.start_time).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}
                            –
                            {new Date(s.end_time).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}
                          </span>
                        </li>
                      ))}
                    </ul>
                  </div>
                );
              })}
            </div>
          ) : <PlaceholderState message="No staff on rota today (or shifts not yet imported)." />}
        </Section>
      </SandboxWrapper>

      {/* Per-staff attribution — date pickable */}
      <SandboxWrapper id="staff.attribution" label="Revenue attribution">
        <Section title="Per-staff revenue attribution">
          <div className="tile">
            <div className="flex flex-wrap items-center gap-3 mb-3 text-xs">
              <label className="flex items-center gap-1">
                <span className="text-ink-500 uppercase tracking-wider">From</span>
                <input type="date" value={dateFrom} onChange={e => setDateFrom(e.target.value)}
                  className="bg-ink-100 border border-ink-200 rounded px-2 py-1 text-ink-900" />
              </label>
              <label className="flex items-center gap-1">
                <span className="text-ink-500 uppercase tracking-wider">To</span>
                <input type="date" value={dateTo} onChange={e => setDateTo(e.target.value)}
                  className="bg-ink-100 border border-ink-200 rounded px-2 py-1 text-ink-900" />
              </label>
              <label className="flex items-center gap-1">
                <span className="text-ink-500 uppercase tracking-wider">Team</span>
                <select value={teamFilter} onChange={e => setTeamFilter(e.target.value)}
                  className="bg-ink-100 border border-ink-200 rounded px-2 py-1 text-ink-900">
                  <option value="all">all</option>
                  {teams.map(t => <option key={t} value={t}>{t}</option>)}
                </select>
              </label>
              <div className="ml-auto text-xs text-ink-500">Attribution = staff-hours-share × team site revenue</div>
            </div>
            {attribution.isLoading ? <PlaceholderState message="Loading…" /> :
             filteredAttribution.length > 0 ? (
              <table className="w-full text-sm">
                <thead className="text-xs text-ink-500 uppercase tracking-wider">
                  <tr>
                    <th className="text-left py-1.5 font-medium">#</th>
                    <th className="text-left font-medium">Name</th>
                    <th className="text-left font-medium">Team</th>
                    <th className="text-right font-medium">Hours</th>
                    <th className="text-right font-medium">Cost</th>
                    <th className="text-right font-medium">Attrib. rev.</th>
                    <th className="text-right font-medium">GP/hr</th>
                  </tr>
                </thead>
                <tbody>
                  {filteredAttribution.map((r, i) => {
                    const gp = r.gp_per_hour != null ? parseFloat(String(r.gp_per_hour)) : null;
                    const gpClass = gp == null ? 'text-ink-500' : gp > 0 ? 'text-good' : 'text-warn';
                    return (
                      <tr key={r.user_external_id} className="border-t border-ink-200">
                        <td className="py-1 text-sm text-ink-500 font-mono">{i + 1}</td>
                        <td className="font-medium text-ink-900">{r.full_name}</td>
                        <td className="text-ink-700 text-xs">{r.team}</td>
                        <td className="text-right font-mono text-ink-700">{parseFloat(String(r.hours)).toFixed(1)}</td>
                        <td className="text-right font-mono text-ink-700">{gbp(r.cost, 0)}</td>
                        <td className="text-right font-mono text-ink-700">{gbp(parseFloat(String(r.attributed_revenue)), 0)}</td>
                        <td className={'text-right font-mono font-semibold ' + gpClass}>{gp != null ? gbp(gp) : '—'}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            ) : <PlaceholderState message="No attribution data in this window." />}
          </div>
        </Section>
      </SandboxWrapper>

      {/* Tips */}
      <SandboxWrapper id="staff.tips" label="Tips">
        <Section title="Today's gratuity (Dojo card tips)">
          {tips.isLoading ? <PlaceholderState message="Loading…" /> :
           tips.data && tips.data.length > 0 ? (
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
              {tips.data.map(t => (
                <KPICard key={t.site} label={`${t.site} · ${t.tx_count} txns`}
                  value={gbp(parseFloat(String(t.gratuity_total)))} />
              ))}
            </div>
          ) : <PlaceholderState message="No gratuity recorded for today."
              hint="Once today's Dojo CSV lands in /home_ai/data/dojo-inbox/ this row populates. Per-staff Tronc allocation is a U137 follow-up." />}
        </Section>
      </SandboxWrapper>

      {/* Holidays */}
      <SandboxWrapper id="staff.holidays" label="Holidays">
        <Section title={`Upcoming holidays — next 28 days (${holidays.data?.length ?? 0})`}>
          {holidays.isLoading ? <PlaceholderState message="Loading…" /> :
           holidays.data && holidays.data.length > 0 ? (
            <div className="tile">
              <table className="w-full text-sm">
                <thead className="text-xs text-ink-500 uppercase tracking-wider">
                  <tr>
                    <th className="text-left py-1.5 font-medium">Staff</th>
                    <th className="text-left font-medium">From</th>
                    <th className="text-left font-medium">To</th>
                    <th className="text-right font-medium">Days</th>
                    <th className="text-left font-medium">Status</th>
                  </tr>
                </thead>
                <tbody>
                  {holidays.data.map(h => (
                    <tr key={h.id} className="border-t border-ink-200">
                      <td className="py-1.5 font-medium text-ink-900">{h.staff_name}</td>
                      <td className="font-mono text-ink-700">{h.requested_start}</td>
                      <td className="font-mono text-ink-700">{h.requested_end}</td>
                      <td className="text-right font-mono text-ink-700">{h.days_requested}</td>
                      <td className={
                        'text-xs ' +
                        (h.status === 'approved' ? 'text-good' : h.status === 'pending' ? 'text-amber-500' : 'text-ink-500')
                      }>{h.status}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : <PlaceholderState message="No upcoming holidays in the next 28 days." />}
        </Section>
      </SandboxWrapper>

      {/* Birthdays */}
      <SandboxWrapper id="staff.birthdays" label="Birthdays">
        <Section title={`Birthdays — next 30 days (${birthdays.data?.length ?? 0})`}>
          {birthdays.isLoading ? <PlaceholderState message="Loading…" /> :
           birthdays.data && birthdays.data.length > 0 ? (
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
              {birthdays.data.map(b => (
                <div key={b.external_id} className="tile">
                  <div className="font-medium text-ink-900">{b.full_name}</div>
                  <div className="text-xs text-ink-500 mt-0.5">{b.next_bday} · turning {b.age_then}</div>
                </div>
              ))}
            </div>
          ) : <PlaceholderState message="No birthdays in the next 30 days." />}
        </Section>
      </SandboxWrapper>

      {/* Wage % */}
      <SandboxWrapper id="staff.wage-tracker" label="Wage %">
        <Section title="Wage % tracker">
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
            {[1, 7, 30].map((d) => {
              const r = wage.data?.find(x => Number(x.days) === d);
              const pct = r?.pct != null ? parseFloat(r.pct) : null;
              return (
                <KPICard key={d} label={`${d}d`}
                  value={pct != null ? `${pct.toFixed(1)}%` : '—'}
                  loading={wage.isLoading} />
              );
            })}
          </div>
        </Section>
      </SandboxWrapper>
    </div>
  );
}
