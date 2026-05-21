'use client';

/**
 * U191 — Contextual empty state.
 *
 * Reads slug metadata (empty_state_md from query_whitelist) to render
 * the per-slug "why this is empty" message instead of a generic placeholder.
 */
interface EmptyStateProps {
  slug?: string;
  /** Slug-specific message override (falls back to db-loaded value) */
  message?: string;
  /** Optional extra context appended below message */
  hint?: string;
}

export function EmptyState({ slug, message, hint }: EmptyStateProps) {
  const text = message ?? (
    slug ? <SlugEmptyMessage slug={slug} fallback={`No data for ${slug}.`} /> : 'No data yet.'
  );

  return (
    <div className="p-4 text-center text-sm text-ink-500 italic border border-dashed border-ink-300 rounded">
      <div>{text}</div>
      {hint && <div className="mt-1 text-xs text-ink-400">{hint}</div>}
    </div>
  );
}

import { useEffect, useState } from 'react';

function SlugEmptyMessage({ slug, fallback }: { slug: string; fallback: string }) {
  const [msg, setMsg] = useState<string | null>(null);
  useEffect(() => {
    fetch(`${process.env.NEXT_PUBLIC_BASE_PATH || ''}/api/slug-meta/${slug}`)
      .then(r => r.json())
      .then(d => setMsg(d.empty_state_md || null))
      .catch(() => setMsg(null));
  }, [slug]);
  return <>{msg ?? fallback}</>;
}
