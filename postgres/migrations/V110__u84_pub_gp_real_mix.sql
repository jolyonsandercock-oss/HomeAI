-- =============================================================================
-- V110 — U84 Item 3: Pub GP%, real wet/dry mix from TouchOffice
-- =============================================================================
-- Replaces the hardcoded 60/40 wet/dry split in v_daily_gp with the actual
-- per-day mix from touchoffice_department_sales. Per U92 audit:
-- "pub GP% wrong — hardcoded 60/40 split drives wrong per-stream margin
-- reporting".
--
-- Mapping:
--   site='malthouse' department='ALCOHOL SALES' → wet (drink)
--   site='malthouse' department='FOOD SALES'    → dry (food)
--   everything else (ACCOM, HOT DRINKS, KITCHEN INT, etc.) excluded.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- Per-day pub wet/dry sales mix from real TouchOffice data.
DROP VIEW IF EXISTS v_pub_sales_mix CASCADE;
CREATE VIEW v_pub_sales_mix AS
SELECT
  report_date,
  SUM(value) FILTER (WHERE department = 'ALCOHOL SALES')           AS wet_sales,
  SUM(value) FILTER (WHERE department = 'FOOD SALES')              AS dry_sales,
  SUM(value) FILTER (WHERE department IN ('ALCOHOL SALES','FOOD SALES')) AS pub_sales_total,
  -- Pre-computed fractions for downstream views (null-safe).
  CASE WHEN SUM(value) FILTER (WHERE department IN ('ALCOHOL SALES','FOOD SALES')) > 0
       THEN SUM(value) FILTER (WHERE department = 'ALCOHOL SALES') /
            NULLIF(SUM(value) FILTER (WHERE department IN ('ALCOHOL SALES','FOOD SALES')), 0)
       ELSE NULL END                                                AS wet_frac,
  CASE WHEN SUM(value) FILTER (WHERE department IN ('ALCOHOL SALES','FOOD SALES')) > 0
       THEN SUM(value) FILTER (WHERE department = 'FOOD SALES') /
            NULLIF(SUM(value) FILTER (WHERE department IN ('ALCOHOL SALES','FOOD SALES')), 0)
       ELSE NULL END                                                AS dry_frac
FROM touchoffice_department_sales
WHERE site = 'malthouse'
GROUP BY report_date;

COMMENT ON VIEW v_pub_sales_mix IS
'U84 V110. Per-day pub wet/dry sales mix from TouchOffice departments
ALCOHOL SALES / FOOD SALES. Used by v_daily_gp instead of hardcoded 60/40.';

-- Rebuild v_daily_gp to consume the real mix. Falls back to the global
-- 60/40 default ONLY if there is no TouchOffice mix for the day (which
-- would mean the scrape hasn't run yet — old code's behaviour, preserved).
DROP VIEW IF EXISTS v_daily_gp;
CREATE VIEW v_daily_gp AS
WITH cost_by_bucket AS (
  SELECT COALESCE(v.delivery_date, v.invoice_date)                  AS report_date,
         vendor_category_bucket(v.category_canonical)               AS bucket,
         SUM(COALESCE(v.net_amount, 0))::numeric(12,2)              AS net_cost
    FROM vendor_invoice_inbox v
   WHERE v.is_statement = false
     AND v.status NOT IN ('duplicate', 'ignored')
     AND COALESCE(v.delivery_date, v.invoice_date) IS NOT NULL
   GROUP BY 1, 2
),
cost_pivot AS (
  SELECT report_date,
         SUM(net_cost) FILTER (WHERE bucket = 'wet')                AS wet_cost,
         SUM(net_cost) FILTER (WHERE bucket = 'dry')                AS dry_cost,
         SUM(net_cost) FILTER (WHERE bucket = 'cafe')               AS cafe_cost,
         SUM(net_cost) FILTER (WHERE bucket = 'head_office')        AS overhead_cost,
         SUM(net_cost) FILTER (WHERE bucket = 'other')              AS other_cost
    FROM cost_by_bucket
   GROUP BY report_date
)
SELECT
  e.report_date,
  e.pub_net_sales,
  e.sandwich_net_sales,
  e.accom_revenue,
  e.total_revenue,
  COALESCE(p.wet_cost, 0::numeric)        AS wet_cost,
  COALESCE(p.dry_cost, 0::numeric)        AS dry_cost,
  COALESCE(p.cafe_cost, 0::numeric)       AS cafe_cost,
  COALESCE(p.overhead_cost, 0::numeric)   AS overhead_cost,
  COALESCE(p.other_cost, 0::numeric)      AS other_cost,
  -- Surface the wet/dry fraction we used, so callers can audit.
  COALESCE(m.wet_frac, 0.60)              AS wet_frac_used,
  COALESCE(m.dry_frac, 0.40)              AS dry_frac_used,
  CASE
    WHEN e.pub_net_sales > 0 THEN
      ROUND(
        100 * (e.pub_net_sales * COALESCE(m.wet_frac, 0.60) - COALESCE(p.wet_cost, 0))
        / NULLIF(e.pub_net_sales * COALESCE(m.wet_frac, 0.60), 0),
        1
      )
    ELSE NULL
  END                                     AS pub_drink_gp_pct,
  CASE
    WHEN e.pub_net_sales > 0 THEN
      ROUND(
        100 * (e.pub_net_sales * COALESCE(m.dry_frac, 0.40) - COALESCE(p.dry_cost, 0))
        / NULLIF(e.pub_net_sales * COALESCE(m.dry_frac, 0.40), 0),
        1
      )
    ELSE NULL
  END                                     AS pub_food_gp_pct,
  CASE
    WHEN e.sandwich_net_sales > 0 THEN
      ROUND(
        100 * (e.sandwich_net_sales - COALESCE(p.cafe_cost, 0))
        / e.sandwich_net_sales,
        1
      )
    ELSE NULL
  END                                     AS cafe_gp_pct,
  CASE
    WHEN e.total_revenue > 0 THEN
      ROUND(
        100 * (e.total_revenue
               - COALESCE(p.wet_cost, 0)
               - COALESCE(p.dry_cost, 0)
               - COALESCE(p.cafe_cost, 0))
        / e.total_revenue,
        1
      )
    ELSE NULL
  END                                     AS overall_gp_pct
FROM v_daily_unit_economics e
LEFT JOIN cost_pivot p     ON p.report_date = e.report_date
LEFT JOIN v_pub_sales_mix m ON m.report_date = e.report_date
WHERE e.report_date <= CURRENT_DATE
ORDER BY e.report_date DESC;

COMMENT ON VIEW v_daily_gp IS
'U84 V110. Daily GP. wet/dry split sourced from v_pub_sales_mix
(real TouchOffice ALCOHOL/FOOD departments); falls back to 60/40 if a
date has no scraped sales. Also: cost date uses COALESCE(delivery_date,
invoice_date) only — never received_at (U84 invoice-date discipline).';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'homeai_pipeline') THEN
    EXECUTE 'GRANT SELECT ON v_pub_sales_mix TO homeai_pipeline';
  END IF;
END$$;

COMMIT;
