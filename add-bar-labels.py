#!/usr/bin/env python3
"""Add value labels + percentages to category breakdown bars."""

path = "/home_ai/services/homeai-frontend/app/sales/page.tsx"

with open(path) as f:
    content = f.read()

# 1. Add LabelList to imports
old_import = "BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid, Cell,"
new_import = "BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid, Cell, LabelList,"
content = content.replace(old_import, new_import)

# 2. Add LabelList inside the Bar component, showing both £value and percentage
# The data has {label, total, category} — we need to compute percentage from grand total
old_bar = """                  <Bar dataKey=\"total\">
                    {catChart.map((d, i) => <Cell key={i} fill={CAT_COLOR[d.category] ?? '#f59e0b'} />)}
                  </Bar>"""

new_bar = """                  <Bar dataKey=\"total\" minPointSize={2}>
                    {catChart.map((d, i) => <Cell key={i} fill={CAT_COLOR[d.category] ?? '#f59e0b'} />)}
                    <LabelList dataKey=\"total\" position=\"right\" fontSize={11}
                      formatter={(v: number) => `${gbp(v).replace('£', '£')}`} />
                  </Bar>"""

content = content.replace(old_bar, new_bar)

# 3. Add a percentage annotation below the chart showing the split
old_chart_end = """                </BarChart>
              </ResponsiveContainer>
            </figure>"""

new_chart_end = """                </BarChart>
              </ResponsiveContainer>
              <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-xs text-ink-500">
                {catChart.map((d) => {
                  const pct = cat.data && cat.data.length > 0
                    ? ((d.total / cat.data.reduce((a: number, r: any) => a + num(r.total), 0)) * 100).toFixed(1)
                    : null;
                  return pct ? (
                    <span key={d.label} className="inline-flex items-center gap-1">
                      <span className="w-2 h-2 rounded-full inline-block" style={{ backgroundColor: CAT_COLOR[d.category] ?? '#f59e0b' }}></span>
                      {d.label.split(' · ')[1]}: <strong>{pct}%</strong>
                    </span>
                  ) : null;
                })}
              </div>
            </figure>"""

content = content.replace(old_chart_end, new_chart_end)

with open(path, "w") as f:
    f.write(content)

print("Patched OK")
