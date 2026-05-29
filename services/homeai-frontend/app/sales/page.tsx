'use client';

import { useMemo, useState, useEffect } from 'react';
import { useRouter, useSearchParams, usePathname } from 'next/navigation';
import { DateRangePicker, DateRange } from '@/components/ui/DateRangePicker';
import { KPICard } from '@/components/ui/KPICard';
import { Section } from '@/components/ui/Section';
import { PollClock } from '@/components/ui/PollClock';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid, Cell,
  LineChart, Line, ComposedChart, Legend, ReferenceLine,
} from 'recharts';

const TABS = ['all', 'pub', 'cafe'] as const;
type Tab = (typeof TABS)[number];

interface CategorizedRow { site: string; category: string; total: string }
interface DailyTotalsRow {
  site: string;
  report_date: string;
  daily_total: string;
  food: string; bar: string; accom: string; icecream: string; cafe_other: string;
  rolling_7d_avg: string;
}
interface IncomeVsLabourRow { day: string; pub_income: string; cafe_income: string; total_income: string; labour_cost: string }
interface FilterableRow {
  day: string;
  pub_food: string; pub_bar: string; pub_accom: string;
  cafe_icecream: string; cafe_other: string;
  labour_cost: string; cogs_overall: string;
  sales_excl_accom: string; labour_pct: string | null;
}
interface PollRow { source: string; last_poll: string | null }

const CAT_COLOR: Record<string, string> = {
  Food: '#f59e0b', Bar: '#fb923c', Accommodation: '#a78bfa',
  'Ice Cream': '#f59e0b', Other: '#737373',
};

function num(s: string | number | null | undefined): number {
  if (s == null) return 0;
  const n = typeof s === 'number' ? s : parseFloat(s);
  return Number.isFinite(n) ? n : 0;
}

export default function SalesPage() {
  const [range, setRange] = useState<DateRange>({ preset: 'today', start: new Date().toISOString().slice(0, 10), end: new Date().toISOString().slice(0, 10) });
  // Hermes D4: persist sales tab in URL so navigating away and back preserves
  // the user's view (was: React-only state → reset on every nav).
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
  // Adopt URL on first mount if tab param changed externally (e.g. deep link).
  useEffect(() => {
    const urlTab = sp.get('tab');
    if (urlTab && TABS.includes(urlTab as Tab) && urlTab !== tab) {
      setTabState(urlTab as Tab);
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sp]);
  const [tableFilter, setTableFilter] = useState<'' | 'high_labour' | 'low_sales' | 'has_data'>('');

  const rangeArgs = { start: range.start, end: range.end };

  const cat       = useSlug<CategorizedRow>('sales_categorized_split_range', rangeArgs, { refetchInterval: 60_000 });
  const daily30   = useSlug<DailyTotalsRow>('sales_daily_totals_30d', {}, { refetchInterval: 5 * 60_000 });
  const incLab    = useSlug<IncomeVsLabourRow>('sales_30d_income_vs_labour', {}, { refetchInterval: 5 * 60_000 });
  const table     = useSlug<FilterableRow>('sales_filterable_daily_table', {}, { refetchInterval: 5 * 60_000 });
  const polls     = useSlug<PollRow>('sales_last_poll_per_source', {}, { refetchInterval: 60_000 });

  const pollFor = (k: string) => polls.data?.find(p => p.source === k)?.last_poll ?? null;

  // KPI totals over selected range
  const catRows = cat.data ?? [];
  const pubTotal  = catRows.filter(r => r.site === 'malthouse' && r.category !== 'Accommodation').reduce((a, r) => a + num(r.total), 0);
  const pubAccom  = catRows.filter(r => r.site === 'malthouse' && r.category === 'Accommodation').reduce((a, r) => a + num(r.total), 0);
  const cafeTotal = catRows.filter(r => r.site === 'sandwich').reduce((a, r) => a + num(r.total), 0);
  const grandTotal = pubTotal + cafeTotal;

  // Categorized bar chart data, filtered by tab
  const catChart = useMemo(() => {
    const visible = catRows.filter(r => tab === 'all' || (tab === 'pub' ? r.site === 'malthouse' : r.site === 'sandwich'));
    return visible.map(r => ({
      label: `${r.site === 'malthouse' ? 'Pub' : 'Café'} · ${r.category}`,
      total: num(r.total),
      category: r.category,
    }));
  }, [catRows, tab]);

  // Compute 7-day rolling average across selected sites — as a target line on the bar chart
  const target7d = useMemo(() => {
    const visible = (daily30.data ?? []).filter(r => tab === 'all' || (tab === 'pub' ? r.site === 'malthouse' : r.site === 'sandwich'));
    if (visible.length === 0) return null;
    // Use the last row's rolling_7d_avg (already computed per-site by SQL)
    const bySite: Record<string, number> = {};
    visible.forEach(r => { bySite[r.site] = num(r.rolling_7d_avg); });
    return Object.values(bySite).reduce((a, b) => a + b, 0);
  }, [daily30.data, tab]);

  // Filterable table rows
  const tableRows = useMemo(() => {
    let rows = table.data ?? [];
    if (tableFilter === 'has_data') rows = rows.filter(r => num(r.sales_excl_accom) > 0);
    if (tableFilter === 'low_sales') rows = rows.filter(r => num(r.sales_excl_accom) < 1000 && num(r.sales_excl_accom) > 0);
    if (tableFilter === 'high_labour') rows = rows.filter(r => r.labour_pct != null && num(r.labour_pct) > 30);
    return rows;
  }, [table.data, tableFilter]);

  // Aggregate table footer
  const footer = useMemo(() => {
    const rows = tableRows;
    const n = rows.length;
    const sum = (k: keyof FilterableRow) => rows.reduce((a, r) => a + num(r[k] as string), 0);
    const totalSales = sum('sales_excl_accom');
    const totalLabour = sum('labour_cost');
    const totalCogs = sum('cogs_overall');
    return {
      n,
      sales: totalSales, labour: totalLabour, cogs: totalCogs,
      labourPct: totalSales > 0 ? (totalLabour / totalSales) * 100 : null,
      cogsPct:   totalSales > 0 ? (totalCogs   / totalSales) * 100 : null,
      avgSales:  n > 0 ? totalSales / n : 0,
      avgLabour: n > 0 ? totalLabour / n : 0,
    };
  }, [tableRows]);

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

      <SandboxWrapper id="sales.kpi" label="Sales KPI row">
        <Section title="KPIs (selected range, excluding accommodation from pub)">
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
            <KPICard label="Total (pub + cafe, excl accom)" size="xl"
              value={cat.isLoading ? null : gbp(tab === 'all' ? (pubTotal + cafeTotal) : tab === 'pub' ? pubTotal : cafeTotal)} />
            <KPICard label="Pub (food + bar)" value={gbp(pubTotal)} />
            <KPICard label="Café (all)" value={gbp(cafeTotal)} />
            <KPICard label="Accommodation (pub till)" value={gbp(pubAccom)} />
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="sales.dept-bar" label="Department bar">
        <Section title="Category breakdown (selected range)">
          {cat.isLoading ? <div className="text-xs text-ink-500">Loading…</div> : (
            <figure
              className="tile h-[340px]"
              aria-labelledby="sales-cat-caption"
              aria-describedby="sales-filterable-table"
              role="figure"
            >
              <figcaption id="sales-cat-caption" className="sr-only">
                Bar chart of sales totals by category for the selected date range.
                The same data is available in the filterable daily table below for screen-reader users.
              </figcaption>
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={catChart} layout="vertical" margin={{ top: 8, right: 24, left: 80, bottom: 8 }}>
                  <CartesianGrid stroke="#2a2a2a" horizontal={false} />
                  <XAxis type="number" stroke="#737373" fontSize={11} tickFormatter={(v) => `£${v}`} />
                  <YAxis type="category" dataKey="label" stroke="#a3a3a3" fontSize={11} width={150} />
                  <Tooltip contentStyle={{ background: '#171717', border: '1px solid #2a2a2a' }} formatter={(v: number) => gbp(v)} />
                  <Bar dataKey="total">
                    {catChart.map((d, i) => <Cell key={i} fill={CAT_COLOR[d.category] ?? '#f59e0b'} />)}
                  </Bar>
                  {target7d != null && (
                    <ReferenceLine x={target7d} stroke="#22d3ee" strokeDasharray="4 4" label={{ value: `7d avg target £${Math.round(target7d).toLocaleString()}`, fill: '#22d3ee', fontSize: 10, position: 'insideTopRight' }} />
                  )}
                </BarChart>
              </ResponsiveContainer>
            </figure>
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="sales.income-vs-labour" label="30d income vs labour">
        <Section title="Income vs labour cost — last 30 days">
          {incLab.isLoading ? <div className="text-xs text-ink-500">Loading…</div> : (
            <figure
              className="tile h-[300px]"
              aria-labelledby="sales-incomelabour-caption"
              aria-describedby="sales-filterable-table"
              role="figure"
            >
              <figcaption id="sales-incomelabour-caption" className="sr-only">
                Composed chart of daily total income versus labour cost over the last 30 days,
                with a 7-day rolling average target line. Data also available in the filterable daily table below.
              </figcaption>
              <ResponsiveContainer width="100%" height="100%">
                <ComposedChart data={incLab.data ?? []} margin={{ top: 8, right: 16, left: 8, bottom: 8 }}>
                  <CartesianGrid stroke="#2a2a2a" vertical={false} />
                  <XAxis dataKey="day" stroke="#737373" fontSize={10} tickFormatter={(d) => d.slice(5)} />
                  <YAxis stroke="#737373" fontSize={11} tickFormatter={(v) => `£${v}`} />
                  <Tooltip contentStyle={{ background: '#171717', border: '1px solid #2a2a2a' }} formatter={(v: number) => gbp(v)} />
                  <Legend wrapperStyle={{ fontSize: 11 }} />
                  <Bar dataKey="pub_income"  stackId="inc" fill="#f59e0b" name="Pub income" />
                  <Bar dataKey="cafe_income" stackId="inc" fill="#fbbf24" name="Café income" />
                  <Line type="monotone" dataKey="labour_cost" stroke="#22d3ee" strokeWidth={2} dot={false} name="Labour cost" />
                </ComposedChart>
              </ResponsiveContainer>
            </figure>
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="sales.daily-table" label="Daily filterable table">
        <Section title="Daily sales / wage / COGS — last 30 days">
          <div className="mb-2 flex items-center gap-2 text-xs">
            <span className="text-ink-500">filter:</span>
            <select value={tableFilter} onChange={(e) => setTableFilter(e.target.value as typeof tableFilter)}
              className="bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1">
              <option value="">All days (30d)</option>
              <option value="has_data">Days with data</option>
              <option value="low_sales">Low sales (&lt; £1k)</option>
              <option value="high_labour">High labour % (&gt; 30%)</option>
            </select>
            <PollClock lastPoll={pollFor('workforce_shifts')} label="workforce" />
            <PollClock lastPoll={pollFor('xero_bills')} label="xero" />
          </div>
          <div className="tile overflow-x-auto" id="sales-filterable-table">
            <table className="w-full text-xs font-mono"
              aria-label="Daily sales, wage and COGS table — accessible alternative to the charts above">
              <thead className="text-ink-500 uppercase tracking-wider text-xs">
                <tr>
                  <th className="px-2 py-1 text-left">Day</th>
                  <th className="px-2 py-1 text-right">Pub food</th>
                  <th className="px-2 py-1 text-right">Pub bar</th>
                  <th className="px-2 py-1 text-right">Pub accom</th>
                  <th className="px-2 py-1 text-right">Café ice cream</th>
                  <th className="px-2 py-1 text-right">Café other</th>
                  <th className="px-2 py-1 text-right">Sales (excl accom)</th>
                  <th className="px-2 py-1 text-right">Labour £</th>
                  <th className="px-2 py-1 text-right">Labour %</th>
                  <th className="px-2 py-1 text-right">COGS £</th>
                </tr>
              </thead>
              <tbody>
                {tableRows.map((r) => (
                  <tr key={r.day} className="border-t border-ink-200">
                    <td className="px-2 py-1">{r.day}</td>
                    <td className="px-2 py-1 text-right">{gbp(num(r.pub_food))}</td>
                    <td className="px-2 py-1 text-right">{gbp(num(r.pub_bar))}</td>
                    <td className="px-2 py-1 text-right">{gbp(num(r.pub_accom))}</td>
                    <td className="px-2 py-1 text-right">{gbp(num(r.cafe_icecream))}</td>
                    <td className="px-2 py-1 text-right">{gbp(num(r.cafe_other))}</td>
                    <td className="px-2 py-1 text-right font-semibold">{gbp(num(r.sales_excl_accom))}</td>
                    <td className="px-2 py-1 text-right">{gbp(num(r.labour_cost))}</td>
                    <td className={'px-2 py-1 text-right ' + (r.labour_pct != null && num(r.labour_pct) > 35 ? 'text-red-400' : r.labour_pct != null && num(r.labour_pct) > 25 ? 'text-amber-300' : '')}>{r.labour_pct ?? '—'}{r.labour_pct != null ? '%' : ''}</td>
                    <td className="px-2 py-1 text-right">{gbp(num(r.cogs_overall))}</td>
                  </tr>
                ))}
                {tableRows.length === 0 && (
                  <tr><td colSpan={10} className="px-2 py-4 text-center text-ink-500">No rows match the filter</td></tr>
                )}
              </tbody>
              <tfoot className="border-t-2 border-ink-300 text-ink-700">
                <tr>
                  <td className="px-2 py-1 font-semibold">Total ({footer.n}d)</td>
                  <td className="px-2 py-1 text-right" colSpan={5}></td>
                  <td className="px-2 py-1 text-right font-semibold">{gbp(footer.sales)}</td>
                  <td className="px-2 py-1 text-right font-semibold">{gbp(footer.labour)}</td>
                  <td className="px-2 py-1 text-right font-semibold">{footer.labourPct?.toFixed(1) ?? '—'}%</td>
                  <td className="px-2 py-1 text-right font-semibold">{gbp(footer.cogs)}</td>
                </tr>
                <tr>
                  <td className="px-2 py-1">Average / day</td>
                  <td className="px-2 py-1 text-right" colSpan={5}></td>
                  <td className="px-2 py-1 text-right">{gbp(footer.avgSales)}</td>
                  <td className="px-2 py-1 text-right">{gbp(footer.avgLabour)}</td>
                  <td className="px-2 py-1 text-right">{footer.labourPct?.toFixed(1) ?? '—'}%</td>
                  <td className="px-2 py-1 text-right">COGS {footer.cogsPct?.toFixed(1) ?? '—'}% of sales</td>
                </tr>
              </tfoot>
            </table>
          </div>
          <p className="mt-2 text-sm text-ink-500">
            COGS is overall (xero contacts not yet site-categorised). Pub COGS vs Café COGS will split once vendor-to-site mapping is wired.
            Labour % is labour ÷ sales (excl accom). Accommodation revenue lives in caterbook and is intentionally excluded from sales totals to avoid double-counting (see /sales accom column for the till-recorded number).
          </p>
        </Section>
      </SandboxWrapper>
    </div>
  );
}
