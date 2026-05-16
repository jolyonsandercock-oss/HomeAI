'use client';

import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';

interface ActionRow {
  source: string;
  reason: string;
  detail: string | null;
  severity: string | null;
  age_days: number | null;
  status: string;
}

const severityColour: Record<string, string> = {
  critical: 'text-warn',
  high: 'text-warn',
  medium: 'text-amber-500',
  low: 'text-ink-500',
};

export default function TasksPage() {
  const q = useSlug<ActionRow>('frontend_action_queue', {}, { refetchInterval: 60_000 });
  return (
    <div className="space-y-6">
      <SandboxWrapper id="tasks.queue" label="Action queue">
        <Section title="Open actions">
          {q.isLoading ? (
            <PlaceholderState message="Loading action queue…" />
          ) : q.data && q.data.length > 0 ? (
            <div className="tile">
              <table className="w-full text-sm">
                <thead className="text-xs text-ink-500 uppercase tracking-wider">
                  <tr>
                    <th className="text-left py-2 font-medium">Severity</th>
                    <th className="text-left font-medium">Source</th>
                    <th className="text-left font-medium">Reason</th>
                    <th className="text-left font-medium">Detail</th>
                    <th className="text-right font-medium">Age</th>
                  </tr>
                </thead>
                <tbody>
                  {q.data.map((r, i) => (
                    <tr key={i} className="border-t border-ink-200">
                      <td className={'py-1.5 font-mono ' + (severityColour[r.severity ?? ''] ?? 'text-ink-500')}>
                        {r.severity ?? '—'}
                      </td>
                      <td className="text-xs text-ink-700">{r.source}</td>
                      <td className="text-xs text-ink-700">{r.reason}</td>
                      <td className="text-xs text-ink-500 max-w-md truncate">{r.detail}</td>
                      <td className="text-right font-mono text-xs text-ink-500">{r.age_days}d</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <PlaceholderState message="No open actions." />
          )}
        </Section>
      </SandboxWrapper>
    </div>
  );
}
