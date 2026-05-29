'use client';

import { useState } from 'react';
import { X, Check } from 'lucide-react';

type Department = 'bar'|'kitchen'|'rooms'|'cafe'|'overhead';
const DEPARTMENTS: Department[] = ['bar','kitchen','rooms','cafe','overhead'];

interface Props {
  lineId: number;
  currentDepartment?: string | null;
  currentFamily?: string | null;
  currentDescription?: string;
  onClose: () => void;
  onSaved: () => void;
}

export function LineRecodePopover({
  lineId, currentDepartment, currentFamily, currentDescription, onClose, onSaved,
}: Props) {
  const [dept, setDept] = useState<Department | ''>((currentDepartment as Department) || '');
  const [family, setFamily] = useState(currentFamily || '');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    setSaving(true);
    setError(null);
    try {
      const basePath = process.env.NEXT_PUBLIC_BASE_PATH || '';
      const r = await fetch(`${basePath}/api/feedback/line`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          line_id: lineId,
          corrected_department: dept || null,
          corrected_family: family.trim() || null,
        }),
      });
      const data = await r.json();
      if (!r.ok) {
        setError(data?.error || `HTTP ${r.status}`);
        setSaving(false);
        return;
      }
      onSaved();
    } catch (e) {
      setError((e as Error).message);
      setSaving(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-0/80" onClick={onClose}>
      <div className="bg-ink-50 border border-ink-200 rounded-lg shadow-xl max-w-md w-full m-4 p-4"
           onClick={(e) => e.stopPropagation()}>
        <div className="flex items-baseline justify-between mb-3">
          <h3 className="text-sm font-medium text-ink-800">Recode line #{lineId}</h3>
          <button onClick={onClose} className="text-ink-500 hover:text-ink-800">
            <X size={16} />
          </button>
        </div>
        {currentDescription && (
          <div className="text-xs text-ink-500 mb-3 italic break-words max-h-20 overflow-y-auto">
            {currentDescription}
          </div>
        )}

        <label className="block text-xs uppercase tracking-wider text-ink-500 mb-1">Department</label>
        <div className="grid grid-cols-3 gap-1 mb-3">
          <button
            onClick={() => setDept('')}
            className={'text-xs px-2 py-1.5 rounded border ' +
              (dept === '' ? 'bg-ink-100 border-ink-300 text-ink-800' : 'border-ink-200 text-ink-500 hover:text-ink-800')}>
            (none)
          </button>
          {DEPARTMENTS.map((d) => (
            <button key={d}
              onClick={() => setDept(d)}
              className={'text-xs px-2 py-1.5 rounded border capitalize ' +
                (dept === d ? 'bg-amber-500 border-amber-500 text-ink-0' : 'border-ink-200 text-ink-600 hover:text-ink-800')}>
              {d}
            </button>
          ))}
        </div>

        <label className="block text-xs uppercase tracking-wider text-ink-500 mb-1">Product family</label>
        <input
          value={family}
          onChange={(e) => setFamily(e.target.value)}
          placeholder="beer / wine / cleaning / packaging / …"
          className="w-full bg-ink-0 border border-ink-200 rounded px-2 py-1.5 text-sm text-ink-800 mb-3"
        />

        {error && <div className="text-xs text-red-400 mb-2">{error}</div>}

        <div className="flex gap-2">
          <button
            onClick={save}
            disabled={saving}
            className="flex-1 text-sm py-1.5 rounded bg-amber-500 text-ink-0 hover:bg-amber-400 disabled:opacity-50 inline-flex items-center justify-center gap-1">
            <Check size={14} /> {saving ? 'Saving…' : 'Save correction'}
          </button>
          <button
            onClick={onClose}
            className="text-sm px-3 py-1.5 rounded bg-ink-100 hover:bg-ink-200 text-ink-700">
            Cancel
          </button>
        </div>
        <div className="text-xs text-ink-500 mt-3">
          This correction is saved to line_category_feedback and applied to the line immediately.
          The nightly promoter rolls ≥3-agreement clusters into vendor_category_rules.
        </div>
      </div>
    </div>
  );
}
