'use client';

import { useState, useCallback, useRef, useEffect } from 'react';
import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import {
  Search, ExternalLink, ChevronDown, ChevronUp, ArrowUpDown,
  ChevronLeft, ChevronRight, X, Paperclip, Flag,
} from 'lucide-react';

interface EmailRow {
  id: number;
  gmail_message_id: string;
  account: string;
  sender: string;
  from_address: string;
  subject: string;
  body_preview: string;
  received_at: string;
  classification: string | null;
  has_attachment: boolean;
  action_required: boolean;
  total_count: string | number;
}
interface EmailDetailRow {
  id: number;
  gmail_message_id: string;
  account: string;
  from_address: string;
  sender: string;
  subject: string;
  body: string | null;
  received_at: string;
  classification: string | null;
  has_attachment: boolean;
  action_required: boolean;
  requires_human: boolean;
  realm: string;
}
interface AccountFacet { account: string; n: string | number }
interface ClassFacet { classification: string; n: string | number }

const CLASS_COLORS: Record<string, string> = {
  urgent: 'bg-red-500/20 text-red-400',
  important: 'bg-amber-500/20 text-amber-400',
  newsletter: 'bg-blue-500/20 text-blue-400',
  promotional: 'bg-purple-500/20 text-purple-400',
  notification: 'bg-cyan-500/20 text-cyan-400',
  spam: 'bg-ink-500/20 text-ink-400',
  personal: 'bg-emerald-500/20 text-emerald-400',
};

const PAGE_SIZE = 50;

type SortKey = 'date' | 'sender' | 'subject' | 'account';
const SORT_FOR = (key: SortKey, dir: 'asc' | 'desc'): string =>
  key === 'date' ? (dir === 'asc' ? 'date_asc' : 'date_desc')
  : key === 'account' ? 'account_asc'
  : `${key}_${dir}`;

function fmtDate(s: string | null): string {
  return s ? new Date(s).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }) : '-';
}
function fmtDateTime(s: string | null): string {
  return s ? new Date(s).toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '-';
}

function EmailDetail({ id }: { id: number }) {
  const detail = useSlug<EmailDetailRow>('email_detail', { id }, { refetchInterval: 0 });
  const d = detail.data?.[0];
  if (detail.isLoading) return <div className="text-xs text-ink-500 py-2">Loading full email…</div>;
  if (!d) return <div className="text-xs text-ink-500 py-2">Could not load this email.</div>;
  return (
    <>
      <div className="grid grid-cols-1 sm:grid-cols-4 gap-4 mb-3">
        <div>
          <div className="text-2xs text-ink-500 uppercase tracking-wider">From</div>
          <div className="text-sm text-ink-800 break-all">{d.from_address || d.sender || '-'}</div>
        </div>
        <div>
          <div className="text-2xs text-ink-500 uppercase tracking-wider">Account</div>
          <div className="text-sm text-ink-800">{d.account}</div>
        </div>
        <div>
          <div className="text-2xs text-ink-500 uppercase tracking-wider">Received</div>
          <div className="text-sm text-ink-800">{fmtDateTime(d.received_at)}</div>
        </div>
        <div>
          <div className="text-2xs text-ink-500 uppercase tracking-wider">Flags</div>
          <div className="text-sm text-ink-800 flex flex-wrap gap-1.5">
            {d.classification && <span className={`px-1.5 py-0.5 rounded text-2xs ${CLASS_COLORS[d.classification] || 'bg-ink-500/20 text-ink-400'}`}>{d.classification}</span>}
            {d.has_attachment && <span className="text-ink-500 inline-flex items-center gap-0.5 text-2xs"><Paperclip size={10} />attach</span>}
            {d.action_required && <span className="text-amber-500 inline-flex items-center gap-0.5 text-2xs"><Flag size={10} />action</span>}
            <span className="text-ink-400 text-2xs">{d.realm}</span>
          </div>
        </div>
      </div>
      <div className="mb-2">
        <div className="text-2xs text-ink-500 uppercase tracking-wider mb-1">Subject</div>
        <div className="text-sm font-semibold text-ink-900">{d.subject || '(no subject)'}</div>
      </div>
      <div>
        <div className="text-2xs text-ink-500 uppercase tracking-wider mb-1">Body</div>
        <div className="text-sm text-ink-700 whitespace-pre-wrap leading-relaxed max-h-[28rem] overflow-y-auto">
          {d.body || '(empty)'}
        </div>
      </div>
      <div className="mt-3">
        <a href={`https://mail.google.com/mail/u/0/#all/${d.gmail_message_id}`} target="_blank" rel="noopener noreferrer"
           className="inline-flex items-center gap-1 text-xs text-amber-500 hover:text-amber-400">
          <ExternalLink size={12} /> Open in Gmail
        </a>
      </div>
    </>
  );
}

export default function EmailsPage() {
  const [searchInput, setSearchInput] = useState('');
  const [q, setQ] = useState('');
  const [account, setAccount] = useState('');
  const [classification, setClassification] = useState('');
  const [attach, setAttach] = useState('');       // '', '1', '0'
  const [flagged, setFlagged] = useState('');      // '', '1'
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [sortKey, setSortKey] = useState<SortKey>('date');
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('desc');
  const [page, setPage] = useState(0);
  const [expandedId, setExpandedId] = useState<number | null>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Debounced search
  const handleSearch = useCallback((v: string) => {
    setSearchInput(v);
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => setQ(v), 450);
  }, []);
  const handleKey = useCallback((e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') { if (debounceRef.current) clearTimeout(debounceRef.current); setQ(searchInput); }
  }, [searchInput]);

  // Any filter/sort change resets to page 0
  useEffect(() => { setPage(0); }, [q, account, classification, attach, flagged, dateFrom, dateTo, sortKey, sortDir]);

  const sort = SORT_FOR(sortKey, sortDir);
  const emails = useSlug<EmailRow>('emails_browse', {
    q, account, classification, attach, flagged,
    date_from: dateFrom, date_to: dateTo, sort,
    limit: PAGE_SIZE, offset: page * PAGE_SIZE,
  }, { refetchInterval: 0 });
  const accounts = useSlug<AccountFacet>('emails_accounts', {}, { refetchInterval: 0 });
  const classes = useSlug<ClassFacet>('emails_classifications', {}, { refetchInterval: 0 });

  const rows = emails.data ?? [];
  const total = rows.length ? Number(rows[0].total_count) : 0;
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const anyFilter = !!(q || account || classification || attach || flagged || dateFrom || dateTo);

  const clearAll = () => {
    setSearchInput(''); setQ(''); setAccount(''); setClassification('');
    setAttach(''); setFlagged(''); setDateFrom(''); setDateTo('');
  };

  const toggleSort = (key: SortKey) => {
    if (sortKey === key) setSortDir(d => (d === 'asc' ? 'desc' : 'asc'));
    else { setSortKey(key); setSortDir(key === 'date' ? 'desc' : 'asc'); }
  };
  const SortIcon = ({ k }: { k: SortKey }) =>
    sortKey !== k ? <ArrowUpDown size={11} className="text-ink-400 inline" />
    : sortDir === 'asc' ? <ChevronUp size={12} className="text-amber-500 inline" />
    : <ChevronDown size={12} className="text-amber-500 inline" />;

  const selectCls = 'px-2.5 py-2 tile text-sm text-ink-800 border border-ink-200 rounded-lg focus:outline-none focus:border-amber-500 bg-ink-0';

  return (
    <div className="space-y-6">
      <SandboxWrapper id="personal.emails" label="Emails">
        <Section title="Emails">
          {/* Controls */}
          <div className="space-y-3 mb-4">
            <div className="flex flex-col sm:flex-row gap-3">
              <div className="relative flex-1">
                <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-ink-400" />
                <input
                  type="text" value={searchInput}
                  onChange={(e) => handleSearch(e.target.value)} onKeyDown={handleKey}
                  placeholder="Search subject, sender, or body…"
                  className="w-full pl-9 pr-3 py-2 tile text-sm text-ink-900 placeholder:text-ink-500 border border-ink-200 rounded-lg focus:outline-none focus:border-amber-500 bg-ink-0"
                />
              </div>
              {anyFilter && (
                <button onClick={clearAll}
                  className="inline-flex items-center justify-center gap-1 px-3 py-2 text-sm text-ink-600 hover:text-ink-900 border border-ink-200 rounded-lg tile">
                  <X size={14} /> Clear
                </button>
              )}
            </div>
            <div className="flex flex-wrap gap-2">
              <select value={account} onChange={(e) => setAccount(e.target.value)} className={selectCls}>
                <option value="">All accounts</option>
                {(accounts.data ?? []).map((a) => (
                  <option key={a.account} value={a.account}>{a.account} ({a.n})</option>
                ))}
              </select>
              <select value={classification} onChange={(e) => setClassification(e.target.value)} className={selectCls}>
                <option value="">All types</option>
                {(classes.data ?? []).map((c) => (
                  <option key={c.classification} value={c.classification}>{c.classification} ({c.n})</option>
                ))}
              </select>
              <select value={attach} onChange={(e) => setAttach(e.target.value)} className={selectCls}>
                <option value="">Attachment: any</option>
                <option value="1">Has attachment</option>
                <option value="0">No attachment</option>
              </select>
              <select value={flagged} onChange={(e) => setFlagged(e.target.value)} className={selectCls}>
                <option value="">Action: any</option>
                <option value="1">Action required</option>
              </select>
              <label className="inline-flex items-center gap-1.5 text-xs text-ink-500">
                From
                <input type="date" value={dateFrom} onChange={(e) => setDateFrom(e.target.value)} className={selectCls} />
              </label>
              <label className="inline-flex items-center gap-1.5 text-xs text-ink-500">
                To
                <input type="date" value={dateTo} onChange={(e) => setDateTo(e.target.value)} className={selectCls} />
              </label>
            </div>
          </div>

          {/* Results */}
          {emails.isLoading ? (
            <PlaceholderState message="Loading emails…" />
          ) : emails.isError ? (
            <PlaceholderState message="Could not load emails." hint="The query may have timed out — try narrowing the filters." />
          ) : rows.length === 0 ? (
            <PlaceholderState
              message={anyFilter ? 'No emails match these filters.' : 'No emails found.'}
              hint={anyFilter ? 'Try different keywords or clear the filters.' : 'Emails appear here once ingested.'}
            />
          ) : (
            <div className="tile overflow-x-auto">
              <table className="w-full text-xs">
                <thead className="text-ink-500 uppercase tracking-wider text-xs sticky top-0 bg-ink-50">
                  <tr>
                    <th className="px-2 py-1.5 text-left w-4"></th>
                    <th className="px-2 py-1.5 text-left cursor-pointer select-none hover:text-ink-700" onClick={() => toggleSort('sender')}>Sender <SortIcon k="sender" /></th>
                    <th className="px-2 py-1.5 text-left cursor-pointer select-none hover:text-ink-700" onClick={() => toggleSort('subject')}>Subject <SortIcon k="subject" /></th>
                    <th className="px-2 py-1.5 text-left hidden md:table-cell">Preview</th>
                    <th className="px-2 py-1.5 text-left cursor-pointer select-none hover:text-ink-700 hidden lg:table-cell" onClick={() => toggleSort('account')}>Account <SortIcon k="account" /></th>
                    <th className="px-2 py-1.5 text-right cursor-pointer select-none hover:text-ink-700 hidden sm:table-cell whitespace-nowrap" onClick={() => toggleSort('date')}>Date <SortIcon k="date" /></th>
                    <th className="px-2 py-1.5 text-left hidden sm:table-cell">Type</th>
                    <th className="px-2 py-1.5 text-right w-8"></th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((email) => {
                    const isExpanded = expandedId === email.id;
                    const clsColor = email.classification ? CLASS_COLORS[email.classification] || 'bg-ink-500/20 text-ink-400' : '';
                    return (
                      <>
                        <tr key={email.id}
                          onClick={() => setExpandedId(isExpanded ? null : email.id)}
                          className={`border-t border-ink-200 hover:bg-ink-100/50 cursor-pointer transition-colors ${isExpanded ? 'bg-ink-100/50' : ''}`}>
                          <td className="px-2 py-1.5">
                            {isExpanded ? <ChevronUp size={12} className="text-ink-400" /> : <ChevronDown size={12} className="text-ink-400" />}
                          </td>
                          <td className="px-2 py-1.5 text-ink-700 max-w-[150px] truncate" title={email.sender || email.from_address}>
                            {email.sender || email.from_address || '-'}
                          </td>
                          <td className="px-2 py-1.5">
                            <div className="flex items-center gap-1.5">
                              <span className="font-semibold text-ink-900 truncate max-w-[260px] block">{email.subject || '(no subject)'}</span>
                              {email.has_attachment && <Paperclip size={11} className="text-ink-400 flex-shrink-0" />}
                              {email.action_required && <Flag size={11} className="text-amber-500 flex-shrink-0" />}
                            </div>
                          </td>
                          <td className="px-2 py-1.5 text-ink-500 hidden md:table-cell max-w-[280px] truncate">{(email.body_preview || '').slice(0, 140)}</td>
                          <td className="px-2 py-1.5 text-ink-500 hidden lg:table-cell">{email.account}</td>
                          <td className="px-2 py-1.5 text-right text-ink-500 whitespace-nowrap hidden sm:table-cell">{fmtDate(email.received_at)}</td>
                          <td className="px-2 py-1.5 hidden sm:table-cell">
                            {email.classification
                              ? <span className={`px-1.5 py-0.5 rounded text-2xs ${clsColor}`}>{email.classification}</span>
                              : <span className="text-ink-400">-</span>}
                          </td>
                          <td className="px-2 py-1.5 text-right">
                            <a href={`https://mail.google.com/mail/u/0/#all/${email.gmail_message_id}`}
                               target="_blank" rel="noopener noreferrer" onClick={(e) => e.stopPropagation()}
                               className="inline-flex items-center text-ink-400 hover:text-ink-600 transition-colors" title="Open in Gmail">
                              <ExternalLink size={12} />
                            </a>
                          </td>
                        </tr>
                        {isExpanded && (
                          <tr key={`${email.id}-d`} className="border-t border-ink-200 bg-ink-50/50">
                            <td colSpan={8} className="px-4 py-3"><EmailDetail id={email.id} /></td>
                          </tr>
                        )}
                      </>
                    );
                  })}
                </tbody>
              </table>

              {/* Footer / pagination */}
              <div className="flex items-center justify-between px-2 py-2 text-xs text-ink-500 border-t border-ink-200">
                <span>
                  {total.toLocaleString('en-GB')} email{total !== 1 ? 's' : ''}
                  {anyFilter ? ' matching' : ''} · showing {page * PAGE_SIZE + 1}–{Math.min((page + 1) * PAGE_SIZE, total)}
                </span>
                <div className="flex items-center gap-2">
                  <button disabled={page === 0} onClick={() => { setPage(p => Math.max(0, p - 1)); setExpandedId(null); }}
                    className="inline-flex items-center gap-0.5 px-2 py-1 rounded border border-ink-200 disabled:opacity-40 disabled:cursor-not-allowed hover:bg-ink-100">
                    <ChevronLeft size={12} /> Prev
                  </button>
                  <span className="tabular-nums">Page {page + 1} / {totalPages}</span>
                  <button disabled={page + 1 >= totalPages} onClick={() => { setPage(p => p + 1); setExpandedId(null); }}
                    className="inline-flex items-center gap-0.5 px-2 py-1 rounded border border-ink-200 disabled:opacity-40 disabled:cursor-not-allowed hover:bg-ink-100">
                    Next <ChevronRight size={12} />
                  </button>
                </div>
              </div>
            </div>
          )}
        </Section>
      </SandboxWrapper>
    </div>
  );
}
