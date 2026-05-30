#!/usr/bin/env python3
"""Redesign the dashboard email section with grouped keyword cards."""

path = "/home_ai/services/homeai-frontend/app/page.tsx"

with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# The old email section — from <SandboxWrapper id="dashboard.email" to the </SandboxWrapper> before manual-uploads
old_start = '<SandboxWrapper id="dashboard.email" label="Email tasks">'
old_end = '</SandboxWrapper>\n        <SandboxWrapper id="dashboard.manual-uploads"'

idx_start = content.find(old_start)
idx_end = content.find(old_end)
if idx_start < 0 or idx_end < 0:
    print(f"ERROR: markers not found. start={idx_start}, end={idx_end}")
    # Find the manual uploads to locate the boundary
    mu = content.find('SandboxWrapper id="dashboard.manual-uploads"')
    email = content.find('SandboxWrapper id="dashboard.email"')
    print(f"email at {email}, manual-uploads at {mu}")
    # Find the closing </SandboxWrapper> before manual-uploads
    between = content[email:mu]
    last_close = between.rfind('</SandboxWrapper>')
    print(f"last </SandboxWrapper> before manual-uploads at {email + last_close}")
    idx_start = email
    idx_end = email + last_close + len('</SandboxWrapper>')

print(f"Replacing from {idx_start} to {idx_end}")

new_section = '''        <SandboxWrapper id="dashboard.email" label="Email tasks">
          <Section title="Email tasks">
            <div className="tile">
              <div className="flex items-center justify-between mb-3">
                <div>
                  <div className="label">Total flagged</div>
                  <div className="kpi-xl mt-1">{emailKpis.data?.[0]?.tasks_open ?? '\\u2014'}</div>
                </div>
                <div className="text-right text-xs text-ink-500">
                  <div>{emailKpis.data?.[0]?.instructions_pending ?? 0} bot pending</div>
                  <div className="font-semibold text-warn">{priorityEmail.data?.length ?? 0} need action</div>
                </div>
              </div>
              <div className="grid grid-cols-2 gap-2 mb-3">
                {(() => {
                  const byKw: Record<string, { items: any[]; maxSev: number }> = {};
                  for (const e of priorityEmail.data ?? []) {
                    const kw = e.matched_keyword || 'other';
                    if (!byKw[kw]) byKw[kw] = { items: [], maxSev: 0 };
                    byKw[kw].items.push(e);
                    if (e.severity > byKw[kw].maxSev) byKw[kw].maxSev = e.severity;
                  }
                  const kwOrder = ['urgent', 'complaint', 'overdue', 'dissatisfied', 'salary', 'credit control', 'final reminder'];
                  const sorted = Object.entries(byKw).sort(([a], [b]) => {
                    const ia = kwOrder.indexOf(a), ib = kwOrder.indexOf(b);
                    return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib);
                  });
                  return sorted.map(([kw, info]) => (
                    <div key={kw} className={'rounded px-2 py-1.5 border ' + (
                      info.maxSev >= 5 ? 'bg-red-900/20 border-red-800/40' :
                      info.maxSev >= 4 ? 'bg-orange-900/20 border-orange-800/40' :
                      'bg-amber-900/15 border-amber-800/30'
                    )}>
                      <div className={'text-2xs uppercase tracking-wider font-medium ' + (
                        info.maxSev >= 5 ? 'text-red-400' :
                        info.maxSev >= 4 ? 'text-orange-400' : 'text-amber-400'
                      )}>{kw}</div>
                      <div className="flex items-baseline gap-1 mt-0.5">
                        <span className="text-sm font-bold text-ink-900">{info.items.length}</span>
                        <span className="text-2xs text-ink-500">open</span>
                      </div>
                      <div className="text-2xs text-ink-500 truncate mt-0.5" title={info.items.map((i: any) => i.subject).join(' | ')}>
                        {info.items[0]?.subject.slice(0, 40) || ''}
                      </div>
                    </div>
                  ));
                })()}
              </div>
              <Link href="/comms" className="block text-sm text-amber-500 hover:text-amber-400 font-medium">
                \\u2192 Manage all flagged emails &rarr;
              </Link>
            </div>
          </Section>
        </SandboxWrapper>'''

content = content[:idx_start] + new_section + content[idx_end:]

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Done")
