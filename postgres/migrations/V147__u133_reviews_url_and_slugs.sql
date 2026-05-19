-- =============================================================================
-- V147 — U133 T8: reviews — review_url column + recent + 30d avg slugs
-- =============================================================================

BEGIN;

ALTER TABLE guest_reviews
    ADD COLUMN IF NOT EXISTS review_url TEXT;

CREATE INDEX IF NOT EXISTS idx_guest_reviews_posted_at
    ON guest_reviews (posted_at DESC NULLS LAST);

CREATE INDEX IF NOT EXISTS idx_guest_reviews_source_location
    ON guest_reviews (source, location);

INSERT INTO query_whitelist
    (slug, display_name, description, sql_template, param_schema, result_format,
     active, created_by, approved_at, approved_by, notes, realm)
VALUES
    ('reviews_recent',
     'Recent guest reviews',
     'Most recent 50 reviews across all sources. Drives the /comms Recent reviews list.',
     $sql$SELECT posted_at, source, location, rating, reviewer_name,
                LEFT(COALESCE(body, ''), 280) AS body_excerpt,
                review_url, status
           FROM guest_reviews
          ORDER BY posted_at DESC NULLS LAST
          LIMIT 50$sql$,
     '{}'::jsonb,
     'table',
     true,
     'V147-U133T8',
     NOW(),
     'V147-U133T8',
     'Per U133 T8 plan.',
     'work'),
    ('reviews_average_30d',
     'Average rating — 30 days',
     '30-day rolling average rating + review count, per source × location.',
     $sql$SELECT source, location,
                ROUND(AVG(rating)::numeric, 2) AS avg_rating,
                COUNT(*) AS review_count
           FROM guest_reviews
          WHERE posted_at >= NOW() - INTERVAL '30 days'
            AND rating IS NOT NULL
          GROUP BY source, location
          ORDER BY source, location$sql$,
     '{}'::jsonb,
     'table',
     true,
     'V147-U133T8',
     NOW(),
     'V147-U133T8',
     'Per U133 T8 plan.',
     'work')
ON CONFLICT (slug) DO UPDATE
   SET sql_template = EXCLUDED.sql_template,
       description  = EXCLUDED.description,
       active       = true,
       approved_at  = NOW();

COMMIT;
