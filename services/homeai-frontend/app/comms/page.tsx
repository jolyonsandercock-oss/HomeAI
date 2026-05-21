'use client';

import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { KPICard } from '@/components/ui/KPICard';
import { useSlug } from '@/lib/hooks';
import { SparkLine } from '@/components/ui/SparkLine';
import { Star, ExternalLink } from 'lucide-react';

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
        <Section title="Reviews — 30-day averages">
          {avg30.isLoading ? <PlaceholderState message="Loading…" /> :
           avg30.data && avg30.data.length > 0 ? (
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
              {avg30.data.map((a, i) => (
                <KPICard
                  key={i}
                  label={`${sourceLabel(a.source)} · ${a.location}`}
                  value={a.avg_rating != null ? `${parseFloat(String(a.avg_rating)).toFixed(2)}★` : '—'}
                  rollingAvg={[{ label: 'reviews', value: a.review_count }]}
                />
              ))}
            </div>
          ) : (
            <PlaceholderState
              message="No reviews yet"
              hint="Once Jo adds rows to the review_listings table (source × location × public URL), the daily scraper (cron 06:15) populates guest_reviews and this panel goes live." />
          )}
        </Section>

        <Section title="Recent reviews">
          {recent.isLoading ? <PlaceholderState message="Loading…" /> :
           recent.data && recent.data.length > 0 ? (
            <div className="tile space-y-3 text-sm">
              {recent.data.map((r, i) => (
                <div key={i} className="border-b border-ink-200 pb-3 last:border-0 last:pb-0">
                  <div className="flex items-center justify-between gap-3 flex-wrap">
                    <div className="flex items-center gap-2">
                      <span className="text-amber-500 font-mono text-base">{stars(r.rating)}</span>
                      <span className="text-ink-500 text-[11px] uppercase tracking-wider">{sourceLabel(r.source)} · {r.location}</span>
                    </div>
                    <span className="text-[11px] text-ink-500">
                      {r.posted_at ? new Date(r.posted_at).toLocaleDateString('en-GB') : '—'}
                    </span>
                  </div>
                  <div className="mt-1 font-medium text-ink-900">{r.reviewer_name ?? 'Anonymous'}</div>
                  <div className="mt-1 text-ink-700 text-xs leading-relaxed">{r.body_excerpt ?? ''}</div>
                  {r.review_url && (
                    <a href={r.review_url}
                       target="_blank"
                       rel="noopener noreferrer"
                       className="mt-2 inline-flex items-center gap-1 text-[11px] text-amber-500 hover:text-amber-400">
                      <ExternalLink size={11} /> View on {sourceLabel(r.source)}
                    </a>
                  )}
                </div>
              ))}
            </div>
          ) : (
            <PlaceholderState message="No reviews yet — see above for setup." />
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
          <PlaceholderState
            message="Will wire to /api/slug/wa_outbound_pending"
            hint="Backed by U118 wa_outbound_queue + U119 staff drafter + U120 visitor drafter. Awaiting paired WhatsApp Web sessions (see PAIRING.md)." />
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="comms.social" label="Social stats">
        <Section title="Social">
          <PlaceholderState
            message="Social media integrations pending"
            hint="Insta/Facebook insights APIs scoped but not built. Roadmapped." />
        </Section>
      </SandboxWrapper>
    </div>
  );
}
