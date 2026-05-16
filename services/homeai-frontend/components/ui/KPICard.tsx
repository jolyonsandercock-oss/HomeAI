'use client';

import { SparkLine } from './SparkLine';
import clsx from 'clsx';

interface KPICardProps {
  label: string;
  value: string | number | null;
  unit?: string;
  rollingAvg?: { label: string; value: string | number }[];
  spark?: number[];
  delta?: number;
  size?: 'xl' | 'md';
  loading?: boolean;
}

export function KPICard({ label, value, unit, rollingAvg, spark, delta, size = 'md', loading }: KPICardProps) {
  return (
    <div className="tile relative overflow-hidden">
      <div className="label">{label}</div>
      <div className="mt-1 flex items-baseline gap-2">
        <span className={size === 'xl' ? 'kpi-xl' : 'kpi'}>
          {loading ? <span className="inline-block w-16 h-6 bg-ink-200 rounded animate-pulse" />
                   : (value ?? '—')}
        </span>
        {unit && <span className="text-xs text-ink-500">{unit}</span>}
        {typeof delta === 'number' && (
          <span className={clsx('text-xs font-mono', delta >= 0 ? 'delta-pos' : 'delta-neg')}>
            {delta >= 0 ? '+' : ''}{delta.toFixed(1)}%
          </span>
        )}
      </div>
      {rollingAvg && rollingAvg.length > 0 && (
        <div className="mt-2 flex gap-3 text-xs text-ink-500">
          {rollingAvg.map((r) => (
            <span key={r.label}>
              <span className="text-ink-700 font-mono">{r.value}</span>{' '}
              <span className="text-ink-500">{r.label}</span>
            </span>
          ))}
        </div>
      )}
      {spark && spark.length > 1 && (
        <div className="mt-2 -mb-1 -mx-1 h-8 opacity-50">
          <SparkLine values={spark} />
        </div>
      )}
    </div>
  );
}
