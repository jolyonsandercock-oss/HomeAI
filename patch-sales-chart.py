#!/usr/bin/env python3
"""Patch the income-vs-labour chart to add labour% line + tab filtering."""
import sys

path = "/home_ai/services/homeai-frontend/app/sales/page.tsx"

with open(path) as f:
    content = f.read()

old = """              <ResponsiveContainer width="100%" height="100%">
                <ComposedChart data={incLab.data ?? []} margin={{ top: 8, right: 16, left: 8, bottom: 8 }}>
                  <CartesianGrid stroke="#2a2a2a" vertical={false} />
                  <XAxis dataKey="day" stroke="#737373" fontSize={10} tickFormatter={(d) => d.slice(5)} />
                  <YAxis stroke="#737373" fontSize={11} tickFormatter={(v) => `\u00a3${v}`} />
                  <Tooltip contentStyle={{ background: '#171717', border: '1px solid #2a2a2a' }} formatter={(v: number) => gbp(v)} />
                  <Legend wrapperStyle={{ fontSize: 11 }} />
                  <Bar dataKey="pub_income"  stackId="inc" fill="#f59e0b" name="Pub income" />
                  <Bar dataKey="cafe_income" stackId="inc" fill="#fbbf24" name="Caf\u00e9 income" />
                  <Line type="monotone" dataKey="labour_cost" stroke="#22d3ee" strokeWidth={2} dot={false} name="Labour cost" />
                </ComposedChart>"""

new = """              {(() => {
                const raw = incLab.data ?? [];
                const chartData = tab === 'all' ? raw
                  : raw.map(d => ({
                      ...d,
                      pub_income:  tab === 'pub'  ? d.pub_income  : '0',
                      cafe_income: tab === 'cafe' ? d.cafe_income : '0',
                    }));
                const enriched = chartData.map(d => {
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
                );
              })()}"""

count = content.count(old)
print(f"Found {count} occurrence(s)")
if count == 0:
    # Try to find the block with minor whitespace differences
    idx = content.find("ResponsiveContainer")
    if idx >= 0:
        print("Found 'ResponsiveContainer' but exact match failed. Context:")
        print(content[idx:idx+100])
    sys.exit(1)

content = content.replace(old, new)
with open(path, "w") as f:
    f.write(content)
print("Patched successfully")
