'use client';

import { useMemo, useState } from 'react';
import { useSlug } from '@/lib/hooks';
import { Section } from '@/components/ui/Section';
import { KPICard } from '@/components/ui/KPICard';
import { DateRangePicker, DateRange } from '@/components/ui/DateRangePicker';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { gbp } from '@/lib/format';
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid,
  Legend, Cell, PieChart, Pie,
} from 'recharts';

type Realm = 'all' | 'work' | 'personal';
type GroupBy = 'vendor' | 'department' | 'product' | 'category';

interface KpiRow { spend: string; invoices: string; lines: string; vendors: string; avg_invoice: string }
interface ConfRow { captured: string; categorised: string; pct_categorised: string | null }
interface MonthRow { month: string; department: string; spend: string }
interface SummaryRow { group_key: string | null; lines: string; spend: string }
interface LineRow {
  invoice_date: string | null; vendor_name: string | null; department: string | null;
  category: string | null; item: string | null; description: string | null;
  quantity: string | null; unit_price: string | null; line_net: string | null;
  realm: string | null; gate_passed: boolean; verified: boolean;
}
interface ExcRow { id: number; invoice_date: string | null; vendor_name: string | null; gross_amount: string | null; extraction_tier: string | null; confidence: string | null; issue: string }
interface GmRow { month: string; dept: string | null; sales: string | null; cogs: string | null; gp_pct: string | null }
interface CovRow { month: string; captured_cogs: string | null; invoice_count: string; vendor_count: string; prev3_avg_cogs: string | null; pct_of_prev3: string | null; completeness: 'ok' | 'low' | 'empty' }
const GM_DEPTS = ['FOOD SALES', 'ALCOHOL SALES', 'HOT DRINKS'];
const COV_COLOR: Record<string, string> = { ok: '#22c55e', low: '#f59e0b', empty: '#ef4444' };

const DEPT_COLOR: Record<string, string> = {
  kitchen: '#f59e0b', bar: '#fb923c', overhead: '#64748b',
  accommodation: '#a78bfa', unmapped: '#404040',
};
const REALM_COLOR: Record<string, string> = { work: '#f59e0b', personal: '#a78bfa', owner: '#22d3ee' };
const DEPTS = ['kitchen', 'bar', 'overhead', 'accommodation', 'unmapped'];
const CATEGORIES = ['food', 'drink_alcohol', 'drink_soft', 'packaging', 'cleaning', 'utilities', 'services', 'repairs', 'capex', 'other'];

function num(s: string | number | null | undefined): number {
  if (s == null) return 0;
  const n = typeof s === 'number' ? s : parseFloat(s);
  return Number.isFinite(n) ? n : 0;
}

export default function InvoicesPage() {
  const [realm, setRealm] = useState<Realm>('all');
  const [range, setRange] = useState<DateRange>({
    preset: '12m',
    start: new Date(Date.now() - 364 * 864e5).toISOString().slice(0, 10),
    end: new Date().toISOString().slice(0, 10),
  });
  const [q, setQ] = useState('');
  const [groupBy, setGroupBy] = useState<GroupBy>('vendor');
  const [vendor, setVendor] = useState<string | null>(null);
  const [department, setDepartment] = useState<string | null>(null);
  const [product, setProduct] = useState<string | null>(null);

  // Shared filter params for the slugs.
  const params = useMemo(() => {
    const p: Record<string, string | number> = {};
    if (realm !== 'all') p.realm = realm;
    if (range.start) p.date_from = range.start;
    if (range.end) p.date_to = range.end;
    if (q.trim()) p.q = q.trim();
    if (vendor) p.vendor = vendor;
    if (department) p.department = department;
    if (product) p.product = product;
    return p;
  }, [realm, range, q, vendor, department, product]);

  const kpis    = useSlug<KpiRow>('purchase_kpis', params, { refetchInterval: 5 * 60_000 });
  const conf    = useSlug<ConfRow>('cogs_capture_confidence', {}, { refetchInterval: 10 * 60_000 });
  const byMonth = useSlug<MonthRow>('purchase_spend_by_month', realm !== 'all' ? { months: 12, realm } : { months: 12 });
  const topVend = useSlug<SummaryRow>('purchase_spend_summary', { ...params, group_by: 'vendor' });
  const realmSplit = useSlug<SummaryRow>('purchase_spend_summary', { group_by: 'realm' });
  const grouped = useSlug<SummaryRow>('purchase_spend_summary', { ...params, group_by: groupBy });
  const lines   = useSlug<LineRow>('purchase_search', params);
  const excs    = useSlug<ExcRow>('purchase_exceptions', {}, { refetchInterval: 10 * 60_000 });
  const gm      = useSlug<GmRow>('gross_margin_period', { months: 6 }, { refetchInterval: 10 * 60_000 });
  const cov     = useSlug<CovRow>('cogs_capture_coverage', { months: 12 }, { refetchInterval: 10 * 60_000 });

  const kpi = kpis.data?.[0];
  const confRow = conf.data?.[0];

  // Exception workflow — confirm or categorise (categorise applies across the vendor).
  const [catSel, setCatSel] = useState<Record<number, string>>({});
  const [busy, setBusy] = useState<number | null>(null);
  const act = async (id: number, action: 'confirm' | 'categorise', category?: string) => {
    setBusy(id);
    try {
      await fetch(`${process.env.NEXT_PUBLIC_BASE_PATH || ''}/api/invoices/verify`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ purchase_id: id, action, category }),
      });
      await Promise.all([excs.refetch(), kpis.refetch(), grouped.refetch(), conf.refetch()]);
    } finally { setBusy(null); }
  };

  // Pivot month×department → recharts stacked rows.
  const monthChart = useMemo(() => {
    const byM: Record<string, Record<string, number>> = {};
    (byMonth.data ?? []).forEach(r => {
      const m = String(r.month).slice(0, 7);
      byM[m] = byM[m] || {};
      byM[m][r.department] = num(r.spend);
    });
    return Object.entries(byM).map(([m, depts]) => ({ month: m, ...depts }));
  }, [byMonth.data]);

  const chips: { label: string; clear: () => void }[] = [];
  if (vendor) chips.push({ label: `vendor: ${vendor}`, clear: () => setVendor(null) });
  if (department) chips.push({ label: `dept: ${department}`, clear: () => setDepartment(null) });
  if (product) chips.push({ label: `item: ${product}`, clear: () => setProduct(null) });

  // Clicking a grouped row drills into the matching filter.
  const drill = (key: string | null) => {
    if (!key) return;
    if (groupBy === 'vendor') setVendor(key);
    else if (groupBy === 'department') setDepartment(key);
    else if (groupBy === 'product') setProduct(key);
  };

  return (
    <div className="space-y-6">
      {/* Filter bar */}
      <div className="flex items-center justify-between flex-wrap gap-3">
        <div className="flex bg-ink-100 border border-ink-200 rounded-md overflow-hidden text-xs">
          {(['all', 'work', 'personal'] as Realm[]).map(r => (
            <button key={r} onClick={() => setRealm(r)}
              className={'px-3 py-1.5 capitalize ' + (realm === r ? 'bg-amber-500 text-ink-0' : 'text-ink-600 hover:text-ink-800')}>
              {r === 'work' ? 'Business' : r}
            </button>
          ))}
        </div>
        <div className="flex items-center gap-2">
          <input value={q} onChange={e => setQ(e.target.value)} placeholder="search vendor / item…"
            className="bg-ink-100 border border-ink-200 text-ink-800 rounded px-3 py-1.5 text-xs w-52" />
          <DateRangePicker value={range} onChange={setRange} />
        </div>
      </div>

      {/* Realm-enforcement caveat */}
      <div className="text-[11px] text-ink-500 border border-ink-200 rounded px-3 py-1.5 bg-ink-100/50">
        Owner view — shows all realms. Personal invoices are visible here until realm-auth (R4/U147) lands;
        gate behind realm login before a work-only (manager) account uses this page.
      </div>

      {/* Active drill chips */}
      {chips.length > 0 && (
        <div className="flex items-center gap-2 flex-wrap text-xs">
          {chips.map((c, i) => (
            <button key={i} onClick={c.clear}
              className="px-2 py-1 rounded-full bg-amber-500/20 text-amber-300 border border-amber-500/40 hover:bg-amber-500/30">
              {c.label} ✕
            </button>
          ))}
        </div>
      )}

      {/* KPI row */}
      <SandboxWrapper id="invoices.kpi" label="Invoice KPIs">
        <div className="grid grid-cols-2 md:grid-cols-5 gap-3">
          <KPICard label="Spend (range)" value={kpis.isLoading ? null : gbp(num(kpi?.spend))} loading={kpis.isLoading} />
          <KPICard label="Invoices" value={kpis.isLoading ? null : (kpi?.invoices ?? '0')} loading={kpis.isLoading} />
          <KPICard label="Avg invoice" value={kpis.isLoading ? null : gbp(num(kpi?.avg_invoice))} loading={kpis.isLoading} />
          <KPICard label="Capture (categorised)" value={confRow?.pct_categorised ? `${confRow.pct_categorised}%` : '—'} loading={conf.isLoading} />
          <KPICard label="Needs attention" value={excs.isLoading ? null : (excs.data?.length ?? 0)} loading={excs.isLoading} />
        </div>
      </SandboxWrapper>

      {/* Charts */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <SandboxWrapper id="invoices.bymonth" label="Spend by month/dept">
          <Section title="Spend by department (monthly)">
            {byMonth.isLoading ? <div className="text-xs text-ink-500">Loading…</div> :
             monthChart.length === 0 ? <PlaceholderState message="No spend in range" /> : (
              <figure className="tile h-[280px]">
                <ResponsiveContainer width="100%" height="100%">
                  <BarChart data={monthChart} margin={{ top: 8, right: 12, left: 4, bottom: 4 }}>
                    <CartesianGrid stroke="#2a2a2a" vertical={false} />
                    <XAxis dataKey="month" stroke="#737373" fontSize={10} tickFormatter={d => String(d).slice(5)} />
                    <YAxis stroke="#737373" fontSize={10} tickFormatter={v => `£${v}`} />
                    <Tooltip contentStyle={{ background: '#171717', border: '1px solid #2a2a2a' }} formatter={(v: number) => gbp(v)} />
                    <Legend wrapperStyle={{ fontSize: 10 }} />
                    {DEPTS.map(d => <Bar key={d} dataKey={d} stackId="s" fill={DEPT_COLOR[d]} name={d} />)}
                  </BarChart>
                </ResponsiveContainer>
              </figure>
            )}
          </Section>
        </SandboxWrapper>

        <SandboxWrapper id="invoices.topvendors" label="Top vendors">
          <Section title="Top vendors">
            {topVend.isLoading ? <div className="text-xs text-ink-500">Loading…</div> :
             (topVend.data ?? []).length === 0 ? <PlaceholderState message="No vendors in range" /> : (
              <figure className="tile h-[280px]">
                <ResponsiveContainer width="100%" height="100%">
                  <BarChart layout="vertical" data={(topVend.data ?? []).slice(0, 10).map(r => ({ name: (r.group_key ?? '—').slice(0, 22), spend: num(r.spend) }))}
                    margin={{ top: 4, right: 16, left: 8, bottom: 4 }}>
                    <CartesianGrid stroke="#2a2a2a" horizontal={false} />
                    <XAxis type="number" stroke="#737373" fontSize={10} tickFormatter={v => `£${v}`} />
                    <YAxis type="category" dataKey="name" stroke="#737373" fontSize={9} width={120} />
                    <Tooltip contentStyle={{ background: '#171717', border: '1px solid #2a2a2a' }} formatter={(v: number) => gbp(v)} />
                    <Bar dataKey="spend" fill="#f59e0b" />
                  </BarChart>
                </ResponsiveContainer>
              </figure>
            )}
          </Section>
        </SandboxWrapper>

        <SandboxWrapper id="invoices.realmsplit" label="Realm split">
          <Section title="Business vs personal">
            {realmSplit.isLoading ? <div className="text-xs text-ink-500">Loading…</div> : (
              <figure className="tile h-[280px]">
                <ResponsiveContainer width="100%" height="100%">
                  <PieChart>
                    <Pie data={(realmSplit.data ?? []).map(r => ({ name: r.group_key === 'work' ? 'Business' : (r.group_key ?? '—'), value: num(r.spend), key: r.group_key ?? '' }))}
                      dataKey="value" nameKey="name" cx="50%" cy="50%" outerRadius={90} label={(e: { name?: string }) => e.name ?? ''}>
                      {(realmSplit.data ?? []).map((r, i) => <Cell key={i} fill={REALM_COLOR[r.group_key ?? ''] ?? '#737373'} />)}
                    </Pie>
                    <Tooltip contentStyle={{ background: '#171717', border: '1px solid #2a2a2a' }} formatter={(v: number) => gbp(v)} />
                  </PieChart>
                </ResponsiveContainer>
              </figure>
            )}
          </Section>
        </SandboxWrapper>
      </div>

      {/* Gross margin — provisional */}
      <SandboxWrapper id="invoices.gp" label="Gross margin (provisional)">
        <Section title="Gross margin — provisional (WIP)">
          <div className="text-[11px] text-ink-500 italic mb-2">
            Provisional: COGS is invoice-date based (lumpy) and the category→sales-department mapping is
            partial, so GP% currently reads high. Capture {confRow?.pct_categorised ?? '—'}% categorised — firms up as both improve.
            {(() => {
              const bad = (cov.data ?? []).filter(r => r.completeness !== 'ok');
              if (bad.length === 0) return null;
              return <> <span className="text-amber-500 not-italic">⚠ {bad.length} month{bad.length > 1 ? 's' : ''} with thin invoice capture — GP% for those is unreliable.</span></>;
            })()}
          </div>

          {/* Capture-completeness strip (U232 T3): per-month captured COGS vs trailing avg */}
          {(cov.data ?? []).length > 0 && (
            <div className="mb-3">
              <div className="text-[10px] uppercase tracking-wide text-ink-500 mb-1">Capture completeness (last 12mo)</div>
              <div className="flex flex-wrap gap-1">
                {[...(cov.data ?? [])].reverse().map((r, i) => (
                  <div key={i}
                    title={`${String(r.month).slice(0, 7)} · captured ${gbp(num(r.captured_cogs))} · ${r.invoice_count} invoices · ${r.pct_of_prev3 ?? '—'}% of prior-3mo avg`}
                    className="flex flex-col items-center px-1.5 py-1 rounded border border-ink-200 bg-ink-50 min-w-[42px]">
                    <span className="text-[9px] text-ink-500">{String(r.month).slice(0, 7).slice(2)}</span>
                    <span className="w-2 h-2 rounded-full my-0.5" style={{ background: COV_COLOR[r.completeness] ?? '#64748b' }} />
                    <span className="text-[9px] font-mono text-ink-600">{r.invoice_count}</span>
                  </div>
                ))}
              </div>
              <div className="text-[10px] text-ink-500 mt-1 flex gap-3">
                <span><span className="inline-block w-2 h-2 rounded-full mr-1 align-middle" style={{ background: COV_COLOR.ok }} />ok</span>
                <span><span className="inline-block w-2 h-2 rounded-full mr-1 align-middle" style={{ background: COV_COLOR.low }} />thin (&lt;50% of trailing avg)</span>
                <span><span className="inline-block w-2 h-2 rounded-full mr-1 align-middle" style={{ background: COV_COLOR.empty }} />empty</span>
              </div>
            </div>
          )}
          {gm.isLoading ? <div className="text-xs text-ink-500">Loading…</div> :
           (gm.data ?? []).filter(r => GM_DEPTS.includes(r.dept ?? '')).length === 0 ?
            <PlaceholderState message="No mapped gross-margin rows yet" /> : (
            <div className="overflow-auto max-h-[300px] text-xs">
              <table className="w-full">
                <thead className="text-ink-500 sticky top-0 bg-ink-50"><tr>
                  <th className="text-left px-2 py-1">month</th>
                  <th className="text-left px-2 py-1">department</th>
                  <th className="text-right px-2 py-1">sales</th>
                  <th className="text-right px-2 py-1">COGS</th>
                  <th className="text-right px-2 py-1 italic">GP % (WIP)</th>
                </tr></thead>
                <tbody>
                  {(gm.data ?? []).filter(r => GM_DEPTS.includes(r.dept ?? '')).map((r, i) => (
                    <tr key={i} className="border-t border-ink-200">
                      <td className="px-2 py-1">{String(r.month).slice(0, 7)}</td>
                      <td className="px-2 py-1">{r.dept}</td>
                      <td className="px-2 py-1 text-right font-mono">{gbp(num(r.sales))}</td>
                      <td className="px-2 py-1 text-right font-mono">{gbp(num(r.cogs))}</td>
                      <td className="px-2 py-1 text-right font-mono italic text-ink-400">{r.gp_pct != null ? `${r.gp_pct}%` : '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </Section>
      </SandboxWrapper>

      {/* Waterfall explorer */}
      <SandboxWrapper id="invoices.explorer" label="Spend explorer">
        <Section title="Spend explorer — drill to line items">
          <div className="mb-2 flex items-center gap-2 text-xs">
            <span className="text-ink-500">group by:</span>
            <div className="flex bg-ink-100 border border-ink-200 rounded overflow-hidden">
              {(['vendor', 'department', 'product', 'category'] as GroupBy[]).map(g => (
                <button key={g} onClick={() => setGroupBy(g)}
                  className={'px-2.5 py-1 capitalize ' + (groupBy === g ? 'bg-amber-500 text-ink-0' : 'text-ink-600 hover:text-ink-800')}>{g}</button>
              ))}
            </div>
          </div>
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            {/* Grouped totals */}
            <div className="overflow-auto max-h-[360px] text-xs">
              <table className="w-full">
                <thead className="text-ink-500 sticky top-0 bg-ink-50"><tr>
                  <th className="text-left px-2 py-1 capitalize">{groupBy}</th>
                  <th className="text-right px-2 py-1">lines</th>
                  <th className="text-right px-2 py-1">spend</th>
                </tr></thead>
                <tbody>
                  {(grouped.data ?? []).map((r, i) => (
                    <tr key={i} onClick={() => drill(r.group_key)}
                      className="border-t border-ink-200 hover:bg-ink-100 cursor-pointer">
                      <td className="px-2 py-1">{r.group_key ?? '—'}</td>
                      <td className="px-2 py-1 text-right text-ink-500">{r.lines}</td>
                      <td className="px-2 py-1 text-right font-mono">{gbp(num(r.spend))}</td>
                    </tr>
                  ))}
                  {(grouped.data ?? []).length === 0 && !grouped.isLoading && (
                    <tr><td colSpan={3} className="px-2 py-4 text-ink-500">No data</td></tr>
                  )}
                </tbody>
              </table>
            </div>
            {/* Line-item detail */}
            <div className="overflow-auto max-h-[360px] text-xs">
              <table className="w-full">
                <thead className="text-ink-500 sticky top-0 bg-ink-50"><tr>
                  <th className="text-left px-2 py-1">date</th>
                  <th className="text-left px-2 py-1">vendor</th>
                  <th className="text-left px-2 py-1">item</th>
                  <th className="text-right px-2 py-1">£</th>
                </tr></thead>
                <tbody>
                  {(lines.data ?? []).slice(0, 200).map((r, i) => (
                    <tr key={i} className="border-t border-ink-200">
                      <td className="px-2 py-1 whitespace-nowrap">{String(r.invoice_date ?? '').slice(0, 10)}</td>
                      <td className="px-2 py-1">{(r.vendor_name ?? '—').slice(0, 22)}</td>
                      <td className="px-2 py-1">{(r.item ?? r.description ?? '—').slice(0, 30)}</td>
                      <td className="px-2 py-1 text-right font-mono">{gbp(num(r.line_net))}</td>
                    </tr>
                  ))}
                  {(lines.data ?? []).length === 0 && !lines.isLoading && (
                    <tr><td colSpan={4} className="px-2 py-4 text-ink-500">No line items</td></tr>
                  )}
                </tbody>
              </table>
            </div>
          </div>
        </Section>
      </SandboxWrapper>

      {/* Exceptions lane */}
      <SandboxWrapper id="invoices.exceptions" label="Needs attention">
        <Section title={`Needs attention${excs.data ? ` (${excs.data.length})` : ''}`}>
          {excs.isLoading ? <div className="text-xs text-ink-500">Loading…</div> :
           (excs.data ?? []).length === 0 ? <PlaceholderState message="Nothing needs attention" hint="All captured invoices are gate-passed and categorised." /> : (
            <div className="overflow-auto max-h-[320px] text-xs">
              <table className="w-full">
                <thead className="text-ink-500 sticky top-0 bg-ink-50"><tr>
                  <th className="text-left px-2 py-1">date</th>
                  <th className="text-left px-2 py-1">vendor</th>
                  <th className="text-right px-2 py-1">£</th>
                  <th className="text-left px-2 py-1">issue</th>
                  <th className="text-left px-2 py-1">tier</th>
                  <th className="text-left px-2 py-1">action</th>
                </tr></thead>
                <tbody>
                  {(excs.data ?? []).map(r => (
                    <tr key={r.id} className="border-t border-ink-200">
                      <td className="px-2 py-1 whitespace-nowrap">{String(r.invoice_date ?? '').slice(0, 10)}</td>
                      <td className="px-2 py-1">{(r.vendor_name ?? '—').slice(0, 24)}</td>
                      <td className="px-2 py-1 text-right font-mono">{gbp(num(r.gross_amount))}</td>
                      <td className="px-2 py-1">
                        <span className={'px-1.5 py-0.5 rounded text-[10px] ' + (r.issue === 'low confidence' ? 'bg-red-500/20 text-red-300' : 'bg-amber-500/20 text-amber-300')}>{r.issue}</span>
                      </td>
                      <td className="px-2 py-1 text-ink-500">{r.extraction_tier}</td>
                      <td className="px-2 py-1">
                        <div className="flex items-center gap-1">
                          <select value={catSel[r.id] ?? ''} onChange={e => setCatSel(s => ({ ...s, [r.id]: e.target.value }))}
                            className="bg-ink-100 border border-ink-200 rounded px-1 py-0.5 text-[11px]">
                            <option value="">category…</option>
                            {CATEGORIES.map(c => <option key={c} value={c}>{c}</option>)}
                          </select>
                          <button disabled={!catSel[r.id] || busy === r.id} onClick={() => act(r.id, 'categorise', catSel[r.id])}
                            className="px-1.5 py-0.5 rounded bg-amber-500/20 text-amber-300 border border-amber-500/40 disabled:opacity-40 text-[11px]">apply</button>
                          <button disabled={busy === r.id} onClick={() => act(r.id, 'confirm')}
                            className="px-1.5 py-0.5 rounded bg-ink-200 text-ink-700 disabled:opacity-40 text-[11px]">confirm</button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
              <p className="mt-2 text-[11px] text-ink-500">“Apply” sets the category on this invoice <em>and every uncategorised invoice from the same vendor</em>, then marks them verified — the queue shrinks as you go.</p>
            </div>
          )}
        </Section>
      </SandboxWrapper>
    </div>
  );
}
