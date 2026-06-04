'use client';

import Link from 'next/link';
import { Section } from '@/components/ui/Section';
import { KPICard } from '@/components/ui/KPICard';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import { AlertTriangle, CheckCircle2, FileText } from 'lucide-react';
import { QuotaStatusTile } from '@/components/admin/QuotaStatusTile';
import { ExpenseRollup } from '@/components/admin/ExpenseRollup';

interface Cache { service: string; model_used: string; calls: number; prompt_tokens_total: number; cache_writes: number; cache_reads: number; pct_input_cached: string | null }
interface AIUsage {
  model_used: string; tier: string; call_count: number;
  prompt_tokens: number; completion_tokens: number;
  avg_latency_ms: number; cache_hits: number; escalated: number;
}
interface ErrorRow { pipeline: string; action: string; occurrences: number; most_recent: string }
interface LocalAI { workload: string; capability_tag: string | null; calls: number; prompt_tokens: number; completion_tokens: number; latest: string }
interface Freshness { source: string; last_data: string; hours_stale: string | number | null }
interface PipelineLogRow { pipeline: string; action: string; created_at: string; trace_id: string | null; record_type: string | null; record_id: number | null }

function freshnessClass(h: number | null): string {
  if (h == null) return 'text-ink-500';
  if (h < 24) return 'text-good';
  if (h < 72) return 'text-amber-500';
  return 'text-warn';
}

export default function BackendPage() {
  const cache = useSlug<Cache>('ai_cache_effectiveness', {}, { refetchInterval: 60_000 });
  const aiUsage = useSlug<AIUsage>('backend_ai_usage_24h', {}, { refetchInterval: 60_000 });
const pipelineLogs = useSlug<PipelineLogRow>('pipeline_audit_recent');
  const loan = useSlug<any>('youleend_reconciliation', {}, { refetchInterval: 10 * 60_000 });
  const errors  = useSlug<ErrorRow>('backend_errors_24h', {}, { refetchInterval: 60_000 });
  const fresh   = useSlug<Freshness>('backend_import_freshness', {}, { refetchInterval: 60_000 });
  const localAI = useSlug<LocalAI>('backend_local_ai_30d', {}, { refetchInterval: 5 * 60_000 });

  const staleSources = (fresh.data ?? []).filter(f => parseFloat(String(f.hours_stale ?? 0)) >= 24);

  return (
    <div className="space-y-6">
      {staleSources.length > 0 && (
        <div className="tile bg-warn/10 border border-warn/30 flex items-center gap-3">
          <AlertTriangle size={20} className="text-warn shrink-0" />
          <div className="text-sm text-warn">
            <strong>Stalled imports:</strong> {staleSources.map(s => `${s.source} (${Math.round(parseFloat(String(s.hours_stale)))}h)`).join(' · ')}
          </div>
        </div>
      )}

      <SandboxWrapper id="backend.quota" label="AI quota">
        <QuotaStatusTile />
      </SandboxWrapper>

      <SandboxWrapper id="backend.expense-rollup" label="Expense rollup">
        <ExpenseRollup />
        <div className="mt-2 text-xs">
          <Link href="/app/invoices" className="text-amber-500 hover:text-amber-400 underline inline-flex items-center gap-1">
            <FileText size={12} /> View invoices / COGS breakdown
          </Link>
        </div>
      </SandboxWrapper>

      <SandboxWrapper id="backend.loans" label="Loans">
        <Section title="YouLend — Merchant Cash Advance">
          {loan.isLoading ? <PlaceholderState message="Loading..." /> :
           loan.data && loan.data.length > 0 ? (
            <div>
              <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 mb-4">
                <KPICard label="Original advance" value={`£${(Number(loan.data[0].original_balance) ?? 0).toLocaleString()}`} />
                <KPICard label="Remaining balance" value={`£${(Number(loan.data[0].current_balance) ?? 0).toLocaleString()}`} />
                <KPICard label="Repaid to date" value={`£${((Number(loan.data[0].original_balance) ?? 0) - (Number(loan.data[0].current_balance) ?? 0)).toLocaleString()}`} />
              </div>
              <div className="tile overflow-x-auto text-xs">
                <table className="w-full">
                  <thead className="text-ink-500 uppercase">
                    <tr>
                      <th className="text-left py-1">Date</th>
                      <th className="text-right">YouLend took</th>
                      <th className="text-right">Dojo gross</th>
                      <th className="text-right">Expected 10%</th>
                      <th className="text-right">Variance</th>
                      <th className="text-center">Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    {(loan.data ?? []).slice(0, 14).map((r, i) => (
                      <tr key={i} className="border-t border-ink-200">
                        <td className="py-1">{new Date(r.repayment_date).toLocaleDateString('en-GB', {day:'numeric', month:'short'})}</td>
                        <td className="text-right font-mono">{r.youleend_took != null ? `£${Number(r.youleend_took).toFixed(2)}` : '–'}</td>
                        <td className="text-right font-mono text-ink-500">{r.dojo_gross != null ? `£${Number(r.dojo_gross).toFixed(2)}` : '–'}</td>
                        <td className="text-right font-mono text-ink-500">£{Number(r.expected_10pct).toFixed(2)}</td>
                        <td className={`text-right font-mono ${Math.abs(Number(r.variance)) > 0.05 ? 'text-warn' : 'text-ink-500'}`}>{Number(r.variance).toFixed(2)}</td>
                        <td className="text-center">
                          <span className={`text-2xs px-1.5 py-0.5 rounded ${r.status === 'match' ? 'bg-green-900/30 text-green-400' : r.status === 'manual_topup' ? 'bg-amber-900/30 text-amber-400' : r.status === 'needs_review' ? 'bg-red-900/30 text-red-400' : 'bg-ink-200 text-ink-500'}`}>
                            {r.status}
                          </span>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          ) : <PlaceholderState message="No loan data." />}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="backend.freshness" label="Import freshness">
        <Section title="Upstream import freshness">
          {fresh.isLoading ? <PlaceholderState message="Loading…" /> :
           fresh.data && fresh.data.length > 0 ? (
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
              {fresh.data.map(f => {
                const h = f.hours_stale != null ? parseFloat(String(f.hours_stale)) : null;
                return (
                  <div key={f.source} className="tile">
                    <div className="flex items-center justify-between">
                      <div className="text-xs uppercase tracking-wider text-ink-500">{f.source}</div>
                      {h != null && h < 24
                        ? <CheckCircle2 size={14} className="text-good" />
                        : <AlertTriangle size={14} className={freshnessClass(h)} />}
                    </div>
                    <div className={'mt-1 text-xl font-mono font-semibold ' + freshnessClass(h)}>
                      {h != null ? `${h.toFixed(0)}h` : '—'}
                    </div>
                    <div className="text-xs text-ink-500 mt-0.5">{f.last_data}</div>
                  </div>
                );
              })}
            </div>
          ) : <PlaceholderState message="No freshness data." />}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="backend.ai-usage" label="AI usage">
        <Section title="AI usage — last 24h">
          {aiUsage.isLoading ? <PlaceholderState message="Loading…" /> :
           aiUsage.data && aiUsage.data.length > 0 ? (
            <div className="tile overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="text-xs text-ink-500 uppercase tracking-wider">
                  <tr>
                    <th className="text-left py-1.5 font-medium">Model</th>
                    <th className="text-left font-medium">Tier</th>
                    <th className="text-right font-medium">Calls</th>
                    <th className="text-right font-medium">Prompt</th>
                    <th className="text-right font-medium">Completion</th>
                    <th className="text-right font-medium">Avg ms</th>
                    <th className="text-right font-medium">Cached</th>
                    <th className="text-right font-medium">Escalated</th>
                  </tr>
                </thead>
                <tbody>
                  {aiUsage.data.map((r, i) => (
                    <tr key={i} className="border-t border-ink-200">
                      <td className="py-1.5 font-medium text-ink-900">{r.model_used}</td>
                      <td className="text-ink-700 text-xs">{r.tier}</td>
                      <td className="text-right font-mono text-ink-700">{r.call_count}</td>
                      <td className="text-right font-mono text-ink-700">{r.prompt_tokens?.toLocaleString()}</td>
                      <td className="text-right font-mono text-ink-700">{r.completion_tokens?.toLocaleString()}</td>
                      <td className="text-right font-mono text-ink-700">{r.avg_latency_ms}</td>
                      <td className="text-right font-mono text-good">{r.cache_hits}</td>
                      <td className={'text-right font-mono ' + (r.escalated > 0 ? 'text-amber-500' : 'text-ink-700')}>{r.escalated}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              <div className="mt-2 text-xs text-ink-500">
                Cost-per-model conversion deferred — pricing constants need to land in DB first.
              </div>
            </div>
          ) : <PlaceholderState message="No AI calls in the last 24h." />}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="backend.local-ai" label="Local model">
        <Section title="Local model — Ollama / qwen (30 days)">
          {localAI.isLoading ? <PlaceholderState message="Loading…" /> :
           localAI.data && localAI.data.length > 0 ? (
            <div className="tile overflow-x-auto">
              <div className="mb-2 text-xs text-ink-500">
                {(() => {
                  const d = localAI.data!;
                  const c = d.reduce((s, r) => s + Number(r.calls), 0);
                  const tok = d.reduce((s, r) => s + Number(r.prompt_tokens) + Number(r.completion_tokens), 0);
                  return `${c.toLocaleString()} calls · ${tok.toLocaleString()} tokens · £0 cloud cost (runs on the local RTX 3060)`;
                })()}
              </div>
              <table className="w-full text-sm">
                <thead className="text-xs text-ink-500 uppercase tracking-wider">
                  <tr>
                    <th className="text-left py-1.5 font-medium">Workload</th>
                    <th className="text-left font-medium">Capability</th>
                    <th className="text-right font-medium">Calls</th>
                    <th className="text-right font-medium">Prompt tok</th>
                    <th className="text-right font-medium">Completion tok</th>
                    <th className="text-left font-medium">Last</th>
                  </tr>
                </thead>
                <tbody>
                  {localAI.data.map((r, i) => (
                    <tr key={i} className="border-t border-ink-200">
                      <td className="py-1.5 text-ink-900">{r.workload}</td>
                      <td className="text-ink-700 text-xs">{r.capability_tag}</td>
                      <td className="text-right font-mono text-ink-700">{Number(r.calls).toLocaleString()}</td>
                      <td className="text-right font-mono text-ink-700">{Number(r.prompt_tokens).toLocaleString()}</td>
                      <td className="text-right font-mono text-ink-700">{Number(r.completion_tokens).toLocaleString()}</td>
                      <td className="text-ink-500 text-xs">{new Date(r.latest).toLocaleString('en-GB')}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : <PlaceholderState message="No local-model calls in the last 30 days." />}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="backend.errors" label="Errors">
        <Section title={`Errors / firing alerts — last 24h (${errors.data?.length ?? 0})`}>
          {errors.isLoading ? <PlaceholderState message="Loading…" /> :
           errors.data && errors.data.length > 0 ? (
            <div className="tile overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="text-xs text-ink-500 uppercase tracking-wider">
                  <tr>
                    <th className="text-left py-1.5 font-medium">Pipeline</th>
                    <th className="text-left font-medium">Action</th>
                    <th className="text-right font-medium">Count</th>
                    <th className="text-left font-medium">Last</th>
                  </tr>
                </thead>
                <tbody>
                  {errors.data.map((e, i) => (
                    <tr key={i} className="border-t border-ink-200">
                      <td className="py-1.5 text-ink-900 text-xs">{e.pipeline}</td>
                      <td className="text-ink-700 text-xs font-mono">{e.action}</td>
                      <td className={'text-right font-mono ' + (e.occurrences > 5 ? 'text-warn' : 'text-amber-500')}>{e.occurrences}</td>
                      <td className="text-sm text-ink-500 font-mono">{new Date(e.most_recent).toLocaleString('en-GB')}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : <PlaceholderState message="No errors in the last 24h." />}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="backend.cache">
        <Section title="Prompt cache effectiveness (last 7d)">
          {cache.isLoading ? (
            <PlaceholderState message="Loading…" />
          ) : cache.data && cache.data.length > 0 ? (
            <div className="tile overflow-x-auto">
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
        <Section title={`Pipeline logs — last 24h (${pipelineLogs.data?.length ?? 0})`}>
          {pipelineLogs.isLoading ? (
            <PlaceholderState message="Loading logs…" />
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
    </div>
  );
}
