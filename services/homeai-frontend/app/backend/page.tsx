'use client';

import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';

interface Cache { service: string; model_used: string; calls: number; prompt_tokens_total: number; cache_writes: number; cache_reads: number; pct_input_cached: string | null }

export default function BackendPage() {
  const cache = useSlug<Cache>('ai_cache_effectiveness', {}, { refetchInterval: 60_000 });

  return (
    <div className="space-y-6">
      <SandboxWrapper id="backend.health">
        <Section title="System health">
          <PlaceholderState
            message="Pipeline health view not yet present"
            hint="v_pipeline_health view is referenced by frontend_pipeline_health slug. Needs the underlying view created — heartbeat scrape per service. Lives in /agents-ops on the legacy dashboard currently." />
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="backend.cache">
        <Section title="Prompt cache effectiveness (last 7d)">
          {cache.isLoading ? (
            <PlaceholderState message="Loading…" />
          ) : cache.data && cache.data.length > 0 ? (
            <div className="tile">
              <table className="w-full text-sm">
                <thead className="text-xs text-ink-500 uppercase tracking-wider">
                  <tr>
                    <th className="text-left py-2 font-medium">Service</th>
                    <th className="text-left font-medium">Model</th>
                    <th className="text-right font-medium">Calls</th>
                    <th className="text-right font-medium">Tokens</th>
                    <th className="text-right font-medium">Hit %</th>
                  </tr>
                </thead>
                <tbody>
                  {cache.data.map((r, i) => (
                    <tr key={i} className="border-t border-ink-200">
                      <td className="py-1.5 font-mono text-xs text-ink-700">{r.service}</td>
                      <td className="text-xs text-ink-500">{r.model_used}</td>
                      <td className="text-right font-mono">{r.calls}</td>
                      <td className="text-right font-mono">{r.prompt_tokens_total?.toLocaleString()}</td>
                      <td className={'text-right font-mono ' + (parseFloat(r.pct_input_cached ?? '0') > 30 ? 'text-good' : 'text-ink-500')}>
                        {r.pct_input_cached ?? '0'}%
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : <PlaceholderState message="No AI calls yet in the last 7 days." />}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="backend.action-queue">
        <Section title="Pipeline logs">
          <PlaceholderState
            message="audit_log live stream"
            hint="Pipeline logs view is in the legacy /agents-ops surface. Migration to this page in next iteration." />
        </Section>
      </SandboxWrapper>
    </div>
  );
}
