'use client';

import { Search } from 'lucide-react';
import { useState } from 'react';

export function GlobalSearch() {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button
        onClick={() => setOpen(true)}
        className="flex items-center gap-2 px-2.5 py-1.5 text-xs rounded-md bg-ink-100 hover:bg-ink-200 text-ink-500 border border-ink-200"
        aria-label="Search"
      >
        <Search size={14} />
        <span className="hidden sm:inline">Search</span>
      </button>
      {open && (
        <div onClick={() => setOpen(false)}
          className="fixed inset-0 bg-black/60 z-50 flex items-start justify-center pt-24 px-3">
          <div onClick={(e) => e.stopPropagation()}
            className="w-full max-w-2xl bg-ink-50 rounded-lg shadow-2xl border border-ink-200 p-4">
            <input
              autoFocus
              type="text"
              placeholder="Search — guest name, invoice, sales day, action…"
              className="w-full bg-ink-0 border border-ink-200 rounded-md px-3 py-2.5 text-sm text-ink-800 placeholder:text-ink-500 focus:outline-none focus:border-amber-500"
            />
            <div className="mt-3 text-xs text-ink-500">
              Try: <span className="text-ink-700 font-mono">tonight covers</span>,{' '}
              <span className="text-ink-700 font-mono">wage% week</span>,{' '}
              <span className="text-ink-700 font-mono">arrivals tomorrow</span>.
              {' '}Search wired to /api/search in next iteration.
            </div>
          </div>
        </div>
      )}
    </>
  );
}
