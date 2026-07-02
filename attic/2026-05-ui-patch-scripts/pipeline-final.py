#!/usr/bin/env python3
"""Replace pipeline logs placeholder with live table."""

path = "/home_ai/services/homeai-frontend/app/backend/page.tsx"

with open(path) as f:
    lines = f.readlines()

old_section = """      <SandboxWrapper id="backend.action-queue">
        <Section title="Pipeline logs">
          <PlaceholderState
            message="audit_log live stream"
            hint="Pipeline logs view is in the legacy /agents-ops surface. Migration to this page in next iteration." />
        </Section>
      </SandboxWrapper>
"""

old_lines = old_section.split("\n")
# old_section has a trailing empty line from split, let's handle by just joining with \n
old_text = "\n".join(old_lines[:-1]) + "\n"  # remove trailing blank

# Find this text in the file
content = "".join(lines)
if old_text in content:
    print("Found old section")
else:
    print("NOT FOUND — trying without trailing newline")
    old_text = old_section.rstrip("\n")
    if old_text not in content:
        old_text = old_section.strip()
        if old_text not in content:
            print("Still not found")
            exit(1)

new_section = """      <SandboxWrapper id="backend.action-queue">
        <Section title={`Pipeline logs \u2014 last 24h (${pipelineLogs.data?.length ?? 0})`}>
          {pipelineLogs.isLoading ? (
            <PlaceholderState message="Loading logs\u2026" />
          ) : (pipelineLogs.data ?? []).length === 0 ? (
            <PlaceholderState message="No pipeline activity in the last 24h." />
          ) : (
            <div className="tile overflow-x-auto text-xs">
              <table className="w-full font-mono">
                <thead className="text-ink-500 uppercase tracking-wider">
                  <tr>
                    <th className="text-left py-1.5">Time</th>
                    <th className="text-left">Pipeline</th>
                    <th className="text-left">Action</th>
                    <th className="text-left">Record</th>
                  </tr>
                </thead>
                <tbody>
                  {(pipelineLogs.data ?? []).slice(0, 30).map((l, i) => (
                    <tr key={l.trace_id || i} className="border-t border-ink-200">
                      <td className="py-1 text-ink-500">{new Date(l.created_at).toLocaleTimeString('en-GB', {hour:'2-digit', minute:'2-digit', second:'2-digit'})}</td>
                      <td className="text-ink-800">{l.pipeline}</td>
                      <td className="text-ink-600">{l.action}</td>
                      <td className="text-ink-500">{l.record_type || ''}{l.record_id ? ' #' + l.record_id : ''}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </Section>
      </SandboxWrapper>
"""

content = content.replace(old_text, new_section)

with open(path, "w") as f:
    f.write(content)

if "pipelineLogs.data" in content and "audit_log live stream" not in content:
    print("Success")
else:
    print("WARNING: check output")
