'use client';

import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { KPICard } from '@/components/ui/KPICard';
import { useSlug } from '@/lib/hooks';

interface FreshnessRow {
  name: string;
  status: string; // 'ok' | 'STALE' | 'NO_DATA'
  age_hours: string | number | null;
  sla_hours: string | number | null;
}
interface AlertRow {
  alertname: string;
  severity: string | null;
  status: string;
  starts_at: string;
  acknowledged: boolean;
  summary: string | null;
}
interface FailureRow {
  name: string;
  started_at: string | null;
  finished_at: string;
  status: string;
  rows_affected: number | null;
  note: string | null;
}

// Traffic-light styling per freshness status: green ok / amber NO_DATA / red STALE.
function statusClasses(status: string): string {
  if (status === 'STALE') return 'border-red-500/60 bg-red-500/10';
  if (status === 'NO_DATA') return 'border-amber-500/60 bg-amber-500/10';
  return 'border-green-600/40 bg-green-500/5';
}
function statusDot(status: string): string {
  if (status === 'STALE') return 'bg-red-500';
  if (status === 'NO_DATA') return 'bg-amber-500';
  return 'bg-green-500';
}
function fmtHours(v: string | number | null): string {
  if (v == null) return '—';
  const n = Number(v);
  if (!isFinite(n)) return '—';
  if (n >= 48) return `${(n / 24).toFixed(1)}d`;
  return `${n.toFixed(1)}h`;
}

export default function OpsPage() {
  const fresh    = useSlug<FreshnessRow>('ops_freshness', {}, { refetchInterval: 5 * 60_000 });
  const alerts   = useSlug<AlertRow>('ops_alerts', {}, { refetchInterval: 5 * 60_000 });
  const failures = useSlug<FailureRow>('ops_recent_failures', {}, { refetchInterval: 5 * 60_000 });

  const rows = fresh.data ?? [];
  const staleCount  = rows.filter(r => r.status === 'STALE').length;
  const noDataCount = rows.filter(r => r.status === 'NO_DATA').length;
  const okCount     = rows.filter(r => r.status !== 'STALE' && r.status !== 'NO_DATA').length;

  return (
    <div className="space-y-6">
      <SandboxWrapper id="ops.kpi" label="Ops KPIs">
        <Section title="Pipeline health — right now">
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
            <KPICard label="Stale (over SLA)" value={staleCount} loading={fresh.isLoading} />
            <KPICard label="No data" value={noDataCount} loading={fresh.isLoading} />
            <KPICard label="Healthy" value={okCount} loading={fresh.isLoading} />
            <KPICard label="Firing alerts" value={alerts.data?.length ?? 0} loading={alerts.isLoading} />
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="ops.freshness" label="Freshness grid">
        <Section title="Freshness vs SLA (STALE first)">
          {fresh.isLoading ? <PlaceholderState message="Loading freshness…" /> :
           rows.length === 0 ? <PlaceholderState message="No pipelines registered in ops.check_freshness()." /> : (
            <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-2">
              {rows.map(r => (
                <div key={r.name} className={'rounded-md border p-2 ' + statusClasses(r.status)}>
                  <div className="flex items-center gap-2">
                    <span className={'inline-block w-2 h-2 rounded-full shrink-0 ' + statusDot(r.status)} />
                    <span className="text-xs font-mono text-ink-800 truncate" title={r.name}>{r.name}</span>
                  </div>
                  <div className={'mt-1 text-xs ' + (r.status === 'STALE' ? 'text-red-400 font-semibold' : r.status === 'NO_DATA' ? 'text-amber-400' : 'text-ink-500')}>
                    {r.status === 'NO_DATA' ? 'no data ever' : `age ${fmtHours(r.age_hours)}`}
                    <span className="text-ink-500 font-normal"> / SLA {fmtHours(r.sla_hours)}</span>
                  </div>
                </div>
              ))}
            </div>
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="ops.alerts" label="Firing alerts">
        <Section title="Firing alerts">
          {alerts.isLoading ? <PlaceholderState message="Loading alerts…" /> :
           (alerts.data ?? []).length === 0 ? <PlaceholderState message="No firing alerts." /> : (
            <div className="tile overflow-x-auto">
              <table className="w-full text-xs">
                <thead className="text-ink-500 uppercase tracking-wider">
                  <tr>
                    <th className="text-left px-2 py-1.5">Alert</th>
                    <th className="text-left px-2 py-1.5">Severity</th>
                    <th className="text-left px-2 py-1.5">Since</th>
                    <th className="text-left px-2 py-1.5">Ack</th>
                    <th className="text-left px-2 py-1.5">Summary</th>
                  </tr>
                </thead>
                <tbody>
                  {(alerts.data ?? []).map((a, i) => (
                    <tr key={a.alertname + i} className="border-t border-ink-200 align-top">
                      <td className="px-2 py-1.5 font-mono text-ink-800 whitespace-nowrap">{a.alertname}</td>
                      <td className={'px-2 py-1.5 ' + (a.severity === 'critical' ? 'text-red-400' : 'text-amber-400')}>{a.severity ?? '—'}</td>
                      <td className="px-2 py-1.5 whitespace-nowrap text-ink-700">{new Date(a.starts_at).toLocaleString('en-GB', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                      <td className="px-2 py-1.5">{a.acknowledged ? <span className="text-ink-500">ack</span> : <span className="text-red-400">no</span>}</td>
                      <td className="px-2 py-1.5 text-ink-700 max-w-md">{a.summary ?? ''}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="ops.failures" label="Recent failures">
        <Section title="Pipeline failures — last 24h">
          {failures.isLoading ? <PlaceholderState message="Loading failures…" /> :
           (failures.data ?? []).length === 0 ? <PlaceholderState message="No failed runs in the last 24 hours." /> : (
            <div className="tile overflow-x-auto">
              <table className="w-full text-xs">
                <thead className="text-ink-500 uppercase tracking-wider">
                  <tr>
                    <th className="text-left px-2 py-1.5">Pipeline</th>
                    <th className="text-left px-2 py-1.5">Finished</th>
                    <th className="text-right px-2 py-1.5">Rows</th>
                    <th className="text-left px-2 py-1.5">Note</th>
                  </tr>
                </thead>
                <tbody>
                  {(failures.data ?? []).map((f, i) => (
                    <tr key={f.name + f.finished_at + i} className="border-t border-ink-200 align-top">
                      <td className="px-2 py-1.5 font-mono text-red-400 whitespace-nowrap">{f.name}</td>
                      <td className="px-2 py-1.5 whitespace-nowrap text-ink-700">{new Date(f.finished_at).toLocaleString('en-GB', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                      <td className="px-2 py-1.5 text-right text-ink-500">{f.rows_affected ?? '—'}</td>
                      <td className="px-2 py-1.5 text-ink-700 max-w-md">{f.note ?? ''}</td>
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
