#!/usr/bin/env python3
"""Rewrite the sales page — split table into Pub/Cafe sections, new slug columns."""

path = "/home_ai/services/homeai-frontend/app/sales/page.tsx"

with open(path) as f:
    content = f.read()

# === 1. Update FilterableRow interface ===
old_interface = """interface FilterableRow {
  day: string;
  pub_food: string; pub_bar: string; pub_accom: string;
  cafe_icecream: string; cafe_other: string;
  labour_cost: string; cogs_overall: string;
  sales_excl_accom: string; labour_pct: string | null;
}"""

new_interface = """interface FilterableRow {
  day: string;
  pub_food: string; pub_bar: string; pub_accom: string; pub_total: string;
  pub_labour: string; pub_labour_pct: string | null;
  cafe_icecream: string; cafe_other: string; cafe_total: string;
  cafe_labour: string; cafe_labour_pct: string | null;
  combined_total: string; combined_labour: string; combined_labour_pct: string | null;
  cogs_overall: string;
}"""

content = content.replace(old_interface, new_interface)

# === 2. Update table filter to use combined_total ===
content = content.replace(
    "const [tableFilter, setTableFilter] = useState<'' | 'high_labour' | 'low_sales' | 'has_data'>('');",
    "const [tableFilter, setTableFilter] = useState<'' | 'high_labour' | 'low_sales' | 'has_data'>('has_data');"
)

# === 3. Update tableRows filter logic ===
old_filter = """  const tableRows = useMemo(() => {
    let rows = table.data ?? [];
    if (tableFilter === 'has_data') rows = rows.filter(r => num(r.sales_excl_accom) > 0);
    if (tableFilter === 'low_sales') rows = rows.filter(r => num(r.sales_excl_accom) < 1000 && num(r.sales_excl_accom) > 0);
    if (tableFilter === 'high_labour') rows = rows.filter(r => r.labour_pct != null && num(r.labour_pct) > 30);
    return rows;
  }, [table.data, tableFilter]);"""

new_filter = """  const tableRows = useMemo(() => {
    let rows = table.data ?? [];
    if (tableFilter === 'has_data') rows = rows.filter(r => num(r.combined_total) > 0);
    if (tableFilter === 'low_sales') rows = rows.filter(r => num(r.combined_total) < 1000 && num(r.combined_total) > 0);
    if (tableFilter === 'high_labour') rows = rows.filter(r => r.combined_labour_pct != null && num(r.combined_labour_pct) > 30);
    return rows;
  }, [table.data, tableFilter]);"""

content = content.replace(old_filter, new_filter)

# === 4. Update footer to use new columns ===
old_footer = """  const footer = useMemo(() => {
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
  }, [tableRows]);"""

new_footer = """  const footer = useMemo(() => {
    const rows = tableRows;
    const n = rows.length;
    const sum = (k: string) => rows.reduce((a, r) => a + num((r as any)[k]), 0);
    const pubSales = sum('pub_total');
    const cafeSales = sum('cafe_total');
    const totalSales = sum('combined_total');
    const pubLabour = sum('pub_labour');
    const cafeLabour = sum('cafe_labour');
    const totalLabour = sum('combined_labour');
    const totalCogs = sum('cogs_overall');
    return {
      n,
      pubSales, cafeSales, sales: totalSales,
      pubLabour, cafeLabour, labour: totalLabour, cogs: totalCogs,
      pubLabourPct: pubSales > 0 ? (pubLabour / pubSales) * 100 : null,
      cafeLabourPct: cafeSales > 0 ? (cafeLabour / cafeSales) * 100 : null,
      labourPct: totalSales > 0 ? (totalLabour / totalSales) * 100 : null,
      cogsPct:   totalSales > 0 ? (totalCogs   / totalSales) * 100 : null,
      avgSales:  n > 0 ? totalSales / n : 0,
      avgPubSales: n > 0 ? pubSales / n : 0,
      avgCafeSales: n > 0 ? cafeSales / n : 0,
      avgPubLabour: n > 0 ? pubLabour / n : 0,
      avgCafeLabour: n > 0 ? cafeLabour / n : 0,
      avgLabour: n > 0 ? totalLabour / n : 0,
    };
  }, [tableRows]);"""

content = content.replace(old_footer, new_footer)

# === 5. Replace the entire table (thead + tbody + tfoot + note) ===
old_table_section = """          <div className="tile overflow-x-auto" id="sales-filterable-table">
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
          </p>"""

new_table_section = """          <div className="tile overflow-x-auto" id="sales-filterable-table">
            <table className="w-full text-xs font-mono"
              aria-label="Daily sales, wage and COGS table — accessible alternative to the charts above">
              <thead className="text-ink-500 uppercase tracking-wider text-xs">
                <tr>
                  <th className="px-2 py-1 text-left" rowSpan={2}>Day</th>
                  <th className="px-2 py-1 text-center border-b border-ink-200" colSpan={5}>Pub (Malthouse)</th>
                  <th className="px-2 py-1 text-center border-b border-ink-200" colSpan={4}>Café (Sandwich)</th>
                  <th className="px-2 py-1 text-center border-b border-ink-200" colSpan={3}>Combined</th>
                  <th className="px-2 py-1 text-right border-b border-ink-200" rowSpan={2}>COGS £</th>
                </tr>
                <tr>
                  <th className="px-2 py-1 text-right">Food</th>
                  <th className="px-2 py-1 text-right">Bar</th>
                  <th className="px-2 py-1 text-right">Accom</th>
                  <th className="px-2 py-1 text-right">Total</th>
                  <th className="px-2 py-1 text-right">Lab %</th>
                  <th className="px-2 py-1 text-right">Ice Cr</th>
                  <th className="px-2 py-1 text-right">Other</th>
                  <th className="px-2 py-1 text-right">Total</th>
                  <th className="px-2 py-1 text-right">Lab %</th>
                  <th className="px-2 py-1 text-right">Total</th>
                  <th className="px-2 py-1 text-right">Lab £</th>
                  <th className="px-2 py-1 text-right">Lab %</th>
                </tr>
              </thead>
              <tbody>
                {tableRows.map((r) => (
                  <tr key={r.day} className="border-t border-ink-200">
                    <td className="px-2 py-1">{r.day}</td>
                    {/* Pub columns */}
                    <td className="px-2 py-1 text-right">{gbp(num(r.pub_food))}</td>
                    <td className="px-2 py-1 text-right">{gbp(num(r.pub_bar))}</td>
                    <td className="px-2 py-1 text-right">{gbp(num(r.pub_accom))}</td>
                    <td className="px-2 py-1 text-right font-semibold">{gbp(num(r.pub_total))}</td>
                    <td className={'px-2 py-1 text-right ' + (r.pub_labour_pct != null && num(r.pub_labour_pct) > 35 ? 'text-red-400' : r.pub_labour_pct != null && num(r.pub_labour_pct) > 25 ? 'text-amber-300' : '')}>{r.pub_labour_pct ?? '—'}{r.pub_labour_pct != null ? '%' : ''}</td>
                    {/* Cafe columns */}
                    <td className="px-2 py-1 text-right">{gbp(num(r.cafe_icecream))}</td>
                    <td className="px-2 py-1 text-right">{gbp(num(r.cafe_other))}</td>
                    <td className="px-2 py-1 text-right font-semibold">{gbp(num(r.cafe_total))}</td>
                    <td className={'px-2 py-1 text-right ' + (r.cafe_labour_pct != null && num(r.cafe_labour_pct) > 35 ? 'text-red-400' : r.cafe_labour_pct != null && num(r.cafe_labour_pct) > 25 ? 'text-amber-300' : '')}>{r.cafe_labour_pct ?? '—'}{r.cafe_labour_pct != null ? '%' : ''}</td>
                    {/* Combined columns */}
                    <td className="px-2 py-1 text-right font-semibold text-amber-300">{gbp(num(r.combined_total))}</td>
                    <td className="px-2 py-1 text-right">{gbp(num(r.combined_labour))}</td>
                    <td className={'px-2 py-1 text-right ' + (r.combined_labour_pct != null && num(r.combined_labour_pct) > 35 ? 'text-red-400' : r.combined_labour_pct != null && num(r.combined_labour_pct) > 25 ? 'text-amber-300' : '')}>{r.combined_labour_pct ?? '—'}{r.combined_labour_pct != null ? '%' : ''}</td>
                    <td className="px-2 py-1 text-right">{gbp(num(r.cogs_overall))}</td>
                  </tr>
                ))}
                {tableRows.length === 0 && (
                  <tr><td colSpan={15} className="px-2 py-4 text-center text-ink-500">No rows match the filter</td></tr>
                )}
              </tbody>
              <tfoot className="border-t-2 border-ink-300 text-ink-700">
                <tr className="text-xs">
                  <td className="px-2 py-1 font-semibold">Total ({footer.n}d)</td>
                  <td className="px-2 py-1 text-right" colSpan={3}></td>
                  <td className="px-2 py-1 text-right font-semibold">{gbp(footer.pubSales)}</td>
                  <td className="px-2 py-1 text-right font-semibold">{footer.pubLabourPct?.toFixed(1) ?? '—'}%</td>
                  <td className="px-2 py-1 text-right" colSpan={2}></td>
                  <td className="px-2 py-1 text-right font-semibold">{gbp(footer.cafeSales)}</td>
                  <td className="px-2 py-1 text-right font-semibold">{footer.cafeLabourPct?.toFixed(1) ?? '—'}%</td>
                  <td className="px-2 py-1 text-right font-semibold">{gbp(footer.sales)}</td>
                  <td className="px-2 py-1 text-right font-semibold">{gbp(footer.labour)}</td>
                  <td className="px-2 py-1 text-right font-semibold">{footer.labourPct?.toFixed(1) ?? '—'}%</td>
                  <td className="px-2 py-1 text-right font-semibold">{gbp(footer.cogs)}</td>
                </tr>
                <tr className="text-xs">
                  <td className="px-2 py-1">Avg / day</td>
                  <td className="px-2 py-1 text-right" colSpan={3}></td>
                  <td className="px-2 py-1 text-right">{gbp(footer.avgPubSales)}</td>
                  <td className="px-2 py-1 text-right"></td>
                  <td className="px-2 py-1 text-right" colSpan={2}></td>
                  <td className="px-2 py-1 text-right">{gbp(footer.avgCafeSales)}</td>
                  <td className="px-2 py-1 text-right"></td>
                  <td className="px-2 py-1 text-right">{gbp(footer.avgSales)}</td>
                  <td className="px-2 py-1 text-right">{gbp(footer.avgLabour)}</td>
                  <td className="px-2 py-1 text-right">{footer.labourPct?.toFixed(1) ?? '—'}%</td>
                  <td className="px-2 py-1 text-right">COGS {footer.cogsPct?.toFixed(1) ?? '—'}%</td>
                </tr>
              </tfoot>
            </table>
          </div>
          <p className="mt-2 text-sm text-ink-500">
            COGS is overall (xero contacts not yet site-categorised). Pub labour % = pub labour ÷ pub total.
            Café labour % = cafe labour ÷ cafe total. Combined labour % = total labour ÷ (pub + cafe).
            Pub totals include accommodation (recorded through pub till).
          </p>"""

content = content.replace(old_table_section, new_table_section)

with open(path, "w") as f:
    f.write(content)

print("Written OK")
print(f"Final size: {len(content)} chars, {content.count(chr(10))+1} lines")
