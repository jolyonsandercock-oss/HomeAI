#!/usr/bin/env python3
"""Replace email section on comms page with flagged emails + keyword management."""

path = "/home_ai/services/homeai-frontend/app/comms/page.tsx"

with open(path) as f:
    content = f.read()

# 1. Add priority email fetch
old_hooks = """  const email  = useSlug<EmailKpis>('work_email_kpis', {}, { refetchInterval: 5 * 60_000 });"""
new_hooks = """  const email    = useSlug<EmailKpis>('work_email_kpis', {}, { refetchInterval: 5 * 60_000 });
  const flagged  = useSlug<any>('dashboard_email_priority', {}, { refetchInterval: 5 * 60_000 });
  const [showAddKeyword, setShowAddKeyword] = useState(false);
  const [newKeyword, setNewKeyword] = useState('');
  const [keywordMsg, setKeywordMsg] = useState('');"""

content = content.replace(old_hooks, new_hooks)

# 2. Replace the email section
old_email = """      <SandboxWrapper id=\"comms.email\" label=\"Email summary\">
        <Section title=\"Email\">
          <div className=\"grid grid-cols-1 sm:grid-cols-3 gap-3\">
            <KPICard label=\"Email tasks open\" value={ek?.tasks_open ?? '—'} loading={email.isLoading} />
            <KPICard label=\"Bot instructions pending\" value={ek?.instructions_pending ?? '—'} loading={email.isLoading} />
            <KPICard
              label=\"Last instruction\"
              value={ek?.last_instruction_at ? new Date(ek.last_instruction_at).toLocaleString('en-GB', { day:'2-digit', month:'short', hour:'2-digit', minute:'2-digit' }) : '—'}
              loading={email.isLoading} />
          </div>
        </Section>
      </SandboxWrapper>"""

new_email = """      <SandboxWrapper id=\"comms.email\" label=\"Email summary\">
        <Section title=\"Email — flagged priority\">
          <div className=\"grid grid-cols-1 sm:grid-cols-3 gap-3 mb-4\">
            <KPICard label=\"Email tasks open\" value={ek?.tasks_open ?? '—'} loading={email.isLoading} />
            <KPICard label=\"Flagged priority\" value={flagged.data?.length ?? 0} loading={email.isLoading} />
            <KPICard label=\"Bot pending\" value={ek?.instructions_pending ?? '—'} loading={email.isLoading} />
          </div>

          <div className=\"mb-3 flex items-center gap-2 text-xs\">
            <span className=\"text-ink-500\">Priority keywords:</span>
            <button onClick={() => setShowAddKeyword(!showAddKeyword)}
              className=\"text-amber-500 hover:text-amber-400\">+ add</button>
          </div>

          {showAddKeyword && (
            <div className=\"mb-3 flex items-center gap-2 text-xs\">
              <input value={newKeyword} onChange={(e) => setNewKeyword(e.target.value)}
                placeholder=\"e.g. complaint, overdue, urgent\"
                className=\"bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1.5 flex-1\" />
              <button onClick={async () => {
                if (!newKeyword.trim()) return;
                setKeywordMsg('');
                try {
                  const res = await fetch('/app/api/keywords/email-priority', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ keyword: newKeyword.trim().toLowerCase(), label: newKeyword.trim() }),
                  });
                  const data = await res.json();
                  if (data.ok) {
                    setKeywordMsg('Added!');
                    setNewKeyword('');
                    setTimeout(() => setKeywordMsg(''), 2000);
                  } else {
                    setKeywordMsg('Error: ' + (data.error || ''));
                  }
                } catch (e: any) {
                  setKeywordMsg('Error: ' + e.message);
                }
              }} className=\"px-2 py-1.5 rounded bg-amber-500 text-ink-0 hover:bg-amber-400\">Add</button>
              {keywordMsg && <span className={'text-xs ' + (keywordMsg.startsWith('Error') ? 'text-warn' : 'text-green-400')}>{keywordMsg}</span>}
            </div>
          )}

          <div className=\"tile overflow-x-auto\">
            {flagged.isLoading ? (
              <PlaceholderState message=\"Loading flagged emails…\" />
            ) : (flagged.data ?? []).length === 0 ? (
              <PlaceholderState message=\"No flagged priority emails.\" />
            ) : (
              <table className=\"w-full text-xs\">
                <thead className=\"text-ink-500 uppercase tracking-wider\">
                  <tr>
                    <th className=\"text-left py-1.5\">Flag</th>
                    <th className=\"text-left\">Subject</th>
                    <th className=\"text-left\">From</th>
                    <th className=\"text-right\">Sev</th>
                    <th className=\"text-right\">Score</th>
                    <th className=\"text-right\">Date</th>
                  </tr>
                </thead>
                <tbody>
                  {(flagged.data ?? []).map((e: any) => (
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
                  ))}
                </tbody>
              </table>
            )}
          </div>
        </Section>
      </SandboxWrapper>"""

content = content.replace(old_email, new_email)

with open(path, "w") as f:
    f.write(content)

print("Done")
