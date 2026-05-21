'use client';

/**
 * U194 — Breadcrumb back-link.
 *
 * Reads ?from=... query param so drill-down pages can return to where they came.
 */
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import { ArrowLeft } from 'lucide-react';

const DEFAULT_LABELS: Record<string, string> = {
  '/': 'Dashboard',
  '/staff': 'Staff',
  '/restaurant': 'Restaurant',
  '/bar': 'Bar',
  '/cafe': 'Cafe',
  '/rooms': 'Rooms',
  '/sales': 'Sales',
  '/tasks': 'Tasks',
  '/admin': 'Admin',
  '/comms': 'Reviews',
  '/backend': 'Backend',
};

export function Breadcrumb({ defaultBack = '/', defaultLabel = 'Dashboard' }: { defaultBack?: string; defaultLabel?: string }) {
  const sp = useSearchParams();
  const from = sp.get('from') || defaultBack;
  const label = DEFAULT_LABELS[from] || defaultLabel;

  return (
    <div className="mb-3">
      <Link
        href={from}
        className="inline-flex items-center gap-1 text-xs text-ink-500 hover:text-amber-500 transition-colors"
      >
        <ArrowLeft className="w-3 h-3" />
        <span>Back to {label}</span>
      </Link>
    </div>
  );
}
