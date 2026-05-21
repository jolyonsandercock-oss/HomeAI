'use client';

import { use, useState } from 'react';
import Link from 'next/link';
import { useQueryClient } from '@tanstack/react-query';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';
import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { LineRecodePopover } from '@/components/admin/LineRecodePopover';
import { ArrowLeft, FileText, ExternalLink, Pencil } from 'lucide-react';

interface InvoiceHeader {
  id: string;
  vendor_name: string | null;
  vendor_domain: string;
  account: string;
  subject: string;
  received_at: string;
  invoice_date: string | null;
  due_date: string | null;
  delivery_date: string | null;
  gross_amount: string | null;
  net_amount: string | null;
  vat_amount: string | null;
  vat_rate: string | null;
  category_canonical: string | null;
  site: string | null;
  status: string;
  has_pdf: boolean;
  attachment_count: number;
  first_attachment_path: string | null;
  paperless_doc_id: string | null;
  xero_bill_id: string | null;
  forwarded_to_dext_at: string | null;
  extraction_method: string | null;
  extraction_confidence: string | null;
  extracted_at: string | null;
  notes: string | null;
}

interface InvoiceLine {
  line_id: string;
  line_no: number;
  description: string;
  qty: string | null;
  unit: string | null;
  unit_price: string | null;
  line_net: string | null;
  line_vat: string | null;
  line_gross: string | null;
  canonical_id: string | null;
  canonical_family: string | null;
  canonical_name: string | null;
  suggested_family?: string | null;
  department?: string | null;
  extracted_by: string | null;
  extraction_confidence: string | null;
}

export default function InvoiceDrilldown({ params }: { params: Promise<{ id: string }> | { id: string } }) {
  // Next.js 14: params is sync; 15+ async. Support both.
  const { id } = ('then' in (params as object) ? use(params as Promise<{ id: string }>) : (params as { id: string }));
  const header = useSlug<InvoiceHeader>('invoice_header', { invoice_id: id });
  const lines  = useSlug<InvoiceLine>  ('invoice_lines',  { invoice_id: id });
  const qc = useQueryClient();
  const [recoding, setRecoding] = useState<InvoiceLine | null>(null);

  const h = header.data?.[0];

  return (
    <div className="space-y-6">
      <div>
        <Link href="/admin" className="text-xs text-ink-500 hover:text-amber-500 inline-flex items-center gap-1">
          <ArrowLeft size={12} /> Back to admin
        </Link>
      </div>

      {header.isLoading ? (
        <PlaceholderState message="Loading invoice…" />
      ) : !h ? (
        <PlaceholderState message={`Invoice #${id} not found.`} />
      ) : (
        <>
          <Section title={`Invoice #${h.id} — ${cleanVendor(h.vendor_name) || h.vendor_domain}`}>
            <div className="tile p-0 overflow-hidden">
              <div className="px-4 py-3 border-b border-ink-200 flex flex-wrap gap-2 items-center">
                <StatusPill status={h.status} />
                {h.xero_bill_id && <Pill tone="emerald">Linked → Xero bill #{h.xero_bill_id}</Pill>}
                {h.paperless_doc_id && <Pill tone="ink">Paperless #{h.paperless_doc_id}</Pill>}
                {h.forwarded_to_dext_at && <Pill tone="amber">Forwarded to Dext {new Date(h.forwarded_to_dext_at).toLocaleDateString('en-GB')}</Pill>}
                {h.site && <Pill tone="ink">{h.site}</Pill>}
                {h.category_canonical && <Pill tone="ink">{h.category_canonical}</Pill>}
              </div>

              <div className="grid grid-cols-2 sm:grid-cols-4 border-b border-ink-200">
                <Cell label="Gross" value={gbp(h.gross_amount, 2)} />
                <Cell label="Net"   value={gbp(h.net_amount, 2)} />
                <Cell label="VAT"   value={gbp(h.vat_amount, 2)} sub={h.vat_rate ? `${h.vat_rate}%` : ''} />
                <Cell label="Lines" value={String(lines.data?.length ?? '—')} />
              </div>

              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 border-b border-ink-200">
                <Cell label="Invoice date"
                      value={h.invoice_date ? new Date(h.invoice_date).toLocaleDateString('en-GB') : '—'} />
                <Cell label="Due date"
                      value={h.due_date ? new Date(h.due_date).toLocaleDateString('en-GB') : '—'} />
                <Cell label="Received"
                      value={new Date(h.received_at).toLocaleDateString('en-GB')}
                      sub={new Date(h.received_at).toLocaleTimeString('en-GB', {hour: '2-digit', minute: '2-digit'})} />
                <Cell label="Extracted by"
                      value={h.extraction_method || '—'}
                      sub={h.extraction_confidence ? `conf ${h.extraction_confidence}` : ''} />
              </div>

              <div className="px-4 py-2 text-xs text-ink-500 break-all">
                <div className="text-[10px] uppercase tracking-wider mb-0.5">Subject</div>
                {h.subject}
              </div>
              {h.notes && (
                <div className="px-4 py-2 text-xs text-ink-500 border-t border-ink-200 whitespace-pre-wrap">
                  <div className="text-[10px] uppercase tracking-wider mb-0.5">Notes</div>
                  {h.notes}
                </div>
              )}
              <div className="px-4 py-3 border-t border-ink-200 flex gap-2 flex-wrap">
                {h.has_pdf && (
                  <a href={`http://100.104.82.53:8090/api/invoice/${h.id}/pdf`}
                     target="_blank" rel="noreferrer"
                     className="text-xs px-2.5 py-1.5 bg-ink-100 hover:bg-ink-200 rounded-md inline-flex items-center gap-1">
                    <FileText size={12} /> Open PDF
                  </a>
                )}
                <a href={`http://100.104.82.53:8090/invoices?id=${h.id}`}
                   target="_blank" rel="noreferrer"
                   className="text-xs px-2.5 py-1.5 bg-ink-100 hover:bg-ink-200 rounded-md inline-flex items-center gap-1">
                  Open in build-dashboard <ExternalLink size={12} />
                </a>
              </div>
            </div>
          </Section>

          <Section title="Line items">
            {lines.isLoading ? (
              <PlaceholderState message="Loading lines…" />
            ) : lines.data && lines.data.length > 0 ? (
              <div className="tile p-0 overflow-x-auto">
                <table className="w-full text-sm">
                  <thead className="text-xs text-ink-500 uppercase tracking-wider bg-ink-50">
                    <tr>
                      <th className="text-right py-2 px-2 font-medium">#</th>
                      <th className="text-left font-medium">Description</th>
                      <th className="text-right font-medium px-2">Qty</th>
                      <th className="text-left font-medium">Unit</th>
                      <th className="text-right font-medium px-2">Unit £</th>
                      <th className="text-right font-medium px-2">Net</th>
                      <th className="text-right font-medium px-2">VAT</th>
                      <th className="text-right font-medium px-2">Gross</th>
                      <th className="text-left font-medium px-2">Department</th>
                      <th className="text-left font-medium px-2">Family</th>
                      <th className="text-right font-medium px-2">Conf</th>
                      <th className="text-center font-medium px-2"> </th>
                    </tr>
                  </thead>
                  <tbody>
                    {lines.data.map((l) => (
                      <tr key={l.line_id} className="border-t border-ink-200 hover:bg-ink-50">
                        <td className="text-right text-xs text-ink-500 px-2">{l.line_no}</td>
                        <td className="text-ink-800 max-w-[24rem]">{l.description || '—'}</td>
                        <td className="text-right font-mono text-ink-700 px-2">{fmtNum(l.qty, 0)}</td>
                        <td className="text-xs text-ink-500">{l.unit || '—'}</td>
                        <td className="text-right font-mono text-ink-700 px-2">{gbp(l.unit_price, 4)}</td>
                        <td className="text-right font-mono text-ink-700 px-2">{gbp(l.line_net, 2)}</td>
                        <td className="text-right font-mono text-ink-500 px-2">{gbp(l.line_vat, 2)}</td>
                        <td className="text-right font-mono text-ink-800 px-2">{gbp(l.line_gross, 2)}</td>
                        <td className="text-xs px-2">
                          {l.department ? (
                            <span className="capitalize text-amber-500">{l.department}</span>
                          ) : (
                            <span className="text-ink-500 italic">—</span>
                          )}
                        </td>
                        <td className="text-xs px-2">
                          {l.canonical_family ? (
                            <span className="text-ink-700">{l.canonical_family}</span>
                          ) : l.suggested_family ? (
                            <span className="text-emerald-500">{l.suggested_family} <span className="text-ink-500">(suggested)</span></span>
                          ) : (
                            <span className="text-ink-500 italic">unclassified</span>
                          )}
                          {l.canonical_name && <span className="text-ink-500"> · {l.canonical_name}</span>}
                        </td>
                        <td className="text-right text-xs text-ink-500 px-2 font-mono">{l.extraction_confidence ?? '—'}</td>
                        <td className="text-center px-2">
                          <button
                            onClick={() => setRecoding(l)}
                            className="text-xs text-ink-500 hover:text-amber-500 inline-flex items-center gap-1 border border-ink-200 rounded px-1.5 py-0.5"
                            title="Re-code department / family">
                            <Pencil size={11} /> code
                          </button>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : (
              <PlaceholderState
                message="No line items extracted yet."
                hint="Either Haiku hasn't run on this invoice or the PDF was un-parseable. Line extraction is part of the U138-E backfill." />
            )}
          </Section>
        </>
      )}

      {recoding && (
        <LineRecodePopover
          lineId={Number(recoding.line_id)}
          currentDepartment={recoding.department ?? null}
          currentFamily={recoding.canonical_family ?? recoding.suggested_family ?? null}
          currentDescription={recoding.description}
          onClose={() => setRecoding(null)}
          onSaved={() => {
            setRecoding(null);
            qc.invalidateQueries({ queryKey: ['slug', 'invoice_lines'] });
          }}
        />
      )}
    </div>
  );
}

function Cell({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="px-3 py-2.5">
      <div className="text-[10px] uppercase tracking-wider text-ink-500">{label}</div>
      <div className="text-base font-mono text-ink-800">{value}</div>
      {sub && <div className="text-xs text-ink-500 mt-0.5">{sub}</div>}
    </div>
  );
}

function Pill({ tone, children }: { tone: 'emerald'|'amber'|'red'|'ink'; children: React.ReactNode }) {
  const toneCls =
    tone === 'emerald' ? 'bg-emerald-500/15 text-emerald-400' :
    tone === 'amber'   ? 'bg-amber-500/15 text-amber-500' :
    tone === 'red'     ? 'bg-red-500/15 text-red-400' :
                         'bg-ink-100 text-ink-700';
  return <span className={'text-xs px-2 py-0.5 rounded ' + toneCls}>{children}</span>;
}

function StatusPill({ status }: { status: string }) {
  const tone =
    status === 'extracted' ? 'emerald' :
    status === 'needs_review' ? 'amber' :
    status === 'new' ? 'ink' :
    status === 'ignored' ? 'red' :
    'ink';
  return <Pill tone={tone as 'emerald'|'amber'|'red'|'ink'}>{status}</Pill>;
}

function fmtNum(n: string | null, decimals = 2): string {
  if (n === null || n === undefined) return '—';
  const num = parseFloat(n);
  if (!Number.isFinite(num)) return '—';
  return num.toLocaleString('en-GB', { minimumFractionDigits: 0, maximumFractionDigits: decimals });
}

function cleanVendor(v: string | null): string | null {
  if (!v) return null;
  const m = v.match(/^"?([^"<]+?)"?\s*<.*>$/);
  return m ? m[1].trim() : v;
}
