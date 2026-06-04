'use client';

import Link from 'next/link';
import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { OrphanTile } from '@/components/admin/OrphanTile';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';

interface Invoice {
  id: number;
  vendor_name: string | null;
  gross_amount: string | null;
  invoice_date: string;
  status: string;
}

interface Obligation { due_date: string; source: string; label: string; kind: string }

export default function AdminPage() {
  const invs = useSlug<Invoice>('frontend_invoices_recent', {}, { refetchInterval: 5 * 60_000 });
  const obs  = useSlug<Obligation>('obligations_upcoming');

  return (
    <div className="space-y-6">
      <SandboxWrapper id="admin.orphans" label="Xero orphans">
        <OrphanTile />
      </SandboxWrapper>

      <SandboxWrapper id="admin.invoices" label="Invoices">
        <Section title="Recent invoices (30d)" action={<Link href="/app/invoices" className="text-xs text-amber-500 hover:text-amber-400 underline">View all invoices →</Link>}>
          {invs.isLoading ? (
            <PlaceholderState message="Loading invoices…" />
          ) : invs.data && invs.data.length > 0 ? (
            <div className="tile overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="text-xs text-ink-500 uppercase tracking-wider">
                  <tr>
                    <th className="text-left py-2 font-medium">Date</th>
                    <th className="text-left font-medium">Vendor</th>
                    <th className="text-right font-medium">Amount</th>
                    <th className="text-left font-medium">Status</th>
                  </tr>
                </thead>
                <tbody>
                  {invs.data.map((r) => (
                    <tr key={r.id} className="border-t border-ink-200 hover:bg-ink-50">
                      <td className="py-1.5 font-mono text-xs text-ink-700">
                        <Link href={`/admin/invoices/${r.id}`} className="hover:text-amber-500">
                          {new Date(r.invoice_date).toLocaleDateString('en-GB')}
                        </Link>
                      </td>
                      <td className="text-ink-800">
                        <Link href={`/admin/invoices/${r.id}`} className="hover:text-amber-500">
                          {r.vendor_name ?? '—'}
                        </Link>
                      </td>
                      <td className="text-right font-mono text-ink-700">{gbp(r.gross_amount)}</td>
                      <td className="text-xs text-ink-500">{r.status}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <PlaceholderState message="No invoices in the last 30 days." />
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="admin.compliance" label="Compliance calendar">
        <Section title="Compliance / obligations — next 30 days">
          {obs.data && obs.data.length > 0 ? (
            <div className="tile overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="text-xs text-ink-500 uppercase tracking-wider">
                  <tr>
                    <th className="text-left py-2 font-medium">When</th>
                    <th className="text-left font-medium">What</th>
                    <th className="text-left font-medium">Type</th>
                  </tr>
                </thead>
                <tbody>
                  {obs.data.map((r, i) => (
                    <tr key={i} className="border-t border-ink-200">
                      <td className="py-1.5 font-mono text-xs text-ink-700">
                        {new Date(r.due_date).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' })}
                      </td>
                      <td className="font-medium text-ink-900">{r.label}</td>
                      <td className="text-xs text-ink-500">{r.kind}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <PlaceholderState message="No dated obligations in the next 30 days." />
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="admin.external">
        <Section title="External links">
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
            {[
              ['Tanda', 'https://my.workforce.com'],
              ['Caterbook', 'https://caterbook.com'],
              ['ICRTouch BackOffice', 'https://malthouseinn.epos.live'],
              ['Vault', 'https://vault.home-ai.local'],
              ['Grafana', 'http://homeai-grafana:3000'],
              ['n8n', 'http://homeai-n8n:5678'],
            ].map(([label, url]) => (
              <a key={label} href={url} target="_blank" rel="noreferrer"
                className="tile text-sm hover:text-amber-500">{label} ↗</a>
            ))}
          </div>
        </Section>
      </SandboxWrapper>
    </div>
  );
}
