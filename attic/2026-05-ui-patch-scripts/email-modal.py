#!/usr/bin/env python3
"""
Replace the email section on comms/page.tsx with flagged email table + modal.
Uses line-number-based replacement — no string matching, no escaping issues.
"""

path = "/home_ai/services/homeai-frontend/app/comms/page.tsx"

with open(path) as f:
    lines = f.readlines()

# === Find exact boundaries ===

# 1. The email section sandbox wrapper
email_start = None
email_end = None
wa_start = None

for i, l in enumerate(lines):
    if 'id="comms.email"' in l:
        email_start = i
    if 'id="comms.wa"' in l:
        wa_start = i
        email_end = wa_start  # email section ends right before WA section

print(f"Email section: line {email_start+1} to {email_end}")
print(f"WA section starts: line {wa_start+1}")

# 2. The email KPIs fetch line (to add flagged fetch after)
email_fetch_line = None
for i, l in enumerate(lines):
    if "'work_email_kpis'" in l:
        email_fetch_line = i
        break

print(f"Email fetch at line {email_fetch_line+1}")

# 3. The searchText useState line (to add modal state after)
search_state_line = None
for i, l in enumerate(lines):
    if 'setSearchText' in l and 'useState' in l:
        search_state_line = i
        break

print(f"SearchText state at line {search_state_line+1}")

# === Build replacements ===

# --- New email section ---
new_email_section = [
    '      <SandboxWrapper id="comms.email" label="Email summary">\n',
    '        <Section title="Email \u2014 flagged priority">\n',
    '          <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 mb-4">\n',
    '            <KPICard label="Email tasks open" value={ek?.tasks_open ?? \'\u2014\'} loading={email.isLoading} />\n',
    '            <KPICard label="Flagged priority" value={flagged.data?.length ?? 0} loading={flagged.isLoading} />\n',
    '            <KPICard label="Bot pending" value={ek?.instructions_pending ?? \'\u2014\'} loading={email.isLoading} />\n',
    '          </div>\n',
    '          <div className="mb-3 flex items-center gap-2 text-xs">\n',
    '            <span className="text-ink-500">Priority keywords:</span>\n',
    '            <button onClick={() => setShowAddKeyword(!showAddKeyword)}\n',
    '              className="text-amber-500 hover:text-amber-400">+ add</button>\n',
    '          </div>\n',
    '          {showAddKeyword && (\n',
    '            <div className="mb-3 flex items-center gap-2 text-xs">\n',
    '              <input value={newKeyword} onChange={(e) => setNewKeyword(e.target.value)}\n',
    '                placeholder="e.g. complaint, overdue, urgent"\n',
    '                className="bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1.5 flex-1" />\n',
    '              <button onClick={async () => {\n',
    '                if (!newKeyword.trim()) return;\n',
    '                setKeywordMsg("");\n',
    '                try {\n',
    "                  const res = await fetch('/app/api/keywords/email-priority', {\n",
    "                    method: 'POST',\n",
    "                    headers: { 'Content-Type': 'application/json' },\n",
    '                    body: JSON.stringify({ keyword: newKeyword.trim().toLowerCase(), label: newKeyword.trim() }),\n',
    '                  });\n',
    '                  const data = await res.json();\n',
    '                  if (data.ok) {\n',
    "                    setKeywordMsg('Added!');\n",
    "                    setNewKeyword('');\n",
    "                    setTimeout(() => setKeywordMsg(''), 2000);\n",
    '                  } else {\n',
    "                    setKeywordMsg('Error: ' + (data.error || ''));\n",
    '                  }\n',
    '                } catch (e: any) {\n',
    "                  setKeywordMsg('Error: ' + e.message);\n",
    '                }\n',
    '              }} className="px-2 py-1.5 rounded bg-amber-500 text-ink-0 hover:bg-amber-400">Add</button>\n',
    "              {keywordMsg && <span className={'text-xs ' + (keywordMsg.startsWith('Error') ? 'text-warn' : 'text-green-400')}>{keywordMsg}</span>}\n",
    '            </div>\n',
    '          )}\n',
    '          <div className="tile overflow-x-auto">\n',
    '            {flagged.isLoading ? (\n',
    '              <PlaceholderState message="Loading flagged emails\u2026" />\n',
    '            ) : (flagged.data ?? []).length === 0 ? (\n',
    '              <PlaceholderState message="No flagged priority emails." />\n',
    '            ) : (\n',
    '              <table className="w-full text-xs">\n',
    '                <thead className="text-ink-500 uppercase tracking-wider">\n',
    '                  <tr>\n',
    '                    <th className="text-left py-1.5">Flag</th>\n',
    '                    <th className="text-left">Subject</th>\n',
    '                    <th className="text-left">From</th>\n',
    '                    <th className="text-right">Sev</th>\n',
    '                    <th className="text-right">Score</th>\n',
    '                    <th className="text-right">Date</th>\n',
    '                  </tr>\n',
    '                </thead>\n',
    '                <tbody>\n',
    '                  {(flagged.data ?? []).map((e: any) => (\n',
    '                    <tr key={e.id} className="border-t border-ink-200 cursor-pointer hover:bg-ink-100/50" onClick={() => setSelectedTask(e)}>\n',
    "                      <td className={'py-1.5 font-mono text-2xs ' + (\n",
    "                        e.severity >= 5 ? 'text-red-400' :\n",
    "                        e.severity >= 4 ? 'text-orange-400' : 'text-amber-400'\n",
    '                      )}>{e.matched_keyword}</td>\n',
    '                      <td className="max-w-[300px] truncate text-ink-800" title={e.subject}>{e.subject}</td>\n',
    '                      <td className="text-ink-500 max-w-[200px] truncate">{e.from_address}</td>\n',
    '                      <td className="text-right text-ink-500">{e.severity}</td>\n',
    '                      <td className="text-right text-ink-700 font-mono">{e.priority_score}</td>\n',
    "                      <td className=\"text-right text-ink-500\">{new Date(e.detected_at).toLocaleDateString('en-GB', {day:'2-digit', month:'short'})}</td>\n",
    '                    </tr>\n',
    '                  ))}\n',
    '                </tbody>\n',
    '              </table>\n',
    '            )}\n',
    '          </div>\n',
    '\n',
    '          {selectedTask && (\n',
    '            <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60" onClick={() => setSelectedTask(null)}>\n',
    '              <div className="bg-ink-50 border border-ink-200 rounded-lg w-full max-w-2xl p-5 shadow-xl max-h-[80vh] flex flex-col" onClick={(e) => e.stopPropagation()}>\n',
    '                <div className="flex items-center justify-between mb-3 shrink-0">\n',
    '                  <h3 className="text-sm font-medium text-ink-800">{selectedTask.subject}</h3>\n',
    '                  <button onClick={() => setSelectedTask(null)} className="text-ink-400 hover:text-ink-600 text-lg leading-none">&times;</button>\n',
    '                </div>\n',
    '                <div className="space-y-2 text-xs text-ink-600 mb-3 shrink-0">\n',
    '                  <p><span className="text-ink-500">From:</span> {selectedTask.from_address}</p>\n',
    '                  <p><span className="text-ink-500">Flagged:</span> {selectedTask.matched_keyword} (severity {selectedTask.severity})</p>\n',
    "                  <p><span className=\"text-ink-500\">Date:</span> {new Date(selectedTask.detected_at).toLocaleString('en-GB')}</p>\n",
    '                </div>\n',
    '                <div className="flex-1 overflow-y-auto mb-3 border border-ink-200 rounded bg-ink-100/50 p-3 text-xs text-ink-700 font-mono whitespace-pre-wrap max-h-[300px]">\n',
    "                  {selectedTask.body_text || '(no body text available)'}\n",
    '                </div>\n',
    '                <div className="flex items-center justify-between shrink-0 pt-3 border-t border-ink-200">\n',
    '                  <div className="flex items-center gap-2 text-xs">\n',
    '                    <span className="text-ink-500">Realm:</span>\n',
    '                    <select className="bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1 text-xs">\n',
    '                      <option value="work">Work</option>\n',
    '                      <option value="personal">Personal</option>\n',
    '                      <option value="shared">Shared</option>\n',
    '                    </select>\n',
    '                  </div>\n',
    '                  <div className="flex items-center gap-2">\n',
    '                    <button onClick={async () => {\n',
    '                      setActingTask(selectedTask.id);\n',
    '                      try {\n',
    "                        await fetch('/app/api/email/task', {\n",
    "                          method: 'POST',\n",
    "                          headers: { 'Content-Type': 'application/json' },\n",
    "                          body: JSON.stringify({ task_id: selectedTask.id, status: 'snoozed', notes: 'Snoozed from comms page' }),\n",
    '                        });\n',
    '                      } catch {}\n',
    '                      setActingTask(null);\n',
    '                      setSelectedTask(null);\n',
    '                    }} disabled={actingTask === selectedTask.id}\n',
    '                      className="px-3 py-1.5 text-xs rounded bg-ink-200 text-ink-600 hover:bg-ink-300 disabled:opacity-50">Snooze</button>\n',
    '                    <button onClick={async () => {\n',
    '                      setActingTask(selectedTask.id);\n',
    '                      try {\n',
    "                        await fetch('/app/api/email/task', {\n",
    "                          method: 'POST',\n",
    "                          headers: { 'Content-Type': 'application/json' },\n",
    "                          body: JSON.stringify({ task_id: selectedTask.id, status: 'done', notes: 'Done from comms page' }),\n",
    '                        });\n',
    '                      } catch {}\n',
    '                      setActingTask(null);\n',
    '                      setSelectedTask(null);\n',
    "                    }} disabled={actingTask === selectedTask.id}\n",
    "                      className=\"px-3 py-1.5 text-xs rounded bg-amber-500 text-ink-0 hover:bg-amber-400 disabled:opacity-50\">{actingTask === selectedTask.id ? '...' : 'Done'}</button>\n",
    '                    <button onClick={async () => {\n',
    '                      setActingTask(selectedTask.id);\n',
    '                      try {\n',
    "                        await fetch('/app/api/email/task', {\n",
    "                          method: 'POST',\n",
    "                          headers: { 'Content-Type': 'application/json' },\n",
    "                          body: JSON.stringify({ task_id: selectedTask.id, status: 'dismissed', notes: 'Ignored from comms page' }),\n",
    '                        });\n',
    '                      } catch {}\n',
    '                      setActingTask(null);\n',
    '                      setSelectedTask(null);\n',
    '                    }} disabled={actingTask === selectedTask.id}\n',
    '                      className="px-3 py-1.5 text-xs rounded bg-red-900/40 text-red-300 hover:bg-red-800/50 disabled:opacity-50">Ignore</button>\n',
    '                  </div>\n',
    '                </div>\n',
    '              </div>\n',
    '            </div>\n',
    '          )}\n',
    '        </Section>\n',
    '      </SandboxWrapper>\n',
]

# === Apply replacements ===

# 1. Replace email section
old_count = email_end - email_start
lines[email_start:email_end] = new_email_section
delta = len(new_email_section) - old_count
print(f"Replaced {old_count} lines with {len(new_email_section)} lines (delta={delta})")

# 2. Insert flagged fetch after email KPIs (accounting for line shift)
insert_at = email_fetch_line + 1
# If the email section replacement shifted lines before the fetch, no adjustment needed
# since the fetch is before the email section in the file
lines.insert(insert_at + 1, "  const flagged  = useSlug<any>('dashboard_email_priority', {}, { refetchInterval: 5 * 60_000 });\n")
print(f"Inserted flagged fetch after line {insert_at+1}")

# 3. Insert modal state after searchText (accounting for the insert above)
# The searchText line is after the flagged fetch insert, so refetch the line number
for i, l in enumerate(lines):
    if 'setSearchText' in l and 'useState' in l:
        search_state_line = i
        break
lines.insert(search_state_line + 1, '  const [showAddKeyword, setShowAddKeyword] = useState(false);\n')
lines.insert(search_state_line + 2, "  const [newKeyword, setNewKeyword] = useState('');\n")
lines.insert(search_state_line + 3, "  const [keywordMsg, setKeywordMsg] = useState('');\n")
lines.insert(search_state_line + 4, '  const [selectedTask, setSelectedTask] = useState<any>(null);\n')
lines.insert(search_state_line + 5, '  const [actingTask, setActingTask] = useState<number | null>(null);\n')
print(f"Inserted modal state after line {search_state_line+1}")

# === Write ===
with open(path, 'w') as f:
    f.writelines(lines)

print(f"Final line count: {len(lines)}")
print("Done")
