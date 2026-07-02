#!/usr/bin/env python3
"""Revert 3-segment labour% line to single line, keep green ref line at 30%."""

path = "/home_ai/services/homeai-frontend/app/sales/page.tsx"

with open(path) as f:
    content = f.read()

# Replace the enriched map — remove the 3 split fields, keep labour_pct
old_enrich = """const enriched = chartData.map(d => {
                  const total = num(d.pub_income) + num(d.cafe_income);
                  const labour = num(d.labour_cost);
                  const pct = total > 0 ? Number((labour / total * 100).toFixed(1)) : null;
                  return {
                    ...d,
                    total_income: String(total),
                    labour_pct: pct,
                    // Split into 3 colour-coded series for the line
                    lpct_green:  pct != null && pct < 30  ? pct : null,
                    lpct_orange: pct != null && pct >= 30 && pct <= 32 ? pct : null,
                    lpct_red:    pct != null && pct > 32  ? pct : null,
                  };
                });"""

new_enrich = """const enriched = chartData.map(d => {
                  const total = num(d.pub_income) + num(d.cafe_income);
                  const labour = num(d.labour_cost);
                  const pct = total > 0 ? Number((labour / total * 100).toFixed(1)) : null;
                  return {
                    ...d,
                    total_income: String(total),
                    labour_pct: pct,
                  };
                });"""

content = content.replace(old_enrich, new_enrich)

# Replace the tooltip — remove the 3-segment suppression, keep labour_pct
old_tooltip = """<Tooltip contentStyle={{ background: '#171717', border: '1px solid #2a2a2a' }}
                    formatter={(v: number, name: string) => {
                      if (name === 'Labour %') return [`${v.toFixed(1)}%`, 'Labour %'];
                      if (name === 'lpct_green' || name === 'lpct_orange' || name === 'lpct_red') return null;
                      return [gbp(v), name];
                    }} />"""

new_tooltip = """<Tooltip contentStyle={{ background: '#171717', border: '1px solid #2a2a2a' }}
                    formatter={(v: number, name: string) => {
                      if (name === 'labour_pct') return [`${v.toFixed(1)}%`, 'Labour %'];
                      return [gbp(v), name];
                    }} />"""

content = content.replace(old_tooltip, new_tooltip)

# Remove the orange reference line at 32, keep green at 30
content = content.replace(
    "                  <ReferenceLine yAxisId=\"right\" y={30} stroke=\"#22c55e\" strokeDasharray=\"3 3\" strokeWidth={1} />\n                  <ReferenceLine yAxisId=\"right\" y={32} stroke=\"#f97316\" strokeDasharray=\"3 3\" strokeWidth={1} />\n",
    "                  <ReferenceLine yAxisId=\"right\" y={30} stroke=\"#22c55e\" strokeDasharray=\"3 3\" strokeWidth={1} />\n"
)

# Replace the 3 lines with 1 single line for labour_pct
old_lines = """<Line yAxisId=\"left\" type=\"monotone\" dataKey=\"labour_cost\" stroke=\"#22d3ee\" strokeWidth={2} dot={false} name=\"Labour cost\" />
                  <Line yAxisId=\"right\" type=\"monotone\" dataKey=\"lpct_green\" stroke=\"#22c55e\" strokeWidth={2} dot={false} name=\"Labour %\" connectNulls={false} />
                  <Line yAxisId=\"right\" type=\"monotone\" dataKey=\"lpct_orange\" stroke=\"#f97316\" strokeWidth={2} dot={false} name=\"Labour %\" connectNulls={false} />
                  <Line yAxisId=\"right\" type=\"monotone\" dataKey=\"lpct_red\" stroke=\"#ef4444\" strokeWidth={2} dot={false} name=\"Labour %\" connectNulls={false} />"""

new_lines = """<Line yAxisId=\"left\" type=\"monotone\" dataKey=\"labour_cost\" stroke=\"#22d3ee\" strokeWidth={2} dot={false} name=\"Labour cost\" />
                  <Line yAxisId=\"right\" type=\"monotone\" dataKey=\"labour_pct\" stroke=\"#ef4444\" strokeWidth={2} dot={false} strokeDasharray=\"4 3\" name=\"Labour %\" />"""

content = content.replace(old_lines, new_lines)

with open(path, "w") as f:
    f.write(content)

# Verify no trace of lpct_ left
if "lpct_" in content:
    print("WARNING: leftover lpct_ references!")
else:
    print("All clean — no lpct_ references remain")
    
print("Patched OK")
