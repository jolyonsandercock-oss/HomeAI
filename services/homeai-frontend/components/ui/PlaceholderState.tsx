'use client';

import { CircleDashed } from 'lucide-react';

export function PlaceholderState({ message, hint }: { message: string; hint?: string }) {
  return (
    <div className="tile flex flex-col items-center justify-center text-center py-8 px-4 border border-dashed border-ink-200 bg-ink-50/50">
      <CircleDashed size={20} className="text-ink-500" />
      <div className="mt-2 text-sm text-ink-600">{message}</div>
      {hint && <div className="mt-1 text-xs text-ink-500 max-w-md">{hint}</div>}
    </div>
  );
}
