-- ============================================================
-- U44 — GP buckets: canonical category → Jo's 5 high-level buckets
-- ============================================================
-- Buckets:
--   wet         = wet_purchase (alcohol/drinks)
--   dry         = dry_purchase (food)
--   cafe        = cafe_stock
--   head_office = utilities + software + repairs_maintenance
--   other       = other / income / unknown
-- ============================================================

CREATE OR REPLACE FUNCTION vendor_category_bucket(canonical TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN canonical = 'wet_purchase'                                       THEN 'wet'
    WHEN canonical = 'dry_purchase'                                       THEN 'dry'
    WHEN canonical = 'cafe_stock'                                         THEN 'cafe'
    WHEN canonical IN ('utilities', 'software', 'repairs_maintenance')    THEN 'head_office'
    WHEN canonical = 'income'                                             THEN 'income_excluded'  -- not a cost, exclude from cost totals
    ELSE 'other'
  END;
$$;

-- Drop dependent views FIRST (column rebuild of vendor_invoice_inbox via generated column)
-- Actually we can't add a STORED generated column on top of a deprecated column easily.
-- Simpler: add a regular column populated via trigger, OR just use the function in views.
-- Going with the latter — no schema change to vendor_invoice_inbox needed.

-- Daily GP view: per-day costs by bucket joined to revenue
DROP VIEW IF EXISTS v_daily_gp;
CREATE VIEW v_daily_gp AS
WITH cost_by_bucket AS (
  SELECT
    COALESCE(delivery_date, invoice_date, received_at::date) AS report_date,
    vendor_category_bucket(category_canonical) AS bucket,
    SUM(COALESCE(net_amount, 0))::numeric(12,2) AS net_cost
  FROM vendor_invoice_inbox
  WHERE is_statement = false
    AND status NOT IN ('duplicate', 'ignored')
  GROUP BY 1, 2
),
cost_pivot AS (
  SELECT
    report_date,
    SUM(net_cost) FILTER (WHERE bucket = 'wet')         AS wet_cost,
    SUM(net_cost) FILTER (WHERE bucket = 'dry')         AS dry_cost,
    SUM(net_cost) FILTER (WHERE bucket = 'cafe')        AS cafe_cost,
    SUM(net_cost) FILTER (WHERE bucket = 'head_office') AS overhead_cost,
    SUM(net_cost) FILTER (WHERE bucket = 'other')       AS other_cost
  FROM cost_by_bucket
  GROUP BY 1
)
SELECT
  e.report_date,
  e.pub_net_sales,
  e.sandwich_net_sales,
  e.accom_revenue,
  e.total_revenue,
  COALESCE(p.wet_cost, 0)      AS wet_cost,
  COALESCE(p.dry_cost, 0)      AS dry_cost,
  COALESCE(p.cafe_cost, 0)     AS cafe_cost,
  COALESCE(p.overhead_cost, 0) AS overhead_cost,
  COALESCE(p.other_cost, 0)    AS other_cost,
  -- GP% per stream
  -- Pub drink GP: a proxy — assume drink is ~60% of pub_net (TouchOffice doesn't split food/drink cleanly).
  -- True split would need a touchoffice_department_sales join; deferred.
  CASE WHEN e.pub_net_sales > 0
       THEN ROUND(100 * (e.pub_net_sales * 0.60 - COALESCE(p.wet_cost, 0))::numeric / NULLIF(e.pub_net_sales * 0.60, 0), 1)
  END AS pub_drink_gp_pct,
  CASE WHEN e.pub_net_sales > 0
       THEN ROUND(100 * (e.pub_net_sales * 0.40 - COALESCE(p.dry_cost, 0))::numeric / NULLIF(e.pub_net_sales * 0.40, 0), 1)
  END AS pub_food_gp_pct,
  CASE WHEN e.sandwich_net_sales > 0
       THEN ROUND(100 * (e.sandwich_net_sales - COALESCE(p.cafe_cost, 0))::numeric / e.sandwich_net_sales, 1)
  END AS cafe_gp_pct,
  CASE WHEN e.total_revenue > 0
       THEN ROUND(100 * (e.total_revenue - COALESCE(p.wet_cost, 0) - COALESCE(p.dry_cost, 0) - COALESCE(p.cafe_cost, 0))::numeric / e.total_revenue, 1)
  END AS overall_gp_pct
FROM v_daily_unit_economics e
LEFT JOIN cost_pivot p ON p.report_date = e.report_date
WHERE e.report_date <= CURRENT_DATE
ORDER BY e.report_date DESC;

GRANT SELECT ON v_daily_gp TO homeai_pipeline, homeai_readonly, metabase_app;

COMMENT ON VIEW v_daily_gp IS
  'U44 — daily GP% per revenue stream. Note: pub_drink_gp_pct and pub_food_gp_pct use a 60/40 proxy split because TouchOffice fixed_totals does not separate food vs drink. Replace with touchoffice_department_sales join when department mapping is confirmed.';
