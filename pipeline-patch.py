#!/usr/bin/env python3
"""Add pipeline audit log to backend page — v2 with exact matching."""

path = "/home_ai/services/homeai-frontend/app/backend/page.tsx"

with open(path) as f:
    content = f.read()

# 1. Add PipelineLogRow interface
content = content.replace(
    "interface ErrorRow { pipeline: string; action: string; occurrences: number; most_recent: string }",
    "interface ErrorRow { pipeline: string; action: string; occurrences: number; most_recent: string }\ninterface PipelineLogRow { pipeline: string; action: string; created_at: string; trace_id: string | null; record_type: string | null; record_id: number | null }"
)

# 2. Add useSlug for pipeline logs 
content = content.replace(
    "const errors  = useSlug<ErrorRow>('backend_errors_24h');",
    "const errors  = useSlug<ErrorRow>('backend_errors_24h');\n  const pipelineLogs = useSlug<PipelineLogRow>('pipeline_audit_recent');"
)

# 3. Replace pipeline logs section
old = '''      <SandboxWrapper id="backend.action-queue">
        <Section title="Pipeline logs">
          <PlaceholderState
            message="audit_log live stream"
            hint="Pipeline logs view is in the legacy /agents-ops surface. Migration to this page in next iteration." />
        </Section>
      </SandboxWrapper>'''

new = '''      <SandboxWrapper id="backend.action-queue">
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
      </SandboxWrapper>'''

n = content.count(old)
print(f"Found: {n}")
if n == 1:
    content = content.replace(old, new)
    with open(path, "w") as f:
        f.write(content)
    print("Done" if "pipelineLogs" in content else "ERROR")
else:
    print(f"Expected 1 match, got {n}")
