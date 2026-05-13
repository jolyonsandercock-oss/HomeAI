-- ============================================================
-- U46 — Rolling-window GP view + per-bucket cost/revenue function
-- ============================================================
-- Extends U44's v_daily_gp (per-day) with arbitrary-window aggregation.
-- ============================================================

CREATE OR REPLACE FUNCTION gp_window(d_from DATE, d_to DATE)
RETURNS TABLE (
  window_from              DATE,
  window_to                DATE,
  days                     INT,
  pub_net_sales            NUMERIC,
  sandwich_net_sales       NUMERIC,
  accom_revenue            NUMERIC,
  total_revenue            NUMERIC,
  wet_cost                 NUMERIC,
  dry_cost                 NUMERIC,
  cafe_cost                NUMERIC,
  overhead_cost            NUMERIC,
  software_cost            NUMERIC,
  other_cost               NUMERIC,
  total_cost               NUMERIC,
  pub_drink_gp_pct         NUMERIC,
  pub_food_gp_pct          NUMERIC,
  cafe_gp_pct              NUMERIC,
  overall_gp_pct           NUMERIC
)
LANGUAGE sql STABLE AS $$
WITH cost_agg AS (
  SELECT
    SUM(COALESCE(net_amount, 0)) FILTER (WHERE vendor_category_bucket(category_canonical) = 'wet')         AS wet,
    SUM(COALESCE(net_amount, 0)) FILTER (WHERE vendor_category_bucket(category_canonical) = 'dry')         AS dry,
    SUM(COALESCE(net_amount, 0)) FILTER (WHERE vendor_category_bucket(category_canonical) = 'cafe')        AS cafe,
    SUM(COALESCE(net_amount, 0)) FILTER (WHERE vendor_category_bucket(category_canonical) = 'head_office') AS overhead,
    SUM(COALESCE(net_amount, 0)) FILTER (WHERE category_canonical = 'software')                            AS software,
    SUM(COALESCE(net_amount, 0)) FILTER (WHERE vendor_category_bucket(category_canonical) = 'other')       AS other_c,
    SUM(COALESCE(net_amount, 0))                                                                           AS total_c
  FROM vendor_invoice_inbox
  WHERE is_statement = false
    AND status NOT IN ('duplicate', 'ignored')
    AND vendor_category_bucket(category_canonical) <> 'income_excluded'
    AND COALESCE(delivery_date, invoice_date, received_at::date) BETWEEN d_from AND d_to
),
rev_agg AS (
  SELECT
    SUM(pub_net_sales)::numeric      AS pub,
    SUM(sandwich_net_sales)::numeric AS cafe_rev,
    SUM(accom_revenue)::numeric      AS accom,
    SUM(total_revenue)::numeric      AS total_r
  FROM v_daily_unit_economics
  WHERE report_date BETWEEN d_from AND d_to
)
SELECT
  d_from, d_to, (d_to - d_from + 1)::int AS days,
  r.pub, r.cafe_rev, r.accom, r.total_r,
  COALESCE(c.wet, 0),
  COALESCE(c.dry, 0),
  COALESCE(c.cafe, 0),
  COALESCE(c.overhead, 0),
  COALESCE(c.software, 0),
  COALESCE(c.other_c, 0),
  COALESCE(c.total_c, 0),
  CASE WHEN COALESCE(r.pub, 0) > 0
       THEN ROUND(100 * (r.pub * 0.60 - COALESCE(c.wet, 0)) / NULLIF(r.pub * 0.60, 0), 1) END,
  CASE WHEN COALESCE(r.pub, 0) > 0
       THEN ROUND(100 * (r.pub * 0.40 - COALESCE(c.dry, 0)) / NULLIF(r.pub * 0.40, 0), 1) END,
  CASE WHEN COALESCE(r.cafe_rev, 0) > 0
       THEN ROUND(100 * (r.cafe_rev - COALESCE(c.cafe, 0)) / r.cafe_rev, 1) END,
  CASE WHEN COALESCE(r.total_r, 0) > 0
       THEN ROUND(100 * (r.total_r - COALESCE(c.total_c, 0)) / r.total_r, 1) END
FROM rev_agg r CROSS JOIN cost_agg c;
$$;

COMMENT ON FUNCTION gp_window(date, date) IS
  'U46 — arbitrary-window GP roll-up. Pub food/drink split is 60/40 proxy until TouchOffice department mapping is wired.';

GRANT EXECUTE ON FUNCTION gp_window(date, date) TO homeai_readonly;
