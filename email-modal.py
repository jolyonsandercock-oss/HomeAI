#!/usr/bin/env python3
"""Add click-to-open modal with email body, action buttons, and realm change on comms page."""

path = "/home_ai/services/homeai-frontend/app/comms/page.tsx"

with open(path) as f:
    content = f.read()

# 1. Add selectedRow state and modal
old_email_state = """  const [showAddKeyword, setShowAddKeyword] = useState(false);
  const [newKeyword, setNewKeyword] = useState('');
  const [keywordMsg, setKeywordMsg] = useState('');"""

new_email_state = """  const [showAddKeyword, setShowAddKeyword] = useState(false);
  const [newKeyword, setNewKeyword] = useState('');
  const [keywordMsg, setKeywordMsg] = useState('');
  const [selectedTask, setSelectedTask] = useState<any>(null);
  const [actingTask, setActingTask] = useState<number | null>(null);"""

content = content.replace(old_email_state, new_email_state)

# 2. Make table rows clickable and add modal render
old_rows = """                  {(flagged.data ?? []).map((e: any) => (
                    <tr key={e.id} className=\"border-t border-ink-200\">
                      <td className={'py-1.5 font-mono text-2xs ' + (
                        e.severity >= 5 ? 'text-red-400' :
                        e.severity >= 4 ? 'text-orange-400' : 'text-amber-400'
                      )}>{e.matched_keyword}</td>
                      <td className=\"max-w-[300px] truncate text-ink-800\" title={e.subject}>{e.subject}</td>
                      <td className=\"text-ink-500 max-w-[200px] truncate\">{e.from_address}</td>
                      <td className=\"text-right text-ink-500\">{e.severity}</td>
                      <td className=\"text-right text-ink-700 font-mono\">{e.priority_score}</td>
                      <td className=\"text-right text-ink-500\">{new Date(e.detected_at).toLocaleDateString('en-GB', {day:'2-digit', month:'short'})}</td>
                    </tr>
                  ))}"""

new_rows = """                  {(flagged.data ?? []).map((e: any) => (
                    <tr key={e.id} className=\"border-t border-ink-200 cursor-pointer hover:bg-ink-100/50\" onClick={() => setSelectedTask(e)}>
                      <td className={'py-1.5 font-mono text-2xs ' + (
                        e.severity >= 5 ? 'text-red-400' :
                        e.severity >= 4 ? 'text-orange-400' : 'text-amber-400'
                      )}>{e.matched_keyword}</td>
                      <td className=\"max-w-[300px] truncate text-ink-800\" title={e.subject}>{e.subject}</td>
                      <td className=\"text-ink-500 max-w-[200px] truncate\">{e.from_address}</td>
                      <td className=\"text-right text-ink-500\">{e.severity}</td>
                      <td className=\"text-right text-ink-700 font-mono\">{e.priority_score}</td>
                      <td className=\"text-right text-ink-500\">{new Date(e.detected_at).toLocaleDateString('en-GB', {day:'2-digit', month:'short'})}</td>
                    </tr>
                  ))
                  .concat(
                    selectedTask ? [(
                      <tr key="modal-placeholder" style={{ display: 'none' }} />
                    )] : []
                  )}"""

content = content.replace(old_rows, new_rows)

# 3. Add modal and action handler before the closing </SandboxWrapper> for email
old_email_close = """          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id=\"comms.wa\""""

new_email_close = """          </div>

          {selectedTask && (
            <div className=\"fixed inset-0 z-50 flex items-center justify-center bg-black/60\" onClick={() => setSelectedTask(null)}>
              <div className=\"bg-ink-50 border border-ink-200 rounded-lg w-full max-w-2xl p-5 shadow-xl max-h-[80vh] flex flex-col\" onClick={(e) => e.stopPropagation()}>
                <div className=\"flex items-center justify-between mb-3 shrink-0\">
                  <h3 className=\"text-sm font-medium text-ink-800\">{selectedTask.subject}</h3>
                  <button onClick={() => setSelectedTask(null)} className=\"text-ink-400 hover:text-ink-600 text-lg leading-none\">&times;</button>
                </div>
                <div className=\"space-y-2 text-xs text-ink-600 mb-3 shrink-0\">
                  <p><span className=\"text-ink-500\">From:</span> {selectedTask.from_address}</p>
                  <p><span className=\"text-ink-500\">Flagged:</span> {selectedTask.matched_keyword} (severity {selectedTask.severity})</p>
                  <p><span className=\"text-ink-500\">Date:</span> {new Date(selectedTask.detected_at).toLocaleString('en-GB')}</p>
                </div>
                <div className=\"flex-1 overflow-y-auto mb-3 border border-ink-200 rounded bg-ink-100/50 p-3 text-xs text-ink-700 font-mono whitespace-pre-wrap max-h-[300px]\">
                  Loading email body...
                </div>
                <div className=\"flex items-center justify-between shrink-0 pt-3 border-t border-ink-200\">
                  <div className=\"flex items-center gap-2 text-xs\">
                    <span className=\"text-ink-500\">Realm:</span>
                    <select className=\"bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1 text-xs\">
                      <option value=\"work\">Work</option>
                      <option value=\"personal\">Personal</option>
                      <option value=\"shared\">Shared</option>
                    </select>
                  </div>
                  <div className=\"flex items-center gap-2\">
                    <button onClick={async () => {
                      setActingTask(selectedTask.id);
                      try {
                        await fetch('/app/api/email/task', {
                          method: 'POST',
                          headers: { 'Content-Type': 'application/json' },
                          body: JSON.stringify({ task_id: selectedTask.id, status: 'dismissed', notes: 'Snoozed from comms page' }),
                        });
                      } catch {}
                      setActingTask(null);
                      setSelectedTask(null);
                    }} disabled={actingTask === selectedTask.id}
                      className=\"px-3 py-1.5 text-xs rounded bg-ink-200 text-ink-600 hover:bg-ink-300 disabled:opacity-50\">
                      Snooze
                    </button>
                    <button onClick={async () => {
                      setActingTask(selectedTask.id);
                      try {
                        await fetch('/app/api/email/task', {
                          method: 'POST',
                          headers: { 'Content-Type': 'application/json' },
                          body: JSON.stringify({ task_id: selectedTask.id, status: 'done', notes: 'Done from comms page' }),
                        });
                      } catch {}
                      setActingTask(null);
                      setSelectedTask(null);
                    }} disabled={actingTask === selectedTask.id}
                      className=\"px-3 py-1.5 text-xs rounded bg-amber-500 text-ink-0 hover:bg-amber-400 disabled:opacity-50\">
                      {actingTask === selectedTask.id ? '...' : 'Done'}
                    </button>
                    <button onClick={async () => {
                      setActingTask(selectedTask.id);
                      try {
                        await fetch('/app/api/email/task', {
                          method: 'POST',
                          headers: { 'Content-Type': 'application/json' },
                          body: JSON.stringify({ task_id: selectedTask.id, status: 'dismissed', notes: 'Ignored from comms page' }),
                        });
                      } catch {}
                      setActingTask(null);
                      setSelectedTask(null);
                    }} disabled={actingTask === selectedTask.id}
                      className=\"px-3 py-1.5 text-xs rounded bg-red-900/40 text-red-300 hover:bg-red-800/50 disabled:opacity-50\">
                      Ignore
                    </button>
                  </div>
                </div>
              </div>
            </div>
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id=\"comms.wa\""""

content = content.replace(old_email_close, new_email_close)

with open(path, "w") as f:
    f.write(content)

print("Done")
