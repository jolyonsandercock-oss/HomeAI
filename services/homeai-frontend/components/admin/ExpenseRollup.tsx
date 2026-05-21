'use client';

import { useState } from 'react';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';
import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { DateRangePicker, DateRange } from '@/components/ui/DateRangePicker';

type SiteFilter = 'all' | 'pub' | 'cafe' | 'shared';

interface Totals {
  total_gross: string;
  total_net: string;
  total_vat: string;
  invoice_count: string;
  uncategorised_count: string;
  uncategorised_gross: string;
  missing_date_count: string;
}
interface CategoryRow { category: string; total_gross: string; invoice_count: string }
interface FamilyRow   { family: string;   total_gross: string; line_count: string; invoice_count: string }
interface DeptRow     { department: string; total_gross: string; line_count: string; invoice_count: string }
interface VendorRow   { vendor: string;   total_gross: string; invoice_count: string; last_seen: string; sites: string }

function todayISO() { return new Date().toISOString().slice(0, 10); }
function daysAgoISO(n: number) {
  const d = new Date(); d.setDate(d.getDate() - n);
  return d.toISOString().slice(0, 10);
}

export function ExpenseRollup() {
  const [range, setRange] = useState<DateRange>({
    preset: '30d', start: daysAgoISO(29), end: todayISO(),
  });
  const [site, setSite] = useState<SiteFilter>('all');

  const params = { date_from: range.start, date_to: range.end, site, limit: 15 };

  const totals      = useSlug<Totals>     ('expense_totals',         params, { refetchInterval: 5 * 60_000 });
  const categories  = useSlug<CategoryRow>('expense_top_categories', params, { refetchInterval: 5 * 60_000 });
  const families    = useSlug<FamilyRow>  ('expense_top_families',   params, { refetchInterval: 5 * 60_000 });
  const departments = useSlug<DeptRow>    ('expense_by_department',  { date_from: range.start, date_to: range.end, site }, { refetchInterval: 5 * 60_000 });
  const vendors     = useSlug<VendorRow>  ('expense_top_vendors',    params, { refetchInterval: 5 * 60_000 });

  const t = totals.data?.[0];

  return (
    <Section
      title="Expenses from emails"
      action={
        <div className="flex items-center gap-3 flex-wrap justify-end">
          <DateRangePicker
            value={range}
            onChange={setRange}
            presets={['7d', '30d', '90d', 'ytd', '12m']}
          />
          <div className="flex bg-ink-100 border border-ink-200 rounded-md overflow-hidden text-xs">
            {(['all', 'pub', 'cafe'] as SiteFilter[]).map((s) => (
              <button key={s}
                onClick={() => setSite(s)}
                className={
                  'px-2.5 py-1.5 capitalize ' +
                  (site === s ? 'bg-amber-500 text-ink-0' : 'text-ink-600 hover:text-ink-800')
                }>
                {s}
              </button>
            ))}
          </div>
        </div>
      }
    >
      <div className="tile p-0 overflow-hidden">
        {/* KPI row */}
        <div className="grid grid-cols-2 sm:grid-cols-4 border-b border-ink-200">
          <Kpi label="Gross"     value={gbp(t?.total_gross)}
               sub={t ? `${t.invoice_count} invoices` : ''} />
          <Kpi label="Net"       value={gbp(t?.total_net)} />
          <Kpi label="VAT"       value={gbp(t?.total_vat)} />
          <Kpi label="Uncat."
               value={gbp(t?.uncategorised_gross)}
               sub={t && Number(t.uncategorised_count) > 0 ? `${t.uncategorised_count} need coding` : ''}
               warn={t ? Number(t.uncategorised_gross) > 0 : false} />
        </div>
        {t && Number(t.missing_date_count) > 0 && (
          <div className="px-3 py-1.5 text-[11px] text-ink-500 bg-ink-50 border-b border-ink-200">
            {t.missing_date_count} of {t.invoice_count} rows have no extracted invoice date — falling back to email-received date. Haiku coverage gap; affects accuracy of date filtering.
          </div>
        )}

        {/* Three-column body: categories | product families | departments */}
        <div className="grid grid-cols-1 lg:grid-cols-3 divide-y lg:divide-y-0 lg:divide-x divide-ink-200">
          <RollupList title="By spend category" subtitle="email-level category_canonical"
                      rows={categories.data} loading={categories.isLoading}
                      labelKey="category" valueKey="total_gross" countKey="invoice_count"
                      countLabel="inv" />
          <RollupList title="By product family" subtitle="from Haiku-extracted line items (~3% mapped)"
                      rows={families.data} loading={families.isLoading}
                      labelKey="family" valueKey="total_gross" countKey="line_count"
                      countLabel="lines" />
          <RollupList title="By department" subtitle="bar / kitchen / rooms / cafe / overhead"
                      rows={departments.data} loading={departments.isLoading}
                      labelKey="department" valueKey="total_gross" countKey="line_count"
                      countLabel="lines" />
        </div>

        {/* Vendors */}
        <div className="border-t border-ink-200">
          <div className="px-3 pt-3 pb-1 flex items-baseline justify-between">
            <h3 className="text-sm font-medium text-ink-800">Top vendors</h3>
            <span className="text-xs text-ink-500">{vendors.data?.length ?? 0} of top 15</span>
          </div>
          {vendors.isLoading ? (
            <PlaceholderState message="Loading vendors…" />
          ) : vendors.data && vendors.data.length > 0 ? (
            <table className="w-full text-sm">
              <thead className="text-xs text-ink-500 uppercase tracking-wider">
                <tr>
                  <th className="text-left font-medium px-3 py-1.5">Vendor</th>
                  <th className="text-left font-medium px-3">Site</th>
                  <th className="text-right font-medium px-3">Gross</th>
                  <th className="text-right font-medium px-3">Invs</th>
                  <th className="text-left font-medium px-3">Last seen</th>
                </tr>
              </thead>
              <tbody>
                {vendors.data.map((v, i) => (
                  <tr key={i} className="border-t border-ink-200">
                    <td className="px-3 py-1.5 text-ink-800 max-w-[28rem] truncate">{cleanVendor(v.vendor)}</td>
                    <td className="px-3 text-xs text-ink-500 capitalize">{v.sites || '—'}</td>
                    <td className="px-3 text-right font-mono text-ink-700">{gbp(v.total_gross)}</td>
                    <td className="px-3 text-right text-xs text-ink-500">{v.invoice_count}</td>
                    <td className="px-3 text-xs font-mono text-ink-500">
                      {v.last_seen ? new Date(v.last_seen).toLocaleDateString('en-GB') : '—'}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <PlaceholderState message="No vendor invoices in this window." />
          )}
        </div>
      </div>
    </Section>
  );
}

function Kpi({ label, value, sub, warn }: { label: string; value: string; sub?: string; warn?: boolean }) {
  return (
    <div className="px-3 py-2.5">
      <div className="text-[10px] uppercase tracking-wider text-ink-500">{label}</div>
      <div className={'text-lg font-mono ' + (warn ? 'text-amber-600' : 'text-ink-800')}>{value}</div>
      {sub && <div className="text-xs text-ink-500 mt-0.5">{sub}</div>}
    </div>
  );
}

function RollupList<T extends object>({
  title, subtitle, rows, loading, labelKey, valueKey, countKey, countLabel,
}: {
  title: string; subtitle: string;
  rows: T[] | undefined; loading: boolean;
  labelKey: keyof T; valueKey: keyof T; countKey: keyof T; countLabel: string;
}) {
  const top = rows?.[0];
  const topVal = top ? Number(top[valueKey] as unknown as string) : 0;
  return (
    <div className="p-3">
      <div className="flex items-baseline justify-between mb-2">
        <h3 className="text-sm font-medium text-ink-800">{title}</h3>
        <span className="text-[10px] text-ink-500">{subtitle}</span>
      </div>
      {loading ? (
        <PlaceholderState message="Loading…" />
      ) : rows && rows.length > 0 ? (
        <div className="space-y-1">
          {rows.map((r, i) => {
            const v = Number(r[valueKey] as unknown as string);
            const pct = topVal > 0 ? (v / topVal) * 100 : 0;
            return (
              <div key={i} className="text-sm">
                <div className="flex items-baseline justify-between gap-2">
                  <span className="text-ink-800 truncate">{String(r[labelKey])}</span>
                  <span className="font-mono text-ink-700 whitespace-nowrap">
                    {gbp(r[valueKey] as unknown as string)}
                    <span className="text-xs text-ink-500 ml-1.5">· {String(r[countKey])} {countLabel}</span>
                  </span>
                </div>
                <div className="h-1 bg-ink-100 rounded mt-1">
                  <div className="h-1 bg-amber-500 rounded" style={{ width: pct + '%' }} />
                </div>
              </div>
            );
          })}
        </div>
      ) : (
        <PlaceholderState message="No rows in this window." />
      )}
    </div>
  );
}

// "St. Austell Brewery <salesaccounts@…>" → "St. Austell Brewery"
function cleanVendor(v: string): string {
  if (!v) return '—';
  const m = v.match(/^"?([^"<]+?)"?\s*<.*>$/);
  return m ? m[1].trim() : v;
}
