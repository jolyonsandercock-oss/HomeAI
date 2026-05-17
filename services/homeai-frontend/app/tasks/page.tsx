'use client';

import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { KPICard } from '@/components/ui/KPICard';
import { useSlug } from '@/lib/hooks';

interface ActionRow {
  source: string;
  ref: string;
  severity: 'critical' | 'high' | 'medium' | 'low' | null;
  kind: string;
  title: string;
  age_date: string;
  age_days: number;
  realm: string;
}

const severityColour: Record<string, string> = {
  critical: 'text-warn font-bold',
  high:     'text-warn',
  medium:   'text-amber-500',
  low:      'text-ink-500',
};

export default function TasksPage() {
  const q = useSlug<ActionRow>('frontend_action_queue', {}, { refetchInterval: 60_000 });

  const counts = (q.data || []).reduce((acc, r) => {
    const s = r.severity ?? 'unknown';
    acc[s] = (acc[s] || 0) + 1;
    return acc;
  }, {} as Record<string, number>);

  return (
    <div className="space-y-6">
      <SandboxWrapper id="tasks.summary">
        <Section title="Action queue — summary">
          <div className="grid grid-cols-2 sm:grid-cols-5 gap-3">
            <KPICard label="Total" value={q.data?.length ?? '—'} size="xl" loading={q.isLoading} />
            <KPICard label="Critical" value={counts.critical ?? 0} />
            <KPICard label="High" value={counts.high ?? 0} />
            <KPICard label="Medium" value={counts.medium ?? 0} />
            <KPICard label="Low" value={counts.low ?? 0} />
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="tasks.queue" label="Action queue">
        <Section title="Open actions">
          {q.isLoading ? (
            <PlaceholderState message="Loading action queue…" />
          ) : q.data && q.data.length > 0 ? (
            <div className="tile overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="text-xs text-ink-500 uppercase tracking-wider">
                  <tr>
                    <th className="text-left py-2 font-medium">Severity</th>
                    <th className="text-left font-medium">Kind</th>
                    <th className="text-left font-medium">Title</th>
                    <th className="text-right font-medium">Age</th>
                  </tr>
                </thead>
                <tbody>
                  {q.data.map((r) => (
                    <tr key={`${r.source}-${r.ref}`} className="border-t border-ink-200">
                      <td className={'py-1.5 font-mono text-xs ' + (severityColour[r.severity ?? 'low'])}>
                        {r.severity ?? '—'}
                      </td>
                      <td className="text-xs text-ink-500">{r.kind}</td>
                      <td className="text-ink-800">{r.title}</td>
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
