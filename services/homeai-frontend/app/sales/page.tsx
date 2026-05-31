'use client';

import { useMemo, useState, useEffect } from 'react';
import { useRouter, useSearchParams, usePathname } from 'next/navigation';
import { DateRangePicker, DateRange } from '@/components/ui/DateRangePicker';
import { KPICard } from '@/components/ui/KPICard';
import { Section } from '@/components/ui/Section';
import { PollClock } from '@/components/ui/PollClock';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { gbp } from '@/lib/format';
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid, Cell,
  LineChart, Line, ComposedChart, Legend, ReferenceLine, LabelList,
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
interface IncomeVsLabourRow { day: string; pub_income: string; cafe_income: string; total_income: string; labour_cost: string; labour_pct: string }
interface FilterableRow {
  day: string;
  pub_food: string; pub_bar: string; pub_accom: string; pub_total: string;
  pub_labour: string; pub_labour_pct: string | null;
  cafe_icecream: string; cafe_other: string; cafe_total: string;
  cafe_labour: string; cafe_labour_pct: string | null;
  combined_total: string; combined_labour: string; combined_labour_pct: string | null;
}
interface CogsRow { day: string; cogs_day: string; cogs_7d_avg: string }
interface FrontendKpiRow { metric: string; value: string }
interface PollRow { source: string; last_poll: string | null }

const CAT_COLOR: Record<string, string> = {
  Food: '#f59e0b', Bar: '#fb923c', Accommodation: '#a78bfa',
  'Ice Cream': '#ec4899', Other: '#ec4899',
};

function num(s: string | number | null | undefined): number {
  if (s == null) return 0;
  const n = typeof s === 'number' ? s : parseFloat(s);
  return Number.isFinite(n) ? n : 0;
}

function labourPctColor(pct: number | null): string {
  if (pct == null) return '';
  if (pct > 35) return 'text-red-400';
  if (pct > 25) return 'text-amber-300';
  return 'text-emerald-400';
}

export default function SalesPage() {
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
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sp]);
  const [tableFilter, setTableFilter] = useState<'' | 'high_labour' | 'low_sales' | 'has_data'>('');
  const [currentPage, setCurrentPage] = useState(1);
  const PAGE_SIZE = 10;

  // Reset pagination on filter change
  useEffect(() => {
    setCurrentPage(1);
  }, [tableFilter, range]);

  const rangeArgs = { start: range.start, end: range.end };

  const cat       = useSlug<CategorizedRow>('sales_categorized_split_range', rangeArgs, { refetchInterval: 60_000 });
  const daily30   = useSlug<DailyTotalsRow>('sales_daily_totals_30d', {}, { refetchInterval: 5 * 60_000 });
  const incLab    = useSlug<IncomeVsLabourRow>('sales_30d_income_vs_labour', {}, { refetchInterval: 5 * 60_000 });
  // Compute labour_pct client-side (slug doesn't return it)
  const incLabWithPct = (incLab.data ?? []).map(r => ({
    ...r,
    labour_pct: num(r.labour_cost) > 0 && num(r.total_income) > 0
      ? (num(r.labour_cost) / num(r.total_income)) * 100
      : null,
  }));
  const table     = useSlug<FilterableRow>('sales_filterable_daily_table', {}, { refetchInterval: 5 * 60_000 });
  const polls     = useSlug<PollRow>('sales_last_poll_per_source', {}, { refetchInterval: 60_000 });
  const cogs7d    = useSlug<CogsRow>('daily_cogs_7d_avg', {}, { refetchInterval: 5 * 60_000 });
  // WIP: purchase-based COGS 7-day rolling avg, keyed by day for the daily table.
  const cogsMap = useMemo(() => {
    const m: Record<string, number> = {};
    (cogs7d.data ?? []).forEach(r => { m[String(r.day).slice(0, 10)] = num(r.cogs_7d_avg); });
    return m;
  }, [cogs7d.data]);
  const kpiSlug   = useSlug<FrontendKpiRow>('sales_frontend_kpis', rangeArgs, { refetchInterval: 60_000 });

  const pollFor = (k: string) => polls.data?.find(p => p.source === k)?.last_poll ?? null;

  // KPI totals — prefer pre-computed KPIs, fall back to category aggregation
  const kpiData = kpiSlug.data ?? [];
  const kpiMap: Record<string, number> = {};
  kpiData.forEach(r => { kpiMap[r.metric] = num(r.value); });

  const catRows = cat.data ?? [];
  const pubTotal  = kpiMap['pub_food_bar'] || catRows.filter(r => r.site === 'malthouse' && r.category !== 'Accommodation').reduce((a, r) => a + num(r.total), 0);
  const pubAccom  = kpiMap['accom'] || catRows.filter(r => r.site === 'malthouse' && r.category === 'Accommodation').reduce((a, r) => a + num(r.total), 0);
  const cafeTotal = kpiMap['cafe_all'] || catRows.filter(r => r.site === 'sandwich').reduce((a, r) => a + num(r.total), 0);
  const grandTotal = kpiMap['total_excl_accom'] || (pubTotal + cafeTotal);

  // Categorized bar chart data, filtered by tab
  const catChart = useMemo(() => {
    const visible = catRows.filter(r => tab === 'all' || (tab === 'pub' ? r.site === 'malthouse' : r.site === 'sandwich'));
    return visible.map(r => ({
      label: `${r.site === 'malthouse' ? 'Pub' : 'Café'} · ${r.category}`,
      total: num(r.total),
      category: r.category,
    }));
  }, [catRows, tab]);

  // Compute percentage breakdown for bar chart
  const catPct = useMemo(() => {
    const total = catChart.reduce((a, c) => a + c.total, 0);
    return catChart.map(d => ({ ...d, pct: total > 0 ? (d.total / total) * 100 : 0 }));
  }, [catChart]);

  // Compute 7-day rolling average across selected sites
  const target7d = useMemo(() => {
    const visible = (daily30.data ?? []).filter(r => tab === 'all' || (tab === 'pub' ? r.site === 'malthouse' : r.site === 'sandwich'));
    if (visible.length === 0) return null;
    const bySite: Record<string, number> = {};
    visible.forEach(r => { bySite[r.site] = num(r.rolling_7d_avg); });
    return Object.values(bySite).reduce((a, b) => a + b, 0);
  }, [daily30.data, tab]);

  // Filterable table rows
  const tableRows = useMemo(() => {
    let rows = table.data ?? [];
    if (tableFilter === 'has_data') rows = rows.filter(r => num(r.combined_total) > 0);
    if (tableFilter === 'low_sales') rows = rows.filter(r => num(r.combined_total) < 1000 && num(r.combined_total) > 0);
    if (tableFilter === 'high_labour') {
      rows = rows.filter(r => {
        const p = num(r.combined_labour_pct);
        const pubP = num(r.pub_labour_pct);
        const cafeP = num(r.cafe_labour_pct);
        return p > 30 || pubP > 30 || cafeP > 30;
      });
    }
    return rows;
  }, [table.data, tableFilter]);

  // Pagination
  const totalPages = Math.max(1, Math.ceil(tableRows.length / PAGE_SIZE));
  // Clamp current page if rows change (e.g. filter reduces count)
  const safePage = Math.min(currentPage, totalPages);
  const paginatedRows = tableRows.slice((safePage - 1) * PAGE_SIZE, safePage * PAGE_SIZE);
  const startItem = tableRows.length === 0 ? 0 : (safePage - 1) * PAGE_SIZE + 1;
  const endItem = Math.min(safePage * PAGE_SIZE, tableRows.length);

  const pagination = (() => {
    const pages: (number | 'ellipsis')[] = [];
    const maxVisible = 5;
    let startP = Math.max(1, safePage - Math.floor(maxVisible / 2));
    let endP = Math.min(totalPages, startP + maxVisible - 1);
    if (endP - startP + 1 < maxVisible) startP = Math.max(1, endP - maxVisible + 1);
    if (startP > 1) { pages.push(1); if (startP > 2) pages.push('ellipsis'); }
    for (let i = startP; i <= endP; i++) pages.push(i);
    if (endP < totalPages) { if (endP < totalPages - 1) pages.push('ellipsis'); pages.push(totalPages); }
    return pages;
  })();

  // Aggregate table footer (over all filtered rows, not just current page)
  const footer = useMemo(() => {
    const rows = tableRows;
    const n = rows.length;
    const sum = (k: keyof FilterableRow) => rows.reduce((a, r) => a + num(r[k] as string), 0);
    const pubFood = sum('pub_food'); const pubBar = sum('pub_bar'); const pubAccom = sum('pub_accom');
    const pubTot = sum('pub_total'); const pubLab = sum('pub_labour');
    const cafeIce = sum('cafe_icecream'); const cafeOth = sum('cafe_other'); const cafeTot = sum('cafe_total');
    const cafeLab = sum('cafe_labour');
    const combTot = sum('combined_total'); const combLab = sum('combined_labour');
    return {
      n,
      pubFood, pubBar, pubAccom, pubTot, pubLab, pubLabPct: pubTot > 0 ? (pubLab / pubTot) * 100 : null,
      cafeIce, cafeOth, cafeTot, cafeLab, cafeLabPct: cafeTot > 0 ? (cafeLab / cafeTot) * 100 : null,
      combTot, combLab, combLabPct: combTot > 0 ? (combLab / combTot) * 100 : null,
      avgCombTot: n > 0 ? combTot / n : 0,
      avgCombLab: n > 0 ? combLab / n : 0,
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
              value={cat.isLoading && kpiSlug.isLoading ? null : gbp(tab === 'all' ? grandTotal : tab === 'pub' ? pubTotal : cafeTotal)} />
            <KPICard label="Pub (food + bar)" value={gbp(pubTotal)} />
            <KPICard label="Café (all)" value={gbp(cafeTotal)} />
            <KPICard label="Accommodation (pub till)" value={gbp(pubAccom)} />
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="sales.dept-bar" label="Department bar">
        <Section title="Category breakdown (selected range)">
          {cat.isLoading ? <div className="text-xs text-ink-500">Loading…</div> :
           catChart.length === 0 ? (
            <PlaceholderState
              message="No sales recorded for this period yet"
              hint="The category breakdown appears once tills ring through for the selected range and site." />
          ) : (
            <div>
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
                  <BarChart data={catChart} layout="vertical" margin={{ top: 8, right: 80, left: 80, bottom: 8 }}>
                    <CartesianGrid stroke="#2a2a2a" horizontal={false} />
                    <XAxis type="number" stroke="#737373" fontSize={11} tickFormatter={(v) => `£${v}`} />
                    <YAxis type="category" dataKey="label" stroke="#a3a3a3" fontSize={11} width={150} />
                    <Tooltip contentStyle={{ background: '#171717', border: '1px solid #2a2a2a' }} formatter={(v: number) => gbp(v)} />
                    <Bar dataKey="total">
                      {catChart.map((d, i) => <Cell key={i} fill={CAT_COLOR[d.category] ?? '#f59e0b'} />)}
                      <LabelList dataKey="total" position="right" formatter={(v: number) => gbp(v)} style={{ fill: '#a3a3a3', fontSize: 10 }} />
                    </Bar>
                    {target7d != null && (
                      <ReferenceLine x={target7d} stroke="#22d3ee" strokeDasharray="4 4" label={{ value: `7d avg target £${Math.round(target7d).toLocaleString()}`, fill: '#22d3ee', fontSize: 10, position: 'insideTopRight' }} />
                    )}
                  </BarChart>
                </ResponsiveContainer>
              </figure>
              {/* Percentage breakdown row */}
              {catPct.length > 0 && (
                <div className="flex flex-wrap gap-x-6 gap-y-1 mt-2 px-4 text-xs text-ink-400">
                  {catPct.map(d => (
                    <span key={d.label}>{d.label}: <span className="text-ink-300">{d.pct.toFixed(1)}%</span></span>
                  ))}
                </div>
              )}
            </div>
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="sales.income-vs-labour" label="30d income vs labour">
        <Section title="Income vs labour cost — last 30 days">
          {incLab.isLoading ? <div className="text-xs text-ink-500">Loading…</div> :
           (incLab.data ?? []).length === 0 ? (
            <PlaceholderState
              message="No income or labour data for the last 30 days yet"
              hint="This chart fills in as daily till totals and Tanda labour costs land for the period." />
          ) : (
            <figure
              className="tile h-[300px]"
              aria-labelledby="sales-incomelabour-caption"
              aria-describedby="sales-filterable-table"
              role="figure"
            >
              <figcaption id="sales-incomelabour-caption" className="sr-only">
                Composed chart of daily total income versus labour cost over the last 30 days,
                with a labour percentage line on the right axis and a 30% reference line.
                Data also available in the filterable daily table below.
              </figcaption>
              <ResponsiveContainer width="100%" height="100%">
                <ComposedChart data={incLabWithPct} margin={{ top: 8, right: 16, left: 8, bottom: 8 }}>
                  <CartesianGrid stroke="#2a2a2a" vertical={false} />
                  <XAxis dataKey="day" stroke="#737373" fontSize={10} tickFormatter={(d) => d.slice(5)} />
                  <YAxis yAxisId="left" stroke="#737373" fontSize={11} tickFormatter={(v) => `£${v}`} />
                  <YAxis yAxisId="right" orientation="right" stroke="#ef4444" fontSize={10} domain={[0, 'auto']} tickFormatter={(v) => `${v}%`} />
                  <Tooltip contentStyle={{ background: '#171717', border: '1px solid #2a2a2a' }} formatter={(v: number, name: string) => name === 'labour_pct' ? `${v.toFixed(1)}%` : gbp(v)} />
                  <Legend wrapperStyle={{ fontSize: 11 }} />
                  <Bar yAxisId="left" dataKey="pub_income"  stackId="inc" fill="#f59e0b" name="Pub income" />
                  <Bar yAxisId="left" dataKey="cafe_income" stackId="inc" fill="#ec4899" name="Café income" />
                  <Line yAxisId="left" type="monotone" dataKey="labour_cost" stroke="#22d3ee" strokeWidth={2} dot={false} name="Labour cost" />
                  <Line yAxisId="right" type="monotone" dataKey="labour_pct" stroke="#ef4444" strokeWidth={2} strokeDasharray="6 3" dot={false} name="Labour %" />
                  <ReferenceLine yAxisId="right" y={30} stroke="#22c55e" strokeWidth={1.5} strokeDasharray="4 4" label={{ value: '30% target', fill: '#22c55e', fontSize: 10, position: 'insideTopRight' }} />
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
              aria-label="Daily sales, wage and labour percentage table — Pub/Café split with combined totals">
              <thead className="text-ink-500 uppercase tracking-wider">
                {/* Row 1: Group headers */}
                <tr className="border-b border-ink-200">
                  <th className="px-2 py-1 text-left" rowSpan={2}>Day</th>
                  <th className="px-2 py-1 text-center border-x border-ink-200" colSpan={4}>Pub</th>
                  <th className="px-2 py-1 text-center" rowSpan={2}>Pub<br/>Labour %</th>
                  <th className="px-2 py-1 text-center border-x border-ink-200" colSpan={3} style={{ color: '#ec4899' }}>Café</th>
                  <th className="px-2 py-1 text-center" rowSpan={2} style={{ color: '#ec4899' }}>Café<br/>Labour %</th>
                  <th className="px-2 py-1 text-center border-l border-ink-200" colSpan={5}>Combined</th>
                </tr>
                {/* Row 2: Individual column headers */}
                <tr>
                  <th className="px-2 py-1 text-right">Food</th>
                  <th className="px-2 py-1 text-right">Bar</th>
                  <th className="px-2 py-1 text-right">Accom</th>
                  <th className="px-2 py-1 text-right border-r border-ink-200">Total</th>
                  <th className="px-2 py-1 text-right" style={{ color: '#ec4899' }}>Ice Cream</th>
                  <th className="px-2 py-1 text-right" style={{ color: '#ec4899' }}>Other</th>
                  <th className="px-2 py-1 text-right border-r border-ink-200" style={{ color: '#ec4899' }}>Total</th>
                  <th className="px-2 py-1 text-right border-l border-ink-200">Total</th>
                  <th className="px-2 py-1 text-right">Labour</th>
                  <th className="px-2 py-1 text-right">Labour %</th>
                  <th className="px-2 py-1 text-right italic font-normal text-ink-400" title="WIP — purchase-based COGS, 7-day rolling avg, partial capture">COGS 7d <span className="text-ink-500">(WIP)</span></th>
                  <th className="px-2 py-1 text-right italic font-normal text-ink-400" title="WIP — 7d-avg COGS as % of the day's combined total">COGS %</th>
                </tr>
              </thead>
              <tbody>
                {paginatedRows.map((r) => (
                  <tr key={r.day} className="border-t border-ink-200 hover:bg-ink-100/50">
                    <td className="px-2 py-1">{r.day}</td>
                    <td className="px-2 py-1 text-right">{gbp(num(r.pub_food))}</td>
                    <td className="px-2 py-1 text-right">{gbp(num(r.pub_bar))}</td>
                    <td className="px-2 py-1 text-right">{gbp(num(r.pub_accom))}</td>
                    <td className="px-2 py-1 text-right font-semibold">{gbp(num(r.pub_total))}</td>
                    <td className={'px-2 py-1 text-right font-semibold ' + labourPctColor(r.pub_labour_pct != null ? num(r.pub_labour_pct) : null)}>
                      {r.pub_labour_pct != null ? `${num(r.pub_labour_pct).toFixed(1)}%` : '—'}
                    </td>
                    <td className="px-2 py-1 text-right" style={{ color: '#ec4899' }}>{gbp(num(r.cafe_icecream))}</td>
                    <td className="px-2 py-1 text-right" style={{ color: '#ec4899' }}>{gbp(num(r.cafe_other))}</td>
                    <td className="px-2 py-1 text-right font-semibold" style={{ color: '#ec4899' }}>{gbp(num(r.cafe_total))}</td>
                    <td className={'px-2 py-1 text-right font-semibold ' + labourPctColor(r.cafe_labour_pct != null ? num(r.cafe_labour_pct) : null)} style={{ color: r.cafe_labour_pct != null ? undefined : '#ec4899' }}>
                      {r.cafe_labour_pct != null ? `${num(r.cafe_labour_pct).toFixed(1)}%` : '—'}
                    </td>
                    <td className="px-2 py-1 text-right font-semibold">{gbp(num(r.combined_total))}</td>
                    <td className="px-2 py-1 text-right">{gbp(num(r.combined_labour))}</td>
                    <td className={'px-2 py-1 text-right font-semibold ' + labourPctColor(r.combined_labour_pct != null ? num(r.combined_labour_pct) : null)}>
                      {r.combined_labour_pct != null ? `${num(r.combined_labour_pct).toFixed(1)}%` : '—'}
                    </td>
                    {(() => {
                      const c = cogsMap[String(r.day).slice(0, 10)];
                      const tot = num(r.combined_total);
                      return (<>
                        <td className="px-2 py-1 text-right italic text-ink-400">{c != null ? gbp(c) : '—'}</td>
                        <td className="px-2 py-1 text-right italic text-ink-400">{c != null && tot > 0 ? `${(c / tot * 100).toFixed(1)}%` : '—'}</td>
                      </>);
                    })()}
                  </tr>
                ))}
                {tableRows.length === 0 && (
                  <tr><td colSpan={15} className="px-2 py-8 text-center text-ink-500">No rows match the filter</td></tr>
                )}
              </tbody>
              <tfoot className="border-t-2 border-ink-300 text-ink-700">
                <tr>
                  <td className="px-2 py-1 font-semibold">Total ({footer.n}d)</td>
                  <td className="px-2 py-1 text-right">{gbp(footer.pubFood)}</td>
                  <td className="px-2 py-1 text-right">{gbp(footer.pubBar)}</td>
                  <td className="px-2 py-1 text-right">{gbp(footer.pubAccom)}</td>
                  <td className="px-2 py-1 text-right font-semibold">{gbp(footer.pubTot)}</td>
                  <td className={'px-2 py-1 text-right font-semibold ' + labourPctColor(footer.pubLabPct)}>{footer.pubLabPct?.toFixed(1) ?? '—'}%</td>
                  <td className="px-2 py-1 text-right" style={{ color: '#ec4899' }}>{gbp(footer.cafeIce)}</td>
                  <td className="px-2 py-1 text-right" style={{ color: '#ec4899' }}>{gbp(footer.cafeOth)}</td>
                  <td className="px-2 py-1 text-right font-semibold" style={{ color: '#ec4899' }}>{gbp(footer.cafeTot)}</td>
                  <td className={'px-2 py-1 text-right font-semibold ' + labourPctColor(footer.cafeLabPct)}>{footer.cafeLabPct?.toFixed(1) ?? '—'}%</td>
                  <td className="px-2 py-1 text-right font-semibold">{gbp(footer.combTot)}</td>
                  <td className="px-2 py-1 text-right">{gbp(footer.combLab)}</td>
                  <td className={'px-2 py-1 text-right font-semibold ' + labourPctColor(footer.combLabPct)}>{footer.combLabPct?.toFixed(1) ?? '—'}%</td>
                  <td className="px-2 py-1 text-right italic text-ink-500">—</td>
                  <td className="px-2 py-1 text-right italic text-ink-500">—</td>
                </tr>
                <tr>
                  <td className="px-2 py-1">Average / day</td>
                  <td className="px-2 py-1 text-right">{gbp(footer.n > 0 ? footer.pubFood / footer.n : 0)}</td>
                  <td className="px-2 py-1 text-right">{gbp(footer.n > 0 ? footer.pubBar / footer.n : 0)}</td>
                  <td className="px-2 py-1 text-right">{gbp(footer.n > 0 ? footer.pubAccom / footer.n : 0)}</td>
                  <td className="px-2 py-1 text-right">{gbp(footer.n > 0 ? footer.pubTot / footer.n : 0)}</td>
                  <td className="px-2 py-1 text-right"></td>
                  <td className="px-2 py-1 text-right" style={{ color: '#ec4899' }}>{gbp(footer.n > 0 ? footer.cafeIce / footer.n : 0)}</td>
                  <td className="px-2 py-1 text-right" style={{ color: '#ec4899' }}>{gbp(footer.n > 0 ? footer.cafeOth / footer.n : 0)}</td>
                  <td className="px-2 py-1 text-right" style={{ color: '#ec4899' }}>{gbp(footer.n > 0 ? footer.cafeTot / footer.n : 0)}</td>
                  <td className="px-2 py-1 text-right"></td>
                  <td className="px-2 py-1 text-right">{gbp(footer.avgCombTot)}</td>
                  <td className="px-2 py-1 text-right">{gbp(footer.avgCombLab)}</td>
                  <td className="px-2 py-1 text-right"></td>
                  <td className="px-2 py-1 text-right italic text-ink-500">—</td>
                  <td className="px-2 py-1 text-right italic text-ink-500">—</td>
                </tr>
              </tfoot>
            </table>
          </div>
          {/* Pagination controls */}
          {tableRows.length > 0 && (
            <div className="flex items-center justify-between mt-3 text-xs">
              <span className="text-ink-500">
                Showing {startItem}–{endItem} of {tableRows.length} days
              </span>
              <div className="flex items-center gap-1">
                <button
                  onClick={() => setCurrentPage(p => Math.max(1, p - 1))}
                  disabled={safePage <= 1}
                  className="px-2 py-1 rounded border border-ink-200 text-ink-600 hover:bg-ink-100 disabled:opacity-30 disabled:cursor-not-allowed"
                >Prev</button>
                {pagination.map((p, i) =>
                  p === 'ellipsis' ? (
                    <span key={`e${i}`} className="px-1 text-ink-500">…</span>
                  ) : (
                    <button
                      key={p}
                      onClick={() => setCurrentPage(p)}
                      className={'px-2 py-1 rounded border ' + (p === safePage ? 'bg-amber-500 border-amber-500 text-ink-0' : 'border-ink-200 text-ink-600 hover:bg-ink-100')}
                    >{p}</button>
                  )
                )}
                <button
                  onClick={() => setCurrentPage(p => Math.min(totalPages, p + 1))}
                  disabled={safePage >= totalPages}
                  className="px-2 py-1 rounded border border-ink-200 text-ink-600 hover:bg-ink-100 disabled:opacity-30 disabled:cursor-not-allowed"
                >Next</button>
              </div>
            </div>
          )}
          {tableRows.length === 0 && !table.isLoading && (
            <div className="mt-3 text-xs text-ink-500 text-center">Showing 0–0 of 0 days</div>
          )}
          <p className="mt-2 text-sm text-ink-500">
            Labour % = labour cost ÷ sales for that category. COGS is overall (xero contacts not yet site-categorised).
            Pub COGS vs Café COGS will split once vendor-to-site mapping is wired.
            Accommodation revenue lives in caterbook and is intentionally excluded from sales totals to avoid double-counting.
          </p>
        </Section>
      </SandboxWrapper>
    </div>
  );
}
