'use client';

import { useState, useCallback, useRef } from 'react';
import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import { Search, ExternalLink, ChevronDown, ChevronUp, Mail } from 'lucide-react';

interface EmailRow {
  id: number;
  gmail_message_id: string;
  account: string;
  sender: string;
  subject: string;
  body_preview: string;
  received_at: string;
  classification: string | null;
  has_attachment: boolean;
}

const CLASS_COLORS: Record<string, string> = {
  urgent: 'bg-red-500/20 text-red-400',
  important: 'bg-amber-500/20 text-amber-400',
  newsletter: 'bg-blue-500/20 text-blue-400',
  promotional: 'bg-purple-500/20 text-purple-400',
  notification: 'bg-cyan-500/20 text-cyan-400',
  spam: 'bg-ink-500/20 text-ink-400',
  personal: 'bg-emerald-500/20 text-emerald-400',
};

export default function EmailsPage() {
  const [searchQuery, setSearchQuery] = useState('');
  const [debouncedQuery, setDebouncedQuery] = useState('');
  const [expandedId, setExpandedId] = useState<number | null>(null);
  const [accountFilter, setAccountFilter] = useState<string>('all');
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const handleSearchChange = useCallback((value: string) => {
    setSearchQuery(value);
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => {
      setDebouncedQuery(value);
    }, 500);
  }, []);

  const handleKeyDown = useCallback((e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      if (debounceRef.current) clearTimeout(debounceRef.current);
      setDebouncedQuery(searchQuery);
    }
  }, [searchQuery]);

  const emails = useSlug<EmailRow>('email_search', { query: debouncedQuery, limit: 50 }, { refetchInterval: 0 });

  const accounts = [...new Set((emails.data ?? []).map((e) => e.account))].sort();

  const filtered = (emails.data ?? []).filter(
    (e) => accountFilter === 'all' || e.account === accountFilter
  );

  return (
    <div className="space-y-6">
      <SandboxWrapper id="personal.emails" label="Email search">
        <Section title="Email search">
          {/* Search bar */}
          <div className="flex flex-col sm:flex-row gap-3 mb-4">
            <div className="relative flex-1">
              <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-ink-400" />
              <input
                type="text"
                value={searchQuery}
                onChange={(e) => handleSearchChange(e.target.value)}
                onKeyDown={handleKeyDown}
                placeholder="Search emails by subject, sender, or content…"
                className="w-full pl-9 pr-3 py-2 tile text-sm text-ink-900 placeholder:text-ink-500 border border-ink-200 rounded-lg focus:outline-none focus:border-amber-500 bg-ink-0"
              />
            </div>
            {accounts.length > 1 && (
              <select
                value={accountFilter}
                onChange={(e) => setAccountFilter(e.target.value)}
                className="px-3 py-2 tile text-sm text-ink-800 border border-ink-200 rounded-lg focus:outline-none focus:border-amber-500 bg-ink-0"
              >
                <option value="all">All accounts</option>
                {accounts.map((a) => (
                  <option key={a} value={a}>{a}</option>
                ))}
              </select>
            )}
          </div>

          {/* Results */}
          {emails.isLoading ? (
            <PlaceholderState message="Searching emails…" />
          ) : filtered.length === 0 ? (
            <PlaceholderState
              message={debouncedQuery ? 'No emails match your search.' : 'No emails found.'}
              hint={debouncedQuery ? 'Try different keywords or clear the search.' : 'Personal emails will appear here when ingested.'}
            />
          ) : (
            <div className="tile overflow-x-auto">
              <table className="w-full text-xs">
                <thead className="text-ink-500 uppercase tracking-wider text-xs sticky top-0 bg-ink-50">
                  <tr>
                    <th className="px-2 py-1.5 text-left w-4"></th>
                    <th className="px-2 py-1.5 text-left">Sender</th>
                    <th className="px-2 py-1.5 text-left">Subject</th>
                    <th className="px-2 py-1.5 text-left hidden md:table-cell">Preview</th>
                    <th className="px-2 py-1.5 text-right hidden sm:table-cell">Date</th>
                    <th className="px-2 py-1.5 text-left hidden sm:table-cell">Type</th>
                    <th className="px-2 py-1.5 text-right w-10"></th>
                  </tr>
                </thead>
                <tbody>
                  {filtered.map((email) => {
                    const isExpanded = expandedId === email.id;
                    const date = email.received_at
                      ? new Date(email.received_at).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })
                      : '-';
                    const clsColor = email.classification ? CLASS_COLORS[email.classification] || 'bg-ink-500/20 text-ink-400' : '';
                    return (
                      <>
                        <tr
                          key={email.id}
                          onClick={() => setExpandedId(isExpanded ? null : email.id)}
                          className="border-t border-ink-200 hover:bg-ink-100/50 cursor-pointer transition-colors"
                        >
                          <td className="px-2 py-1.5">
                            {isExpanded ? <ChevronUp size={12} className="text-ink-400" /> : <ChevronDown size={12} className="text-ink-400" />}
                          </td>
                          <td className="px-2 py-1.5 text-ink-700 max-w-[140px] truncate" title={email.sender}>
                            {email.sender || '-'}
                          </td>
                          <td className="px-2 py-1.5">
                            <div className="flex items-center gap-1.5">
                              <span className="font-semibold text-ink-900 truncate max-w-[250px] block">
                                {email.subject || '(no subject)'}
                              </span>
                              {email.has_attachment && (
                                <span className="text-ink-400 flex-shrink-0" title="Has attachment">📎</span>
                              )}
                            </div>
                          </td>
                          <td className="px-2 py-1.5 text-ink-500 hidden md:table-cell max-w-[300px] truncate">
                            {(email.body_preview || '').substring(0, 150)}
                          </td>
                          <td className="px-2 py-1.5 text-right text-ink-500 whitespace-nowrap hidden sm:table-cell">
                            {date}
                          </td>
                          <td className="px-2 py-1.5 hidden sm:table-cell">
                            {email.classification ? (
                              <span className={`px-1.5 py-0.5 rounded text-2xs ${clsColor}`}>
                                {email.classification}
                              </span>
                            ) : (
                              <span className="text-ink-400">-</span>
                            )}
                          </td>
                          <td className="px-2 py-1.5 text-right">
                            <a
                              href={`https://mail.google.com/mail/u/0/#inbox/${email.gmail_message_id}`}
                              target="_blank"
                              rel="noopener noreferrer"
                              onClick={(e) => e.stopPropagation()}
                              className="inline-flex items-center gap-1 text-ink-400 hover:text-ink-600 transition-colors"
                              title="Open in Gmail"
                            >
                              <ExternalLink size={12} />
                            </a>
                          </td>
                        </tr>
                        {isExpanded && (
                          <tr key={`${email.id}-detail`} className="border-t border-ink-200 bg-ink-50/50">
                            <td colSpan={7} className="px-4 py-3">
                              <div className="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-3">
                                <div>
                                  <div className="text-2xs text-ink-500 uppercase tracking-wider">From</div>
                                  <div className="text-sm text-ink-800">{email.sender || '-'}</div>
                                </div>
                                <div>
                                  <div className="text-2xs text-ink-500 uppercase tracking-wider">Account</div>
                                  <div className="text-sm text-ink-800">{email.account}</div>
                                </div>
                                <div>
                                  <div className="text-2xs text-ink-500 uppercase tracking-wider">Received</div>
                                  <div className="text-sm text-ink-800">{date}</div>
                                </div>
                              </div>
                              <div className="mb-3">
                                <div className="text-2xs text-ink-500 uppercase tracking-wider mb-1">Subject</div>
                                <div className="text-sm font-semibold text-ink-900">{email.subject || '(no subject)'}</div>
                              </div>
                              <div>
                                <div className="text-2xs text-ink-500 uppercase tracking-wider mb-1">Body</div>
                                <div className="text-sm text-ink-700 whitespace-pre-wrap leading-relaxed">
                                  {email.body_preview || '(empty)'}
                                </div>
                              </div>
                            </td>
                          </tr>
                        )}
                      </>
                    );
                  })}
                </tbody>
              </table>
              <div className="px-2 py-1.5 text-xs text-ink-500 border-t border-ink-200">
                {filtered.length} email{filtered.length !== 1 ? 's' : ''}
                {debouncedQuery ? ` matching "${debouncedQuery}"` : ''}
              </div>
            </div>
          )}
        </Section>
      </SandboxWrapper>
    </div>
  );
}
