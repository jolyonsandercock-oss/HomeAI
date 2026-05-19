-- =============================================================================
-- V141 — U132: today-slug fallbacks for stale TouchOffice ingestion
-- =============================================================================
-- TouchOffice scrape lands sometime overnight after close; "today" data may be
-- empty for hours into the next morning. Three slugs/views were filtering
-- `report_date = CURRENT_DATE` and rendering blank tiles.
--
-- Fix: filter to the latest report_date that is <= CURRENT_DATE. The dashboard
-- KPI keeps its "Gross today" label; the slug also exposes `as_of` so the UI
-- can disclose the cut-off when not literally today (future UX work).
-- =============================================================================

BEGIN;

-- 1. frontend_today_gross — Next.js homepage "Gross today" tile
UPDATE query_whitelist
   SET sql_template = $sql$SELECT site,
                                  SUM(value)::numeric(12,2) AS gross,
                                  MAX(report_date) AS as_of
                           FROM touchoffice_department_sales
                           WHERE report_date = (
                             SELECT MAX(report_date)
                               FROM touchoffice_department_sales
                              WHERE report_date <= CURRENT_DATE
                           )
                           GROUP BY site$sql$,
       approved_at = NOW(),
       notes       = COALESCE(notes, '') || E'\nV141 (U132): fallback to latest report_date when today is empty'
 WHERE slug = 'frontend_today_gross';

-- 2. today_totals — desktop "Today's totals across sites"
UPDATE query_whitelist
   SET sql_template = $sql$SELECT report_date,
                                  pub_net_sales,      pub_gross_sales,      pub_covers,
                                  sandwich_net_sales, sandwich_gross_sales, sandwich_covers,
                                  total_net_sales,    total_gross_sales,    total_covers
                           FROM v_daily_unit_economics
                           WHERE report_date = (
                             SELECT MAX(report_date)
                               FROM v_daily_unit_economics
                              WHERE report_date <= CURRENT_DATE
                                AND total_net_sales > 0
                           )$sql$,
       approved_at = NOW(),
       notes       = COALESCE(notes, '') || E'\nV141 (U132): fallback to latest day with sales when today is empty'
 WHERE slug = 'today_totals';

-- 3. v_today_pub_sales — desktop "Today pub sales" + today_pub_sales slug
CREATE OR REPLACE VIEW v_today_pub_sales AS
SELECT site,
       department,
       (value)::numeric(12,2) AS net_value,
       quantity,
       report_date AS as_of
FROM touchoffice_department_sales
WHERE report_date = (
  SELECT MAX(report_date)
    FROM touchoffice_department_sales
   WHERE report_date <= CURRENT_DATE
)
ORDER BY value DESC NULLS LAST;

COMMIT;

-- Verify (uncomment to run as part of migration log):
-- SELECT count(*) FROM v_today_pub_sales;
-- SELECT site, gross, as_of FROM (SELECT sql_template FROM query_whitelist WHERE slug = 'frontend_today_gross') x;
