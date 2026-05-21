'use client';

import Link from 'next/link';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';
import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { AlertTriangle, ArrowRight } from 'lucide-react';

interface OrphanSummary {
  orphan_count: string;
  overdue_to_forward: string;
  already_forwarded: string;
  gbp_exposure: string;
}

interface OrphanVendor {
  vendor_name: string | null;
  n: number;
  gbp: string;
  oldest: string | null;
  newest: string | null;
}

export function OrphanTile() {
  const summary = useSlug<OrphanSummary>('xero_vs_email_orphans', {}, { refetchInterval: 5 * 60_000 });
  const top     = useSlug<OrphanVendor>('xero_orphans_top_vendors', { limit: 8 }, { refetchInterval: 5 * 60_000 });

  const s = summary.data?.[0];
  const exposure = Number(s?.gbp_exposure ?? 0);
  const overdue  = Number(s?.overdue_to_forward ?? 0);

  return (
    <Section
      title="Xero orphans — invoices in email, missing from Xero"
      action={
        <Link href="/admin/orphans"
              className="text-xs text-amber-500 hover:text-amber-400 inline-flex items-center gap-1">
          View all <ArrowRight size={12} />
        </Link>
      }
    >
      <div className="tile p-0 overflow-hidden">
        <div className="grid grid-cols-2 sm:grid-cols-4 border-b border-ink-200">
          <div className="px-3 py-2.5">
            <div className="text-[10px] uppercase tracking-wider text-ink-500">Exposure</div>
            <div className={'text-lg font-mono ' + (exposure > 0 ? 'text-amber-600' : 'text-ink-800')}>
              {gbp(s?.gbp_exposure)}
            </div>
          </div>
          <div className="px-3 py-2.5">
            <div className="text-[10px] uppercase tracking-wider text-ink-500">Orphans</div>
            <div className="text-lg font-mono text-ink-800">{s?.orphan_count ?? '—'}</div>
          </div>
          <div className="px-3 py-2.5">
            <div className="text-[10px] uppercase tracking-wider text-ink-500">Overdue → Dext</div>
            <div className={'text-lg font-mono ' + (overdue > 0 ? 'text-red-500' : 'text-ink-800')}>
              {s?.overdue_to_forward ?? '—'}
              {overdue > 0 && <AlertTriangle size={14} className="inline ml-1.5 -mt-0.5 text-red-500" />}
            </div>
          </div>
          <div className="px-3 py-2.5">
            <div className="text-[10px] uppercase tracking-wider text-ink-500">Forwarded</div>
            <div className="text-lg font-mono text-ink-800">{s?.already_forwarded ?? '—'}</div>
          </div>
        </div>
        <div className="px-3 py-2">
          <h3 className="text-sm font-medium text-ink-800 mb-2">Top orphan vendors by £</h3>
          {top.isLoading ? (
            <PlaceholderState message="Loading…" />
          ) : top.data && top.data.length > 0 ? (
            <table className="w-full text-sm">
              <thead className="text-xs text-ink-500 uppercase tracking-wider">
                <tr>
                  <th className="text-left font-medium py-1">Vendor</th>
                  <th className="text-right font-medium">£ exposure</th>
                  <th className="text-right font-medium">#</th>
                  <th className="text-left font-medium pl-3">Oldest</th>
                </tr>
              </thead>
              <tbody>
                {top.data.map((v, i) => (
                  <tr key={i} className="border-t border-ink-200">
                    <td className="py-1.5 text-ink-800 max-w-[24rem] truncate">
                      {cleanVendor(v.vendor_name)}
                    </td>
                    <td className="text-right font-mono text-ink-700">{gbp(v.gbp)}</td>
                    <td className="text-right text-xs text-ink-500">{v.n}</td>
                    <td className="pl-3 text-xs font-mono text-ink-500">
                      {v.oldest ? new Date(v.oldest).toLocaleDateString('en-GB') : '—'}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <PlaceholderState message="No orphan vendors — everything in email is in Xero." />
          )}
        </div>
      </div>
    </Section>
  );
}

function cleanVendor(v: string | null): string {
  if (!v) return '—';
  const m = v.match(/^"?([^"<]+?)"?\s*<.*>$/);
  return m ? m[1].trim() : v;
}
