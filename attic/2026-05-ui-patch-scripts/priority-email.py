#!/usr/bin/env python3
"""Replace email tasks section with priority email view."""

path = "/home_ai/services/homeai-frontend/app/page.tsx"

with open(path) as f:
    content = f.read()

# 1. Add PriorityEmailSection interface + fetch
old_hooks = """  const emailKpis   = useSlug<{ tasks_open: string; instructions_pending: string; last_instruction_at: string | null }>('work_email_kpis', {}, { refetchInterval: 5 * 60_000 });"""

new_hooks = """  const emailKpis   = useSlug<{ tasks_open: string; instructions_pending: string; last_instruction_at: string | null }>('work_email_kpis', {}, { refetchInterval: 5 * 60_000 });
  const priorityEmail = useSlug<{ id: number; subject: string; task_type: string; severity: number; detected_at: string; from_address: string; matched_keyword: string; priority_score: number }>('dashboard_email_priority', {}, { refetchInterval: 5 * 60_000 });"""

content = content.replace(old_hooks, new_hooks)

# 2. Replace the Email section
old_email_section = """        <SandboxWrapper id=\"dashboard.email\" label=\"Email tasks\">
          <Section title=\"Email tasks\">
            <Link
              href=\"/comms\"
              className=\"block focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500 rounded\"
            >
              <div className=\"tile group\">
                <div className=\"label\">Open email tasks</div>
                <div className=\"kpi-xl mt-1\">{emailKpis.data?.[0]?.tasks_open ?? '—'}</div>
                <div className=\"mt-1 text-sm text-ink-500\">
                  {emailKpis.data?.[0]?.instructions_pending ?? 0} bot instructions pending
                </div>
                <div className=\"mt-2 text-sm text-amber-500 group-hover:text-amber-400\">→ Click for /comms</div>
              </div>
            </Link>
          </Section>
        </SandboxWrapper>"""

new_email_section = """        <SandboxWrapper id=\"dashboard.email\" label=\"Email tasks\">
          <Section title=\"Email tasks\">
            <div className=\"tile\">
              <div className=\"flex items-center justify-between\">
                <div>
                  <div className=\"label\">Open tasks</div>
                  <div className=\"kpi-xl mt-1\">{emailKpis.data?.[0]?.tasks_open ?? '—'}</div>
                </div>
                <div className=\"text-right text-xs text-ink-500\">
                  <div>{emailKpis.data?.[0]?.instructions_pending ?? 0} bot pending</div>
                  <div className=\"mt-1\">{priorityEmail.data?.length ?? 0} flagged</div>
                </div>
              </div>
              <div className=\"mt-3 space-y-1.5 max-h-[240px] overflow-y-auto\">
                {(priorityEmail.data ?? []).length === 0 ? (
                  <div className=\"text-xs text-ink-500 py-2\">No flagged priority emails</div>
                ) : (
                  (priorityEmail.data ?? []).slice(0, 8).map((e) => (
                    <div key={e.id} className=\"flex items-start gap-2 text-xs border-t border-ink-200 pt-1.5\">
                      <span className={\'shrink-0 px-1 py-0.5 rounded text-2xs font-medium \' + (
                        e.severity >= 5 ? \'bg-red-900/50 text-red-300\' :
                        e.severity >= 4 ? \'bg-orange-900/40 text-orange-300\' :
                        \'bg-amber-900/30 text-amber-300\'
                      )}>{e.matched_keyword}</span>
                      <div className=\"min-w-0 flex-1\">
                        <div className=\"text-ink-800 truncate\" title={e.subject}>{e.subject}</div>
                        <div className=\"text-ink-500 mt-0.5\">{e.from_address}</div>
                      </div>
                    </div>
                  ))
                )}
              </div>
              <Link href=\"/comms\" className=\"mt-2 block text-sm text-amber-500 hover:text-amber-400\">→ All flagged & settings</Link>
            </div>
          </Section>
        </SandboxWrapper>"""

content = content.replace(old_email_section, new_email_section)

with open(path, "w") as f:
    f.write(content)

print("Done")
