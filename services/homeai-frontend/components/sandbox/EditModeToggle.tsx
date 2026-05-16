'use client';

import { Pencil, Check } from 'lucide-react';
import { useEditMode } from './EditModeContext';

export function EditModeToggle() {
  const { editing, toggle } = useEditMode();
  return (
    <button
      onClick={toggle}
      className={
        'flex items-center gap-1.5 px-2.5 py-1.5 text-xs rounded-md border transition-colors ' +
        (editing
          ? 'bg-amber-500/10 border-amber-500 text-amber-500'
          : 'bg-ink-100 border-ink-200 text-ink-500 hover:text-ink-700')
      }
      aria-label="Toggle edit mode"
    >
      {editing ? <Check size={14} /> : <Pencil size={14} />}
      <span className="hidden sm:inline">{editing ? 'Editing' : 'Edit'}</span>
    </button>
  );
}
