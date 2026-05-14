-- =============================================================================
-- V69 — Dojo ↔ TouchOffice card reconciliation (U54 T4)
-- =============================================================================
-- v_card_reconciliation: one row per (date, site) showing the Dojo card-
-- takings total alongside the TouchOffice "Card in Drawer" tender, with a
-- delta and a status flag. Site labels are mapped Dojo→TouchOffice via the
-- inline CASE (Dojo uses pub/cafe; TouchOffice uses malthouse/sandwich).
--
-- The "Card in Drawer" tender is totaliser_id=6 on both TouchOffice sites
-- (Olde Malthouse Inn + Sandwich Bar). Verified 2026-05-14 with a 7-day
-- cross-check: most days agree to the penny; days with delta > £1 are
-- legitimate operational mismatches (card-machine timeouts, manual voids,
-- cross-midnight card-vs-EPOS bookings) that warrant a `reconciliation_flags`
-- row.
-- =============================================================================

BEGIN;

CREATE OR REPLACE VIEW v_card_reconciliation AS
WITH dojo AS (
    SELECT date, site, gross_sales AS dojo_gross
      FROM v_dojo_daily
),
touchoffice AS (
    SELECT
        report_date AS date,
        CASE site
            WHEN 'malthouse' THEN 'pub'
            WHEN 'sandwich'  THEN 'cafe'
            ELSE site
        END AS site,
        SUM(value) AS to_card
      FROM touchoffice_fixed_totals
     WHERE totaliser_id = 6   -- CREDIT in Drawer
       AND label = 'CREDIT in Drawer'
     GROUP BY 1, 2
)
SELECT
    COALESCE(d.date, t.date)       AS date,
    COALESCE(d.site, t.site)       AS site,
    COALESCE(t.to_card,    0)::numeric(12,2) AS touchoffice_card,
    COALESCE(d.dojo_gross, 0)::numeric(12,2) AS dojo_gross,
    ROUND(COALESCE(d.dojo_gross,0) - COALESCE(t.to_card,0), 2) AS delta,
    CASE
        WHEN d.dojo_gross IS NULL                          THEN 'missing_dojo'
        WHEN t.to_card    IS NULL                          THEN 'missing_touchoffice'
        WHEN ABS(d.dojo_gross - t.to_card) <= 1.00         THEN 'ok'
        WHEN ABS(d.dojo_gross - t.to_card) <= 25.00        THEN 'minor'
        ELSE                                                    'mismatch'
    END AS status,
    'work'::text AS realm
  FROM dojo d
  FULL OUTER JOIN touchoffice t ON t.date = d.date AND t.site = d.site
 WHERE COALESCE(d.date, t.date) >= now()::date - INTERVAL '90 days';

COMMENT ON VIEW v_card_reconciliation IS
    'U54 T4: per-day-per-site card-takings reconciliation. Dojo (gross_sales) '
    'minus TouchOffice CREDIT in Drawer. delta>£1 = minor; >£25 = mismatch; '
    'one-sided rows = missing_dojo / missing_touchoffice.';

-- -----------------------------------------------------------------------------
-- Verification
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    last7_ok INT;
    last7_mismatch INT;
    last7_minor INT;
BEGIN
    SELECT
        COUNT(*) FILTER (WHERE status='ok'),
        COUNT(*) FILTER (WHERE status='mismatch'),
        COUNT(*) FILTER (WHERE status='minor')
      INTO last7_ok, last7_mismatch, last7_minor
      FROM v_card_reconciliation
     WHERE date >= now()::date - INTERVAL '7 days';

    IF last7_ok = 0 AND last7_minor = 0 AND last7_mismatch = 0 THEN
        RAISE EXCEPTION 'V69 verification failed: view returned no rows in last 7 days';
    END IF;

    RAISE NOTICE 'V69 verification PASS: last-7d reconciliation — ok=% / minor=% / mismatch=%',
        last7_ok, last7_minor, last7_mismatch;
END $$;

COMMIT;
