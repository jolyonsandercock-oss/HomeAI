'use client';

import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import { ExternalLink, AlertTriangle } from 'lucide-react';

interface BlendRow {
  blended_all_time: string | null;
  count_all_time: number | string;
  blended_30d: string | null;
  count_30d: number | string;
}
interface SourceHealthRow {
  source: string;
  location: string | null;
  active: boolean | null;
  last_scraped_at: string | null;
  last_status: string | null;
  review_count: number | string;
  last_review_at: string | null;
}
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

const SOURCE_LABEL: Record<string, string> = {
  google: 'Google',
  tripadvisor: 'TripAdvisor',
  booking_com: 'Booking.com',
  expedia: 'Expedia',
};
// booking_com + expedia store raw ratings on the /10 scale.
const TEN_SCALE = new Set(['booking_com', 'expedia']);

function stars(rating5: number | null): string {
  if (rating5 == null) return '';
  const r = Math.round(rating5);
  return '★'.repeat(r) + '☆'.repeat(Math.max(0, 5 - r));
}
function daysAgo(iso: string | null): number | null {
  if (!iso) return null;
  return Math.floor((Date.now() - new Date(iso).getTime()) / 86_400_000);
}

// A scraper is "dead" when its last recorded status wasn't a success —
// google is stuck at `unparsed`, tripadvisor at `fetch_fail`. Surfacing WHY
// a source has no fresh reviews is the point of this row.
function scraperProblem(r: SourceHealthRow): string | null {
  if (r.last_status && r.last_status !== 'ok') return r.last_status;
  return null;
}

export default function ReviewsPage() {
  const blend  = useSlug<BlendRow>('reviews_blend', {}, { refetchInterval: 10 * 60_000 });
  const health = useSlug<SourceHealthRow>('reviews_source_health', {}, { refetchInterval: 10 * 60_000 });
  const recent = useSlug<ReviewRow>('reviews_recent', {}, { refetchInterval: 10 * 60_000 });

  const b = blend.data?.[0];
  const deadScrapers = (health.data ?? []).filter(r => scraperProblem(r) !== null);

  return (
    <div className="space-y-6">
      <SandboxWrapper id="reviews.blend" label="Blended rating">
        <Section title="Guest reviews — blended rating (all sources, /5 normalised)">
          {blend.isLoading ? <PlaceholderState message="Loading…" /> : b ? (
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
              <div className="tile">
                <div className="label">Blended — 30 days</div>
                <div className="kpi-xl mt-1">{b.blended_30d != null ? `${parseFloat(b.blended_30d).toFixed(2)}★` : '—'}</div>
                <div className="text-xs text-ink-500 mt-0.5">{b.count_30d} reviews</div>
              </div>
              <div className="tile">
                <div className="label">Blended — all time</div>
                <div className="kpi-xl mt-1">{b.blended_all_time != null ? `${parseFloat(b.blended_all_time).toFixed(2)}★` : '—'}</div>
                <div className="text-xs text-ink-500 mt-0.5">{b.count_all_time} reviews</div>
              </div>
            </div>
          ) : <PlaceholderState message="No rated reviews yet." />}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="reviews.health" label="Source health">
        <Section title="Sources — where reviews come from (and why some don't)">
          {health.isLoading ? <PlaceholderState message="Loading source health…" /> : (
            <>
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-2">
                {(health.data ?? []).map((r, i) => {
                  const problem = scraperProblem(r);
                  const lastReview = daysAgo(r.last_review_at);
                  return (
                    <div key={r.source + (r.location ?? '') + i}
                         className={'tile p-2 ' + (problem ? 'border-amber-500/70 border' : '')}>
                      <div className="flex items-center justify-between">
                        <div className="text-xs text-ink-500 uppercase tracking-wider">
                          {SOURCE_LABEL[r.source] ?? r.source}{r.location ? ` · ${r.location}` : ''}
                        </div>
                        {problem && <AlertTriangle size={12} className="text-amber-400 shrink-0" />}
                      </div>
                      <div className="mt-0.5 text-lg font-mono font-semibold text-ink-900">
                        {r.review_count}
                        <span className="ml-1 text-xs text-ink-500 font-sans font-normal">reviews</span>
                      </div>
                      <div className="mt-1 text-xs text-ink-600">
                        last review: {lastReview != null ? `${lastReview}d ago` : 'never'}
                      </div>
                      {problem ? (
                        <div className="mt-1 text-xs text-amber-400">
                          scraper dead: <span className="font-mono">{problem}</span>
                          {r.last_scraped_at && <> (last try {daysAgo(r.last_scraped_at)}d ago)</>}
                        </div>
                      ) : r.last_scraped_at == null ? (
                        <div className="mt-1 text-xs text-ink-500">email-ingest / no scraper</div>
                      ) : (
                        <div className="mt-1 text-xs text-ink-500">scraped {daysAgo(r.last_scraped_at)}d ago</div>
                      )}
                    </div>
                  );
                })}
              </div>
              {deadScrapers.length > 0 && (
                <p className="mt-2 text-xs text-amber-400">
                  {deadScrapers.length} scrape target{deadScrapers.length === 1 ? '' : 's'} failing — new
                  Google/TripAdvisor reviews are NOT flowing in automatically (revival queued separately).
                </p>
              )}
            </>
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="reviews.recent" label="Recent reviews">
        <Section title="Recent reviews">
          {recent.isLoading ? <PlaceholderState message="Loading reviews…" /> :
           (recent.data ?? []).length === 0 ? <PlaceholderState message="No reviews yet." /> : (
            <div className="space-y-2">
              {(recent.data ?? []).map((r, i) => {
                const isTen = TEN_SCALE.has(r.source);
                const rating5 = r.rating == null ? null : isTen ? r.rating / 2 : r.rating;
                return (
                  <div key={r.source + (r.posted_at ?? '') + i} className="tile p-3">
                    <div className="flex items-center gap-2 flex-wrap text-xs">
                      <span className="text-amber-500 font-mono">
                        {r.rating != null ? `${r.rating}${isTen ? '/10' : ''}` : '—'}
                      </span>
                      <span className="text-ink-500">{stars(rating5 != null ? Math.round(rating5) : null)}</span>
                      <span className="text-ink-700">{SOURCE_LABEL[r.source] ?? r.source}</span>
                      <span className="text-ink-500">· {r.reviewer_name ?? 'Anonymous'}</span>
                      <span className="text-ink-500 ml-auto whitespace-nowrap">
                        {r.posted_at ? new Date(r.posted_at).toLocaleDateString('en-GB') : '—'}
                      </span>
                      {r.review_url && (
                        <a href={r.review_url} target="_blank" rel="noopener noreferrer"
                           className="text-amber-500 hover:text-amber-400">
                          <ExternalLink size={11} />
                        </a>
                      )}
                    </div>
                    {r.body_excerpt && <p className="mt-1.5 text-xs text-ink-700">{r.body_excerpt}</p>}
                  </div>
                );
              })}
            </div>
          )}
        </Section>
      </SandboxWrapper>
    </div>
  );
}
