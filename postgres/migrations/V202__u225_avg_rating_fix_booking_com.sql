-- V202 / U225 T4 — Fix average review rating maths + prep for Booking.com.
--
-- Bug: reviews_rating_spark_30d computed avg_rating_30d as
--   ROUND(AVG(per_day_avg_rating), 2)
-- That averages the per-day averages, so a day with 10 5★ reviews counts the
-- same as a day with 1 1★ review (giving 3.0★ when the real average is 4.6★).
-- Fix: compute the true weighted mean across all rows in the window.
--
-- Booking.com prep: guest_reviews.source has no CHECK constraint so any
-- spelling is insertable. The UI label function (sourceLabel in
-- app/comms/page.tsx) recognises 'booking_com' as 'Booking.com', so we
-- normalise to that here. The actual email-ingestion path to populate
-- Booking.com rows is U225 follow-up T4b, gated on Vault unseal (Gmail
-- OAuth secrets).

INSERT INTO query_whitelist (slug, display_name, description, sql_template, active, realm, created_by, approved_at, approved_by)
VALUES (
  'reviews_rating_spark_30d',
  'Reviews — 30d rating sparkline + counts',
  'U211→U225: per-day avg rating + count arrays for sparkline. avg_rating_30d is now the true weighted mean across all rows, not avg-of-per-day-avgs.',
  $T$WITH days AS (
    SELECT generate_series(CURRENT_DATE - 29, CURRENT_DATE, '1 day'::interval)::date AS d
  ),
  per_day AS (
    SELECT posted_at::date AS d, COUNT(*) AS n, AVG(rating)::numeric AS avg_rating
      FROM guest_reviews
     WHERE rating IS NOT NULL
       AND posted_at::date >= CURRENT_DATE - 29
     GROUP BY 1
  ),
  totals AS (
    SELECT COUNT(*)::int AS total_reviews_30d,
           ROUND(AVG(rating)::numeric, 2) AS avg_rating_30d
      FROM guest_reviews
     WHERE rating IS NOT NULL
       AND posted_at::date >= CURRENT_DATE - 29
  )
  SELECT array_agg(COALESCE(pd.avg_rating, 0) ORDER BY d.d) AS rating_spark,
         array_agg(COALESCE(pd.n, 0) ORDER BY d.d) AS count_spark,
         (SELECT total_reviews_30d FROM totals) AS total_reviews_30d,
         (SELECT avg_rating_30d    FROM totals) AS avg_rating_30d
    FROM days d
    LEFT JOIN per_day pd USING (d)$T$,
  true, 'shared', 'U225', NOW(), 'U225'
)
ON CONFLICT (slug) DO UPDATE
  SET sql_template = EXCLUDED.sql_template,
      description  = EXCLUDED.description,
      approved_at  = EXCLUDED.approved_at,
      realm        = EXCLUDED.realm;

-- Normalise legacy spellings to canonical 'booking_com' (matches the UI
-- sourceLabel mapping in components/app/comms).
UPDATE guest_reviews SET source = 'booking_com'
 WHERE source IN ('booking', 'booking.com', 'Booking.com', 'BookingCom');
