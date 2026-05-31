'use client';

import { useSlug } from '@/lib/hooks';
import { Section } from '@/components/ui/Section';

interface KpiRow {
  kpi_key: string;
  label: string;
  tier: 'management' | 'operational';
  unit: string;
  value: string | null;
  status: 'green' | 'amber' | 'red' | 'nodata';
  lever: string | null;
  provisional: boolean | string;
  window_note: string | null;
}

const DOT: Record<string, string> = {
  green: 'bg-emerald-500', amber: 'bg-amber-500', red: 'bg-red-500', nodata: 'bg-ink-300',
};
const RING: Record<string, string> = {
  green: 'border-emerald-500/40', amber: 'border-amber-500/50', red: 'border-red-500/60', nodata: 'border-ink-200',
};

function fmtVal(v: string | null, unit: string): string {
  if (v == null) return '—';
  const n = parseFloat(v);
  if (!Number.isFinite(n)) return v;
  if (unit === '£') return '£' + n.toLocaleString('en-GB', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  if (unit === '%') return n.toFixed(1) + '%';
  return v;
}

function KpiCard({ r }: { r: KpiRow }) {
  // Provisional KPIs must NOT show a confident traffic-light — their data is
  // known-incomplete, so a green light would mislead. Render muted + flagged.
  const prov = r.provisional === true || String(r.provisional) === 'true';
  const ring = prov ? 'border-ink-200' : (RING[r.status] ?? 'border-ink-200');
  const dot  = prov ? 'bg-ink-400' : (DOT[r.status] ?? 'bg-ink-300');
  const showLever = !prov && r.lever != null && (r.status === 'amber' || r.status === 'red');
  return (
    <div className={`rounded-lg border ${ring} bg-ink-50 p-3 flex flex-col gap-1`}>
      <div className="flex items-center gap-2">
        <span className={`w-2.5 h-2.5 rounded-full ${dot} ${prov ? 'opacity-50' : ''}`} />
        <span className="text-[11px] uppercase tracking-wide text-ink-500">{r.label}</span>
      </div>
      <div className={`text-xl font-semibold font-mono ${prov ? 'text-ink-400 italic' : 'text-ink-800'}`}>
        {fmtVal(r.value, r.unit)}
      </div>
      <div className="text-[10px] text-ink-500">
        {r.window_note}{prov ? ' · provisional' : ''}
      </div>
      {prov && (
        <div className="text-[10px] text-amber-500/80 italic">⚠ data incomplete — not yet reliable</div>
      )}
      {showLever && (
        <div className="text-[11px] text-ink-700 mt-1 border-t border-ink-200 pt-1">{r.lever}</div>
      )}
    </div>
  );
}

export function KpiTrafficLight() {
  const kpis = useSlug<KpiRow>('kpi_dashboard', {}, { refetchInterval: 5 * 60_000 });
  const rows = kpis.data ?? [];
  if (kpis.isLoading || rows.length === 0) return null;
  const mgmt = rows.filter(r => r.tier === 'management');
  const ops  = rows.filter(r => r.tier === 'operational');
  return (
    <Section title="KPIs — traffic light">
      {mgmt.length > 0 && (
        <>
          <div className="text-[10px] uppercase tracking-wide text-ink-500 mb-1">Management</div>
          <div className="grid grid-cols-2 sm:grid-cols-3 xl:grid-cols-6 gap-2 mb-3">
            {mgmt.map(r => <KpiCard key={r.kpi_key} r={r} />)}
          </div>
        </>
      )}
      {ops.length > 0 && (
        <>
          <div className="text-[10px] uppercase tracking-wide text-ink-500 mb-1">Operational</div>
          <div className="grid grid-cols-2 sm:grid-cols-3 xl:grid-cols-6 gap-2">
            {ops.map(r => <KpiCard key={r.kpi_key} r={r} />)}
          </div>
        </>
      )}
    </Section>
  );
}
