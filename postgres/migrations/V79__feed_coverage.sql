-- =============================================================================
-- V79 — Feed coverage audit (U61 T6)
-- =============================================================================
-- For every (feed, expected_date) pair in the last 2 years, record whether
-- the corresponding source has data. Status enum:
--   ok        — rows present
--   missing   — 0 rows on a date the feed should have data
--   partial   — fewer rows than the feed's 30-day median
--   stale     — feed last ran > expected cadence
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS feed_coverage (
    id            BIGSERIAL PRIMARY KEY,
    feed_name     TEXT        NOT NULL,
    expected_date DATE        NOT NULL,
    row_count     INTEGER     NOT NULL DEFAULT 0,
    last_scraped  TIMESTAMPTZ,
    status        TEXT        NOT NULL,
    notes         TEXT,
    realm         TEXT        NOT NULL DEFAULT 'owner',
    audited_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (feed_name, expected_date)
);

ALTER TABLE feed_coverage DROP CONSTRAINT IF EXISTS feed_coverage_status_check;
ALTER TABLE feed_coverage ADD CONSTRAINT feed_coverage_status_check
    CHECK (status IN ('ok','missing','partial','stale'));

ALTER TABLE feed_coverage DROP CONSTRAINT IF EXISTS feed_coverage_realm_check;
ALTER TABLE feed_coverage ADD CONSTRAINT feed_coverage_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

CREATE INDEX IF NOT EXISTS idx_feed_coverage_missing
    ON feed_coverage (feed_name, expected_date DESC) WHERE status <> 'ok';
CREATE INDEX IF NOT EXISTS idx_feed_coverage_date
    ON feed_coverage (expected_date DESC);

-- ---------------------------------------------------------------------------
-- Helper view: latest coverage snapshot per feed
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_feed_coverage_summary AS
SELECT
    feed_name,
    COUNT(*)                                       AS n_dates,
    COUNT(*) FILTER (WHERE status = 'ok')          AS n_ok,
    COUNT(*) FILTER (WHERE status = 'missing')     AS n_missing,
    COUNT(*) FILTER (WHERE status = 'partial')     AS n_partial,
    COUNT(*) FILTER (WHERE status = 'stale')       AS n_stale,
    ROUND(100.0 * COUNT(*) FILTER (WHERE status='ok') / NULLIF(COUNT(*),0), 1) AS pct_ok,
    MIN(expected_date) AS earliest,
    MAX(expected_date) AS latest,
    MAX(audited_at)    AS last_audited
  FROM feed_coverage
 GROUP BY feed_name
 ORDER BY pct_ok ASC NULLS LAST;

COMMENT ON VIEW v_feed_coverage_summary IS
    'One-row-per-feed snapshot of coverage health. Lowest pct_ok first.';

CREATE OR REPLACE VIEW v_feed_coverage_recent_gaps AS
SELECT feed_name, expected_date, status, row_count, notes
  FROM feed_coverage
 WHERE status <> 'ok'
   AND expected_date >= CURRENT_DATE - INTERVAL '30 days'
 ORDER BY expected_date DESC, feed_name;

COMMENT ON VIEW v_feed_coverage_recent_gaps IS
    'Last-30d gaps for the Mission Control "Coverage" tile.';

COMMIT;
