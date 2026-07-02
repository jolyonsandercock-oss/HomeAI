#!/usr/bin/env python3
"""Apply all chart fixes to sales/page.tsx and café colors site-wide."""

# 1. Patch the chart in sales/page.tsx
import re

path = "/home_ai/services/homeai-frontend/app/sales/page.tsx"

with open(path) as f:
    content = f.read()

# --- Chart section replacement ---
old_chart = """                const enriched = chartData.map(d => {
                  const total = num(d.pub_income) + num(d.cafe_income);
                  const labour = num(d.labour_cost);
                  return {
                    ...d,
                    total_income: String(total),
                    labour_pct: total > 0 ? Number((labour / total * 100).toFixed(1)) : null,
                  };
                });
                return (
              <ResponsiveContainer width="100%" height="100%">
                <ComposedChart data={enriched} margin={{ top: 8, right: 24, left: 8, bottom: 8 }}>
                  <CartesianGrid stroke="#2a2a2a" vertical={false} />
                  <XAxis dataKey="day" stroke="#737373" fontSize={10} tickFormatter={(d) => d.slice(5)} />
                  <YAxis yAxisId="left" stroke="#737373" fontSize={11} tickFormatter={(v) => `\u00a3${v}`} />
                  <YAxis yAxisId="right" orientation="right" stroke="#ef4444" fontSize={11} tickFormatter={(v) => `${v}%`} domain={[0, 'auto']} />
                  <Tooltip contentStyle={{ background: '#171717', border: '1px solid #2a2a2a' }}
                    formatter={(v: number, name: string) => {
                      if (name === 'labour_pct') return [`${v.toFixed(1)}%`, 'Labour %'];
                      return [gbp(v), name];
                    }} />
                  <Legend wrapperStyle={{ fontSize: 11 }} />
                  <Bar yAxisId="left" dataKey="pub_income"  stackId="inc" fill="#f59e0b" name="Pub income" />
                  <Bar yAxisId="left" dataKey="cafe_income" stackId="inc" fill="#fbbf24" name="Caf\u00e9 income" />
                  <Line yAxisId="left" type="monotone" dataKey="labour_cost" stroke="#22d3ee" strokeWidth={2} dot={false} name="Labour cost" />
                  <Line yAxisId="right" type="monotone" dataKey="labour_pct" stroke="#ef4444" strokeWidth={2} dot={false} strokeDasharray="4 3" name="Labour %" />
                </ComposedChart>
              </ResponsiveContainer>
                );"""

new_chart = """                const enriched = chartData.map(d => {
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
                });
                return (
              <ResponsiveContainer width="100%" height="100%">
                <ComposedChart data={enriched} margin={{ top: 8, right: 24, left: 8, bottom: 8 }}>
                  <CartesianGrid stroke="#2a2a2a" vertical={false} />
                  <XAxis dataKey="day" stroke="#737373" fontSize={10} tickFormatter={(d) => d.slice(5)} />
                  <YAxis yAxisId="left" stroke="#737373" fontSize={11} tickFormatter={(v) => `\u00a3${v}`} />
                  <YAxis yAxisId="right" orientation="right" stroke="#737373" fontSize={11} tickFormatter={(v) => `${v}%`} domain={[10, 'auto']} />
                  <Tooltip contentStyle={{ background: '#171717', border: '1px solid #2a2a2a' }}
                    formatter={(v: number, name: string) => {
                      if (name === 'Labour %') return [`${v.toFixed(1)}%`, 'Labour %'];
                      if (name === 'lpct_green' || name === 'lpct_orange' || name === 'lpct_red') return null;
                      return [gbp(v), name];
                    }} />
                  <Legend wrapperStyle={{ fontSize: 11 }} />
                  <ReferenceLine yAxisId="right" y={30} stroke="#22c55e" strokeDasharray="3 3" strokeWidth={1} />
                  <ReferenceLine yAxisId="right" y={32} stroke="#f97316" strokeDasharray="3 3" strokeWidth={1} />
                  <Bar yAxisId="left" dataKey="pub_income"  stackId="inc" fill="#f59e0b" name="Pub income" />
                  <Bar yAxisId="left" dataKey="cafe_income" stackId="inc" fill="#ec4899" name="Caf\u00e9 income" />
                  <Line yAxisId="left" type="monotone" dataKey="labour_cost" stroke="#22d3ee" strokeWidth={2} dot={false} name="Labour cost" />
                  <Line yAxisId="right" type="monotone" dataKey="lpct_green" stroke="#22c55e" strokeWidth={2} dot={false} name="Labour %" connectNulls={false} />
                  <Line yAxisId="right" type="monotone" dataKey="lpct_orange" stroke="#f97316" strokeWidth={2} dot={false} name="Labour %" connectNulls={false} />
                  <Line yAxisId="right" type="monotone" dataKey="lpct_red" stroke="#ef4444" strokeWidth={2} dot={false} name="Labour %" connectNulls={false} />
                </ComposedChart>
              </ResponsiveContainer>
                );"""

count = content.count(old_chart)
print(f"Chart section: found {count} occurrence(s)")
if count == 1:
    content = content.replace(old_chart, new_chart)
else:
    print("ERROR finding chart section")
    sys.exit(1)

# --- CAT_COLOR: Ice Cream = pink ---
content = content.replace(
    "'Ice Cream': '#f59e0b'",
    "'Ice Cream': '#ec4899'"
)
content = content.replace(
    "'Ice Cream': '#f59e0b', Other: '#737373'",
    "'Ice Cream': '#ec4899', Other: '#737373'"
)

with open(path, "w") as f:
    f.write(content)
print("sales/page.tsx patched OK")


# 2. Café page — hot drinks from amber to pink
cafe_path = "/home_ai/services/homeai-frontend/app/cafe/page.tsx"
with open(cafe_path) as f:
    cafe_content = f.read()

cafe_content = cafe_content.replace(
    "'HOT DRINKS':       '#f59e0b'",
    "'HOT DRINKS':       '#ec4899'"
)
with open(cafe_path, "w") as f:
    f.write(cafe_content)
print("cafe/page.tsx patched OK")


# 3. Waterfall.tsx — stroke from amber to pink
wf_path = "/home_ai/services/homeai-frontend/components/ui/Waterfall.tsx"
with open(wf_path) as f:
    wf_content = f.read()

wf_content = wf_content.replace(
    "stroke={b.sub ? '#fbbf24' : 'none'}",
    "stroke={b.sub ? '#ec4899' : 'none'}"
)
with open(wf_path, "w") as f:
    f.write(wf_content)
print("Waterfall.tsx patched OK")

print("\nAll patches applied successfully")
