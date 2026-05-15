-- =============================================================================
-- V84 — business_calendar + closed-day-aware coverage view (U67 T2)
-- =============================================================================
-- Per-site open/closed flag per date. Where is_open=FALSE we expect zero feed
-- activity (no till, no Dojo, no PLU sales). Lets feed_coverage stop crying
-- "missing" on Christmas Day etc.
--
-- Seeded with known UK pub closure dates (Christmas Day) and a small list
-- the operator can expand. Jo can paste an UPDATE for any one-off closures.
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS business_calendar (
    id           BIGSERIAL PRIMARY KEY,
    site         TEXT NOT NULL,         -- 'malthouse' | 'sandwich' | 'inn' | 'pub' | 'cafe' | ...
    cal_date     DATE NOT NULL,
    is_open      BOOLEAN NOT NULL DEFAULT TRUE,
    open_hours   TEXT,                  -- '11:00-23:00' free text; nullable
    closure_reason TEXT,                -- 'christmas_day' | 'staff_holiday' | 'maintenance' | …
    notes        TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    realm        TEXT NOT NULL DEFAULT 'work'
                      CHECK (realm IN ('owner','work','family','shared')),
    UNIQUE (site, cal_date)
);
CREATE INDEX IF NOT EXISTS idx_business_calendar_closed
    ON business_calendar (site, cal_date DESC) WHERE NOT is_open;

-- Seed: Christmas Day across all sites for the data window we have.
-- Both site label conventions (raw TouchOffice 'malthouse'/'sandwich' AND
-- friendly 'pub'/'cafe') are seeded so coverage joins regardless.
INSERT INTO business_calendar (site, cal_date, is_open, closure_reason)
SELECT site, dt::date, FALSE, 'christmas_day'
  FROM (VALUES
    ('malthouse'), ('sandwich'), ('inn'), ('pub'), ('cafe')
  ) AS s(site)
  CROSS JOIN (
    SELECT generate_series('2019-12-25'::date, '2026-12-25'::date, '1 year'::interval) AS dt
  ) AS d
ON CONFLICT (site, cal_date) DO NOTHING;

COMMENT ON TABLE business_calendar IS
    'V84: per-site open/closed schedule. Drives feed_coverage to skip '
    'closure days so the "missing" tally only flags real gaps. Jo expands '
    'manually as one-off closures happen.';

-- v_feed_coverage_clean: feed_coverage with closure days suppressed.
-- A feed-date is "expected_closed" when business_calendar.is_open=FALSE for
-- a site that maps to that feed.
--
-- Mapping (feed_name → sites):
--   touchoffice_malthouse → 'malthouse','pub'
--   touchoffice_sandwich  → 'sandwich','cafe'
--   dojo_pub              → 'pub','malthouse'
--   dojo_cafe             → 'cafe','sandwich'
--   workforce_pub         → 'pub','malthouse'
--   (others → no site mapping, treat as always-expected)
--
-- We left-join through a feed-to-site CTE; any feed_coverage row whose
-- mapped site is closed for that date is reclassified status='closed'.
CREATE OR REPLACE VIEW v_feed_coverage_clean AS
WITH feed_sites AS (
    SELECT 'touchoffice_malthouse'::text AS feed_name, ARRAY['malthouse','pub']      AS sites UNION ALL
    SELECT 'touchoffice_sandwich',                     ARRAY['sandwich','cafe']                  UNION ALL
    SELECT 'touchoffice_inn',                          ARRAY['inn']                              UNION ALL
    SELECT 'dojo_pub',                                 ARRAY['pub','malthouse']                  UNION ALL
    SELECT 'dojo_cafe',                                ARRAY['cafe','sandwich']                  UNION ALL
    SELECT 'workforce_malthouse',                      ARRAY['malthouse','pub']                  UNION ALL
    SELECT 'workforce_sandwich',                       ARRAY['sandwich','cafe']                  UNION ALL
    SELECT 'caterbook',                                ARRAY['inn']                              UNION ALL
    SELECT 'till_reconciliation_pub',                  ARRAY['pub','malthouse']                  UNION ALL
    SELECT 'till_reconciliation_cafe',                 ARRAY['cafe','sandwich']
),
closure AS (
    SELECT fs.feed_name, fc.cal_date
      FROM feed_sites fs
      JOIN business_calendar fc
        ON fc.site = ANY(fs.sites)
       AND NOT fc.is_open
)
SELECT
    f.id, f.feed_name, f.expected_date, f.row_count, f.last_scraped, f.notes,
    f.realm, f.audited_at,
    CASE WHEN c.cal_date IS NOT NULL THEN 'closed' ELSE f.status END AS status
  FROM feed_coverage f
  LEFT JOIN closure c ON c.feed_name = f.feed_name AND c.cal_date = f.expected_date;

COMMENT ON VIEW v_feed_coverage_clean IS
    'V84: feed_coverage with closure days reclassified status=closed so the '
    'missing-rows widget no longer cries about expected zeros.';

-- v_feed_coverage_summary_clean: aggregated per-feed status counts using the
-- closure-aware view above. Drop-in replacement for v_feed_coverage_summary.
CREATE OR REPLACE VIEW v_feed_coverage_summary_clean AS
SELECT
    feed_name,
    COUNT(*)                                  AS expected_days,
    COUNT(*) FILTER (WHERE status = 'ok')     AS ok_days,
    COUNT(*) FILTER (WHERE status = 'closed') AS closed_days,
    COUNT(*) FILTER (WHERE status IN ('missing','partial','stale')) AS real_missing,
    ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'ok')
                / NULLIF(COUNT(*) FILTER (WHERE status <> 'closed'), 0), 1) AS ok_pct
  FROM v_feed_coverage_clean
 GROUP BY feed_name
 ORDER BY feed_name;

DO $$
DECLARE n_closures INT;
BEGIN
    SELECT COUNT(*) INTO n_closures FROM business_calendar WHERE NOT is_open;
    RAISE NOTICE 'V84 PASS: % closure rows seeded; v_feed_coverage_clean ready.', n_closures;
END $$;

COMMIT;
