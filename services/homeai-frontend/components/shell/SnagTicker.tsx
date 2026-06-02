'use client';

import { useSlug } from '@/lib/hooks';

export function SnagTicker() {
  const snags = useSlug<any>('snag_inbox_pending', {}, { refetchInterval: 10_000 });
  const pending = (snags.data ?? []).filter((s: any) => s.status === 'pending').length;
  const done = (snags.data ?? []).filter((s: any) => s.status === 'done').length;

  return (
    <div className="border-t border-ink-200 bg-ink-50 px-3 py-2">
      <div className="flex items-center justify-between text-2xs">
        <div className="flex items-center gap-1.5">
          <span className="w-1.5 h-1.5 rounded-full bg-amber-400 inline-block" />
          <span className="text-ink-500">{pending} pending</span>
        </div>
        <div className="flex items-center gap-1.5">
          <span className="w-1.5 h-1.5 rounded-full bg-green-400 inline-block" />
          <span className="text-ink-500">{done} done</span>
        </div>
      </div>
    </div>
  );
}
