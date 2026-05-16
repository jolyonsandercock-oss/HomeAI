'use client';

import { useState } from 'react';
import { Calendar } from 'lucide-react';

type Preset = 'today' | 'yesterday' | '7d' | '30d' | 'custom';

export interface DateRange {
  preset: Preset;
  start: string;  // YYYY-MM-DD
  end: string;
}

function today() { return new Date().toISOString().slice(0, 10); }
function daysAgo(n: number) {
  const d = new Date(); d.setDate(d.getDate() - n);
  return d.toISOString().slice(0, 10);
}

const PRESETS: Record<Preset, () => DateRange> = {
  today:     () => ({ preset: 'today',     start: today(),       end: today() }),
  yesterday: () => ({ preset: 'yesterday', start: daysAgo(1),    end: daysAgo(1) }),
  '7d':      () => ({ preset: '7d',        start: daysAgo(6),    end: today() }),
  '30d':     () => ({ preset: '30d',       start: daysAgo(29),   end: today() }),
  custom:    () => ({ preset: 'custom',    start: daysAgo(6),    end: today() }),
};

export function DateRangePicker({
  value,
  onChange,
}: {
  value: DateRange;
  onChange: (v: DateRange) => void;
}) {
  const [showCustom, setShowCustom] = useState(false);
  return (
    <div className="flex items-center gap-2">
      <div className="flex bg-ink-100 border border-ink-200 rounded-md overflow-hidden text-xs">
        {(['today', 'yesterday', '7d', '30d'] as Preset[]).map((p) => (
          <button key={p}
            onClick={() => { setShowCustom(false); onChange(PRESETS[p]()); }}
            className={
              'px-2.5 py-1.5 ' +
              (value.preset === p ? 'bg-amber-500 text-ink-0' : 'text-ink-600 hover:text-ink-800')
            }>
            {p === 'today' ? 'Today' : p === 'yesterday' ? 'Yest.' : p}
          </button>
        ))}
        <button
          onClick={() => setShowCustom((v) => !v)}
          className={
            'px-2.5 py-1.5 flex items-center gap-1 ' +
            (value.preset === 'custom' ? 'bg-amber-500 text-ink-0' : 'text-ink-600 hover:text-ink-800')
          }>
          <Calendar size={12} />Custom
        </button>
      </div>
      {showCustom && (
        <div className="flex items-center gap-1.5 text-xs">
          <input
            type="date"
            value={value.start}
            onChange={(e) => onChange({ ...value, preset: 'custom', start: e.target.value })}
            className="bg-ink-0 border border-ink-200 rounded px-1.5 py-1 text-ink-800"
          />
          <span className="text-ink-500">→</span>
          <input
            type="date"
            value={value.end}
            onChange={(e) => onChange({ ...value, preset: 'custom', end: e.target.value })}
            className="bg-ink-0 border border-ink-200 rounded px-1.5 py-1 text-ink-800"
          />
        </div>
      )}
    </div>
  );
}
