'use client';

import { useMemo, useState } from 'react';
import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { KPICard } from '@/components/ui/KPICard';
import { useSlug } from '@/lib/hooks';
import { SparkLine } from '@/components/ui/SparkLine';
import { Star, ExternalLink, ArrowUpDown, ChevronUp, ChevronDown } from 'lucide-react';

interface ReviewRow {
  posted_at: string | null;
  source: string;
  location: string;
  rating: number | null;
  reviewer_name: string | null;
  body_excerpt: string | null;
  review_url: string | null;
  status: string;
}
interface ReviewAvg {
  source: string;
  location: string;
  avg_rating: string | number | null;
  review_count: number;
}
interface ReviewSpark {
  rating_spark: number[];
  count_spark: string[];
  total_reviews_30d: number;
  avg_rating_30d: string | null;
}
interface EmailKpis {
  tasks_open: string;
  instructions_pending: string;
  last_instruction_at: string | null;
}
interface ReviewSummaryRow {
  source: string;
  label: string;
  avg_last_7d: string | null;
  avg_prev_7d: string | null;
  avg_30d: string | null;
  avg_all_time: string | null;
  count_last_7d: number | string;
  count_30d: number | string;
  count_all_time: number | string;
  last_review_at: string | null;
  trend_4w: (string | number)[];
}
interface ReviewTableRow {
  review_id: string;
  posted_at: string | null;
  source: string;
  rating5: string | number | null;
  rating_raw: number | null;
  reviewer_name: string | null;
  body_excerpt: string | null;
  review_url: string | null;
  status: string;
}
interface WaOutboundRow {
  id: number;
  account: string;
  target_label: string;
  body: string;
  draft_reason: string | null;
  created_at: string;
}

function sourceLabel(src: string): string {
  if (src === 'google') return 'Google';
  if (src === 'tripadvisor') return 'TripAdvisor';
  if (src === 'booking_com') return 'Booking.com';
  return src;
}

function stars(rating: number | null): string {
  if (rating == null) return '';
  const r = Math.round(rating);
  return '★'.repeat(r) + '☆'.repeat(Math.max(0, 5 - r));
}

export default function CommsPage() {
  const recent = useSlug<ReviewRow>('reviews_recent', {}, { refetchInterval: 10 * 60_000 });
  const avg30  = useSlug<ReviewAvg>('reviews_average_30d', {}, { refetchInterval: 10 * 60_000 });
  const spark  = useSlug<ReviewSpark>('reviews_rating_spark_30d', {}, { refetchInterval: 10 * 60_000 });
  const email  = useSlug<EmailKpis>('work_email_kpis', {}, { refetchInterval: 5 * 60_000 });
  const waPending = useSlug<WaOutboundRow>('wa_outbound_pending', {}, { refetchInterval: 60_000 });
  const reviewSum = useSlug<ReviewSummaryRow>('reviews_three_source_summary', {}, { refetchInterval: 10 * 60_000 });
  const reviewTbl = useSlug<ReviewTableRow>('reviews_filterable_table', {}, { refetchInterval: 10 * 60_000 });

  // Table sort + filter state
  const [sortKey, setSortKey] = useState<'posted_at' | 'rating5' | 'source' | 'reviewer_name'>('posted_at');
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('desc');
  const [sourceFilter, setSourceFilter] = useState<'all' | 'google' | 'tripadvisor' | 'booking_com'>('all');
  const [ratingMin, setRatingMin] = useState<number>(0);
  const [searchText, setSearchText] = useState<string>('');

  const tableRows = useMemo(() => {
    let rows = reviewTbl.data ?? [];
    if (sourceFilter !== 'all') rows = rows.filter(r => r.source === sourceFilter);
    if (ratingMin > 0) rows = rows.filter(r => (r.rating5 != null ? parseFloat(String(r.rating5)) : 0) >= ratingMin);
    if (searchText.trim()) {
      const q = searchText.toLowerCase();
      rows = rows.filter(r =>
        (r.reviewer_name ?? '').toLowerCase().includes(q) ||
        (r.body_excerpt ?? '').toLowerCase().includes(q));
    }
    const dir = sortDir === 'asc' ? 1 : -1;
    rows = [...rows].sort((a, b) => {
      const va = a[sortKey]; const vb = b[sortKey];
      if (va == null && vb == null) return 0;
      if (va == null) return 1;
      if (vb == null) return -1;
      if (sortKey === 'rating5') return (parseFloat(String(va)) - parseFloat(String(vb))) * dir;
      if (sortKey === 'posted_at') return (new Date(String(va)).getTime() - new Date(String(vb)).getTime()) * dir;
      return String(va).localeCompare(String(vb)) * dir;
    });
    return rows;
  }, [reviewTbl.data, sourceFilter, ratingMin, searchText, sortKey, sortDir]);

  function setSort(k: typeof sortKey) {
    if (sortKey === k) setSortDir(d => d === 'asc' ? 'desc' : 'asc');
    else { setSortKey(k); setSortDir(k === 'rating5' || k === 'posted_at' ? 'desc' : 'asc'); }
  }
  function sortIcon(k: typeof sortKey) {
    if (sortKey !== k) return <ArrowUpDown size={11} className="inline opacity-40" />;
    return sortDir === 'asc' ? <ChevronUp size={11} className="inline" /> : <ChevronDown size={11} className="inline" />;
  }
  const sp     = spark.data?.[0];
  const ek     = email.data?.[0];
  const ratingSeries = (sp?.rating_spark ?? []).map(v => Number(v) || 0);
  const countSeries  = (sp?.count_spark  ?? []).map(v => Number(v) || 0);

  return (
    <div className="space-y-6">
      <SandboxWrapper id="comms.reviews-trend" label="Reviews trend">
        <Section title="Reviews — 30-day trend">
          {spark.isLoading ? <PlaceholderState message="Loading trend…" /> :
           sp && sp.total_reviews_30d > 0 ? (
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div className="tile">
                <div className="label">30d avg rating</div>
                <div className="kpi-xl mt-1">{sp.avg_rating_30d ? `${parseFloat(sp.avg_rating_30d).toFixed(2)}★` : '—'}</div>
                <div className="text-[10px] text-ink-500 mt-0.5">days with reviews only</div>
                <div className="mt-2 h-10 opacity-70">
                  <SparkLine values={ratingSeries} colour="#f59e0b" />
                </div>
              </div>
              <div className="tile">
                <div className="label">30d review count</div>
                <div className="kpi-xl mt-1">{sp.total_reviews_30d}</div>
                <div className="text-[10px] text-ink-500 mt-0.5">total this window</div>
                <div className="mt-2 h-10 opacity-70">
                  <SparkLine values={countSeries} colour="#06b6d4" />
                </div>
              </div>
            </div>
          ) : <PlaceholderState message="No reviews in the last 30 days." />}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="comms.reviews" label="Reviews">
        <Section title="Reviews — by source (all normalised /5)">
          {reviewSum.isLoading ? <PlaceholderState message="Loading…" /> : (
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3">
              {(reviewSum.data ?? []).map((r) => {
                const avg30   = r.avg_30d      != null ? parseFloat(String(r.avg_30d))      : null;
                const avgAll  = r.avg_all_time != null ? parseFloat(String(r.avg_all_time)) : null;
                const last7   = r.avg_last_7d  != null ? parseFloat(String(r.avg_last_7d))  : null;
                const prev7   = r.avg_prev_7d  != null ? parseFloat(String(r.avg_prev_7d))  : null;
                const delta   = (last7 != null && prev7 != null) ? last7 - prev7 : null;
                const deltaStr = delta == null ? '—' : (delta > 0 ? `+${delta.toFixed(2)}` : delta.toFixed(2));
                const deltaCls = delta == null ? 'text-ink-500' : delta > 0 ? 'text-good' : delta < 0 ? 'text-warn' : 'text-ink-500';
                const isAggregate = r.source === 'ALL';
                const trend = (r.trend_4w ?? []).map(v => parseFloat(String(v)) || 0).filter(v => v > 0);
                const lastReviewDays = r.last_review_at ? Math.floor((Date.now() - new Date(r.last_review_at).getTime()) / 86_400_000) : null;
                return (
                  <div key={r.source} className={'tile p-3 ' + (isAggregate ? 'border-amber-500 border-2' : '')}>
                    <div className="flex items-center justify-between">
                      <div className="text-[10px] text-ink-500 uppercase tracking-wider">{r.label}{isAggregate && ' (aggregate)'}</div>
                      {r.source === 'booking_com' && <div className="text-[9px] text-ink-500" title="Booking.com rates /10; halved here for parity">/10 → /5</div>}
                    </div>
                    <div className="mt-1 text-2xl font-mono font-semibold text-ink-900">
                      {avg30 != null ? `${avg30.toFixed(2)}★` : (avgAll != null ? `${avgAll.toFixed(2)}★` : '—')}
                      <span className="ml-1 text-[10px] text-ink-500 font-sans normal-case tracking-normal">{avg30 != null ? '30d' : (avgAll != null ? 'all-time' : '')}</span>
                    </div>
                    <div className="mt-1 text-[10px] text-ink-500">
                      {r.count_30d} reviews / 30d · {r.count_all_time} all-time
                    </div>
                    <div className="mt-1 text-[10px] text-ink-600">
                      last review: {r.last_review_at ? `${lastReviewDays}d ago` : 'never'}
                    </div>
                    <div className={'mt-1 text-xs font-mono ' + deltaCls}>
                      7d vs prev 7d: {deltaStr}{delta != null && '★'}
                    </div>
                    {trend.length > 1 && (
                      <div className="mt-2 h-6 opacity-70" title="Weekly avg, last 4 weeks">
                        <SparkLine values={trend} colour={isAggregate ? '#f59e0b' : '#06b6d4'} />
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          )}
          {reviewSum.data?.find(r => r.source === 'booking_com')?.count_all_time == 0 && (
            <p className="mt-2 text-[11px] text-amber-400">
              Booking.com slot wired (averages halved for /5 parity). Will populate once the Booking.com review-email parser is added to the gmail pipeline (queued — needs gmail unblocked via vault unseal).
            </p>
          )}
        </Section>

        <Section title="Reviews — sortable / filterable table">
          <div className="mb-2 flex flex-wrap items-center gap-2 text-xs">
            <span className="text-ink-500">filter:</span>
            <select value={sourceFilter} onChange={(e) => setSourceFilter(e.target.value as typeof sourceFilter)}
              className="bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1">
              <option value="all">All sources</option>
              <option value="google">Google</option>
              <option value="tripadvisor">TripAdvisor</option>
              <option value="booking_com">Booking.com</option>
            </select>
            <select value={ratingMin} onChange={(e) => setRatingMin(parseFloat(e.target.value))}
              className="bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1">
              <option value="0">Any rating</option>
              <option value="5">5★ only</option>
              <option value="4">4★ and up</option>
              <option value="3">3★ and up</option>
              <option value="2">2★ and up (incl. negative)</option>
              <option value="1">1★ and up</option>
            </select>
            <input type="text" value={searchText} onChange={(e) => setSearchText(e.target.value)}
              placeholder="search name or body…"
              className="bg-ink-100 border border-ink-200 text-ink-800 rounded px-2 py-1 flex-1 min-w-32 max-w-64" />
            <span className="text-[10px] text-ink-500 ml-auto">{tableRows.length} of {reviewTbl.data?.length ?? 0}</span>
          </div>
          {reviewTbl.isLoading ? <PlaceholderState message="Loading…" /> : tableRows.length === 0 ? (
            <PlaceholderState message="No reviews match the filter." />
          ) : (
            <div className="tile overflow-x-auto">
              <table className="w-full text-xs">
                <thead className="text-ink-500 uppercase tracking-wider text-[10px] sticky top-0 bg-ink-50">
                  <tr>
                    <th className="px-2 py-1.5 text-left cursor-pointer hover:text-ink-800 select-none" onClick={() => setSort('rating5')}>
                      Score {sortIcon('rating5')}
                    </th>
                    <th className="px-2 py-1.5 text-left cursor-pointer hover:text-ink-800 select-none" onClick={() => setSort('source')}>
                      Source {sortIcon('source')}
                    </th>
                    <th className="px-2 py-1.5 text-left cursor-pointer hover:text-ink-800 select-none" onClick={() => setSort('posted_at')}>
                      Date {sortIcon('posted_at')}
                    </th>
                    <th className="px-2 py-1.5 text-left cursor-pointer hover:text-ink-800 select-none" onClick={() => setSort('reviewer_name')}>
                      Name {sortIcon('reviewer_name')}
                    </th>
                    <th className="px-2 py-1.5 text-left">Summary</th>
                    <th className="px-2 py-1.5"></th>
                  </tr>
                </thead>
                <tbody>
                  {tableRows.map(r => {
                    const score = r.rating5 != null ? parseFloat(String(r.rating5)) : null;
                    return (
                      <tr key={r.review_id} className="border-t border-ink-200 align-top">
                        <td className="px-2 py-1.5 font-mono whitespace-nowrap">
                          <span className="text-amber-500">{score != null ? score.toFixed(1) : '—'}</span>
                          <span className="ml-1 text-[10px] text-ink-500">{stars(score != null ? Math.round(score) : null)}</span>
                        </td>
                        <td className="px-2 py-1.5">{sourceLabel(r.source)}</td>
                        <td className="px-2 py-1.5 whitespace-nowrap text-ink-700">{r.posted_at ? new Date(r.posted_at).toLocaleDateString('en-GB') : '—'}</td>
                        <td className="px-2 py-1.5 text-ink-700">{r.reviewer_name ?? 'Anonymous'}</td>
                        <td className="px-2 py-1.5 text-ink-700 max-w-md">{r.body_excerpt ?? ''}</td>
                        <td className="px-2 py-1.5 whitespace-nowrap">
                          {r.review_url && (
                            <a href={r.review_url} target="_blank" rel="noopener noreferrer" className="text-amber-500 hover:text-amber-400">
                              <ExternalLink size={11} />
                            </a>
                          )}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="comms.email" label="Email summary">
        <Section title="Email">
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <KPICard label="Email tasks open" value={ek?.tasks_open ?? '—'} loading={email.isLoading} />
            <KPICard label="Bot instructions pending" value={ek?.instructions_pending ?? '—'} loading={email.isLoading} />
            <KPICard
              label="Last instruction"
              value={ek?.last_instruction_at ? new Date(ek.last_instruction_at).toLocaleString('en-GB', { day:'2-digit', month:'short', hour:'2-digit', minute:'2-digit' }) : '—'}
              loading={email.isLoading} />
          </div>
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="comms.wa" label="WhatsApp outbound queue">
        <Section title="WhatsApp drafts awaiting approval">
          {(() => {
            const wa = waPending;
            if (wa.isLoading) return <div className="text-xs text-ink-500">Loading…</div>;
            const rows = wa.data ?? [];
            if (rows.length === 0) return <PlaceholderState message="Queue empty — no WhatsApp drafts awaiting approval." />;
            return (
              <div className="tile overflow-x-auto">
                <table className="w-full text-xs">
                  <thead className="text-ink-500 uppercase tracking-wider text-[10px]">
                    <tr>
                      <th className="px-2 py-1 text-left">Account</th>
                      <th className="px-2 py-1 text-left">Recipient</th>
                      <th className="px-2 py-1 text-left">Body</th>
                      <th className="px-2 py-1 text-left">Reason</th>
                      <th className="px-2 py-1 text-right">Age</th>
                    </tr>
                  </thead>
                  <tbody>
                    {rows.map(r => {
                      const ageH = (Date.now() - new Date(r.created_at).getTime()) / 3_600_000;
                      return (
                        <tr key={r.id} className="border-t border-ink-200 align-top">
                          <td className="px-2 py-1 font-mono">{r.account}</td>
                          <td className="px-2 py-1">{r.target_label}</td>
                          <td className="px-2 py-1 max-w-md truncate" title={r.body}>{r.body}</td>
                          <td className="px-2 py-1 text-ink-500">{r.draft_reason ?? '—'}</td>
                          <td className={'px-2 py-1 text-right ' + (ageH > 24 ? 'text-red-400' : ageH > 6 ? 'text-amber-300' : 'text-ink-700')}>{ageH < 1 ? `${Math.round(ageH * 60)}m` : `${Math.round(ageH)}h`}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            );
          })()}
        </Section>
      </SandboxWrapper>

      {/* Hermes UX review D5 (2026-05-29): hidden until the Insta/Facebook
          insights integrations are actually built. Tracked in the backlog —
          re-enable when the Social slugs are wired. */}
    </div>
  );
}
