#!/usr/bin/env python3
"""Replace email section on dashboard with keyword-grouped cards."""

path = "/home_ai/services/homeai-frontend/app/page.tsx"

with open(path) as f:
    lines = f.readlines()

old_start = 599  # 0-indexed, this is </SandboxWrapper> closing the previous section
# Find the exact lines
email_start = None
email_end = None
for i, line in enumerate(lines):
    if 'id="dashboard.email"' in line:
        email_start = i
    if email_start and '</SandboxWrapper>' in line and i > (email_start or 0):
        # First closing SandboxWrapper after email start
        if email_end is None:
            email_end = i + 1  # include the </SandboxWrapper> line
            break

print(f"Email section: lines {email_start+1} to {email_end}")

# Build replacement lines
new_lines = [
    '        <SandboxWrapper id="dashboard.email" label="Email tasks">\n',
    '          <Section title="Email tasks">\n',
    '            <div className="tile">\n',
    '              <div className="flex items-center justify-between mb-3">\n',
    '                <div>\n',
    '                  <div className="label">Total flagged</div>\n',
    '                  <div className="kpi-xl mt-1">{emailKpis.data?.[0]?.tasks_open ?? \'\u2014\'}</div>\n',
    '                </div>\n',
    '                <div className="text-right text-xs text-ink-500">\n',
    '                  <div>{emailKpis.data?.[0]?.instructions_pending ?? 0} bot pending</div>\n',
    '                  <div className="font-semibold text-warn">{priorityEmail.data?.length ?? 0} need action</div>\n',
    '                </div>\n',
    '              </div>\n',
    '              <div className="grid grid-cols-2 gap-2 mb-3">\n',
    '                {(() => {\n',
    '                  const byKw: Record<string, { items: any[]; maxSev: number }> = {};\n',
    '                  for (const e of priorityEmail.data ?? []) {\n',
    '                    const kw = e.matched_keyword || \'other\';\n',
    '                    if (!byKw[kw]) byKw[kw] = { items: [], maxSev: 0 };\n',
    '                    byKw[kw].items.push(e);\n',
    '                    if (e.severity > byKw[kw].maxSev) byKw[kw].maxSev = e.severity;\n',
    '                  }\n',
    '                  const kwOrder = [\'urgent\', \'complaint\', \'overdue\', \'dissatisfied\', \'salary\', \'credit control\', \'final reminder\'];\n',
    '                  const sorted = Object.entries(byKw).sort(([a], [b]) => {\n',
    '                    const ia = kwOrder.indexOf(a), ib = kwOrder.indexOf(b);\n',
    '                    return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib);\n',
    '                  });\n',
    '                  return sorted.map(([kw, info]) => (\n',
    '                    <div key={kw} className={\'rounded px-2 py-1.5 border \' + (\n',
    '                      info.maxSev >= 5 ? \'bg-red-900/20 border-red-800/40\' :\n',
    '                      info.maxSev >= 4 ? \'bg-orange-900/20 border-orange-800/40\' :\n',
    '                      \'bg-amber-900/15 border-amber-800/30\'\n',
    '                    )}>\n',
    '                      <div className={\'text-2xs uppercase tracking-wider font-medium \' + (\n',
    '                        info.maxSev >= 5 ? \'text-red-400\' :\n',
    '                        info.maxSev >= 4 ? \'text-orange-400\' : \'text-amber-400\'\n',
    '                      )}>{kw}</div>\n',
    '                      <div className="flex items-baseline gap-1 mt-0.5">\n',
    '                        <span className="text-sm font-bold text-ink-900">{info.items.length}</span>\n',
    '                        <span className="text-2xs text-ink-500">open</span>\n',
    '                      </div>\n',
    '                      <div className="text-2xs text-ink-500 truncate mt-0.5" title={info.items.map((i: any) => i.subject).join(\' | \')}>\n',
    '                        {info.items[0]?.subject.slice(0, 40) || \'\'}\n',
    '                      </div>\n',
    '                    </div>\n',
    '                  ));\n',
    '                })()}\n',
    '              </div>\n',
    '              <Link href="/comms" className="block text-sm text-amber-500 hover:text-amber-400 font-medium">\n',
    '                \u2192 Manage all flagged emails\n',
    '              </Link>\n',
    '            </div>\n',
    '          </Section>\n',
    '        </SandboxWrapper>\n',
]

# Replace
old_lines = lines[email_start:email_end]
lines[email_start:email_end] = new_lines

with open(path, 'w') as f:
    f.writelines(lines)

print(f"Replaced {len(old_lines)} lines with {len(new_lines)} lines")
