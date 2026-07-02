#!/usr/bin/env python3
"""Add snag inbox section to Tasks page."""

path = "/home_ai/services/homeai-frontend/app/tasks/page.tsx"

with open(path) as f:
    content = f.read()

# 1. Add SnagRow interface near the other interfaces
content = content.replace(
    "interface ExpenseExceptionRow {",
    "interface SnagRow { id: number; title: string; description: string | null; image_path: string | null; category: string; priority: number; status: string; source: string; submitted_by: string | null; created_at: string }\n\ninterface ExpenseExceptionRow {"
)

# 2. Add snag fetching hook after the expense exceptions fetch (inside ExpenseExceptionSection or at the page level)
# Find the ExpenseExceptionSection function and add before it
content = content.replace(
    "function ExpenseExceptionSection() {",
    "function SnagInboxSection() {\n  const snags = useSlug<SnagRow>('snag_inbox_pending', {}, { refetchInterval: 60_000 });\n  const [actingId, setActingId] = useState<number | null>(null);\n\n  const counts = { pending: (snags.data ?? []).filter(s => s.status === 'pending').length, accepted: (snags.data ?? []).filter(s => s.status === 'accepted').length, in_progress: (snags.data ?? []).filter(s => s.status === 'in_progress').length };\n\n  const handleStatus = async (id: number, status: string) => {\n    setActingId(id);\n    try { await fetch('/app/api/snag/status', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id, status }) }); } catch {}\n    setActingId(null);\n  };\n\n  return (\n    <>\n      {snags.isLoading ? (\n        <PlaceholderState message=\"Loading snag inbox\\u2026\" />\n      ) : (snags.data ?? []).length === 0 ? (\n        <PlaceholderState message=\"Snag inbox empty \\u2014 all clear!\" />\n      ) : (\n        <>\n          <div className=\"grid grid-cols-3 gap-2 mb-3 text-xs\">\n            <div className=\"bg-ink-100 rounded px-2 py-1 text-center\"><span className=\"text-amber-400 font-bold\">{counts.pending}</span> pending</div>\n            <div className=\"bg-ink-100 rounded px-2 py-1 text-center\"><span className=\"text-blue-400 font-bold\">{counts.in_progress}</span> in progress</div>\n            <div className=\"bg-ink-100 rounded px-2 py-1 text-center\"><span className=\"text-ink-500 font-bold\">{counts.accepted}</span> accepted</div>\n          </div>\n          <div className=\"tile overflow-x-auto text-xs\">\n            <table className=\"w-full\">\n              <thead className=\"text-ink-500 uppercase tracking-wider\">\n                <tr>\n                  <th className=\"text-left py-1.5\">P</th>\n                  <th className=\"text-left\">Title</th>\n                  <th className=\"text-left\">Category</th>\n                  <th className=\"text-right\">Source</th>\n                  <th className=\"text-right\">Actions</th>\n                </tr>\n              </thead>\n              <tbody>\n                {(snags.data ?? []).map(s => (\n                  <tr key={s.id} className=\"border-t border-ink-200\">\n                    <td className={'py-1.5 font-bold ' + (s.priority <= 2 ? 'text-red-400' : s.priority <= 3 ? 'text-amber-400' : 'text-ink-500')}>P{s.priority}</td>\n                    <td className=\"text-ink-800 max-w-[300px] truncate\" title={s.title}>{s.title}</td>\n                    <td className=\"text-ink-500\">{s.category}</td>\n                    <td className=\"text-right text-ink-500\">{s.source}</td>\n                    <td className=\"text-right\">\n                      <div className=\"flex items-center justify-end gap-1\">\n                        <button onClick={() => handleStatus(s.id, 'accepted')} disabled={actingId === s.id || s.status !== 'pending'}\n                          className=\"px-2 py-0.5 text-2xs rounded bg-blue-900/30 text-blue-400 hover:bg-blue-900/50 disabled:opacity-30\">Accept</button>\n                        <button onClick={() => handleStatus(s.id, 'done')} disabled={actingId === s.id}\n                          className=\"px-2 py-0.5 text-2xs rounded bg-amber-500 text-ink-0 hover:bg-amber-400 disabled:opacity-30\">Done</button>\n                        <button onClick={() => handleStatus(s.id, 'wontfix')} disabled={actingId === s.id}\n                          className=\"px-2 py-0.5 text-2xs rounded bg-red-900/30 text-red-400 hover:bg-red-900/50 disabled:opacity-30\">Skip</button>\n                      </div>\n                    </td>\n                  </tr>\n                ))}\n              </tbody>\n            </table>\n          </div>\n        </>\n      )}\n    </>\n  );\n}\n\nfunction ExpenseExceptionSection() {"
)

# 3. Add the snag inbox SandboxWrapper before the closing </div>
# Find the closing </div> after the AssignModal
old_close = "      {selectedRow && <AssignModal row={selectedRow} onClose={() => setSelectedRow(null)} />}\n    </div>\n  );\n}"

new_close = "      {selectedRow && <AssignModal row={selectedRow} onClose={() => setSelectedRow(null)} />}\n\n      <SandboxWrapper id=\"tasks.snag-inbox\" label=\"Snag inbox\">\n        <Section title={`Snag inbox \\u2014 improvements, complaints, UX feedback`}>\n          <SnagInboxSection />\n        </Section>\n      </SandboxWrapper>\n    </div>\n  );\n}"

content = content.replace(old_close, new_close)

with open(path, "w") as f:
    f.write(content)

print("Done" if "SnagInboxSection" in content else "ERROR")
