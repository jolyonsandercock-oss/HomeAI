-- ============================================================
-- U47a — Invoice site column + smoothed GP + weather seasonality view
-- ============================================================
-- 1. vendor_invoice_inbox.site (pub/cafe/shared) from account_canonical
-- 2. gp_window_smoothed() — accrues invoice cost across delivery window
-- 3. v_weather_seasonality — year-prior comparison view
-- ============================================================

-- ── 1. Invoice site column ──────────────────────────────────
-- Use a plain column + trigger (generated columns can't use subqueries
-- or non-immutable funcs). For now derive site from account text directly.

ALTER TABLE vendor_invoice_inbox
  ADD COLUMN IF NOT EXISTS site TEXT;

UPDATE vendor_invoice_inbox
SET site = CASE
  WHEN LOWER(COALESCE(account, '')) LIKE '%mal125%'        THEN 'cafe'
  WHEN LOWER(COALESCE(account, '')) LIKE '%sandwich%'      THEN 'cafe'
  WHEN LOWER(COALESCE(account, '')) LIKE '%cafe%'          THEN 'cafe'
  WHEN LOWER(COALESCE(vendor_name, '')) LIKE '%cafe%'      THEN 'cafe'
  WHEN LOWER(COALESCE(account, '')) LIKE '%malthouse%'     THEN 'pub'
  WHEN LOWER(COALESCE(account, '')) LIKE '%pub%'           THEN 'pub'
  WHEN LOWER(COALESCE(account, '')) LIKE '%inn%'           THEN 'pub'
  WHEN category_canonical IN ('wet_purchase','dry_purchase')  THEN 'pub'
  WHEN category_canonical = 'cafe_stock'                      THEN 'cafe'
  ELSE 'shared'
END
WHERE site IS NULL;

CREATE INDEX IF NOT EXISTS idx_vii_site ON vendor_invoice_inbox(site);

CREATE OR REPLACE FUNCTION vendor_invoice_site_trigger() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  NEW.site := CASE
    WHEN LOWER(COALESCE(NEW.account, '')) LIKE '%mal125%'        THEN 'cafe'
    WHEN LOWER(COALESCE(NEW.account, '')) LIKE '%sandwich%'      THEN 'cafe'
    WHEN LOWER(COALESCE(NEW.account, '')) LIKE '%cafe%'          THEN 'cafe'
    WHEN LOWER(COALESCE(NEW.vendor_name, '')) LIKE '%cafe%'      THEN 'cafe'
    WHEN LOWER(COALESCE(NEW.account, '')) LIKE '%malthouse%'     THEN 'pub'
    WHEN LOWER(COALESCE(NEW.account, '')) LIKE '%pub%'           THEN 'pub'
    WHEN LOWER(COALESCE(NEW.account, '')) LIKE '%inn%'           THEN 'pub'
    WHEN NEW.category_canonical IN ('wet_purchase','dry_purchase') THEN 'pub'
    WHEN NEW.category_canonical = 'cafe_stock'                     THEN 'cafe'
    ELSE 'shared'
  END;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_vii_site ON vendor_invoice_inbox;
CREATE TRIGGER trg_vii_site
BEFORE INSERT OR UPDATE OF account, vendor_name, category_canonical
ON vendor_invoice_inbox
FOR EACH ROW EXECUTE FUNCTION vendor_invoice_site_trigger();

COMMENT ON COLUMN vendor_invoice_inbox.site IS
  'U47a — derived pub/cafe/shared from account/vendor/category. Maintained by trg_vii_site.';

-- ── 2. Smoothed GP ──────────────────────────────────────────
-- Accrue invoice costs across (delivery_date - smoothing/2 .. + smoothing/2)
-- to even out lumpy invoice arrival. Counts only the proportion of each
-- invoice's smoothing window that falls inside the requested GP window.

CREATE OR REPLACE FUNCTION gp_window_smoothed(
  d_from        DATE,
  d_to          DATE,
  smoothing     INT DEFAULT 14
)
RETURNS TABLE (
  window_from              DATE,
  window_to                DATE,
  days                     INT,
  smoothing_days           INT,
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
  overall_gp_pct           NUMERIC,
  invoice_count_window     INT,
  coverage_ratio           NUMERIC   -- 0..1, fraction of expected invoices present
)
LANGUAGE sql STABLE AS $$
WITH inv AS (
  SELECT
    COALESCE(delivery_date, invoice_date, received_at::date) AS d,
    net_amount,
    vendor_category_bucket(category_canonical) AS bucket,
    category_canonical
  FROM vendor_invoice_inbox
  WHERE is_statement = false
    AND status NOT IN ('duplicate','ignored')
    AND vendor_category_bucket(category_canonical) <> 'income_excluded'
    AND COALESCE(delivery_date, invoice_date, received_at::date)
        BETWEEN d_from - (smoothing/2) AND d_to + (smoothing/2)
),
inv_accrued AS (
  -- Each invoice contributes a fraction of its value equal to
  -- (overlap of its smoothing window with the GP window) / smoothing.
  SELECT
    bucket, category_canonical,
    net_amount * (
      LEAST(d_to, d + (smoothing/2))::date
      - GREATEST(d_from, d - (smoothing/2))::date + 1
    )::numeric / smoothing AS accrued
  FROM inv
  WHERE d + (smoothing/2) >= d_from AND d - (smoothing/2) <= d_to
),
cost_agg AS (
  SELECT
    SUM(accrued) FILTER (WHERE bucket = 'wet')               AS wet,
    SUM(accrued) FILTER (WHERE bucket = 'dry')               AS dry,
    SUM(accrued) FILTER (WHERE bucket = 'cafe')              AS cafe,
    SUM(accrued) FILTER (WHERE bucket = 'head_office')       AS overhead,
    SUM(accrued) FILTER (WHERE category_canonical='software') AS software,
    SUM(accrued) FILTER (WHERE bucket = 'other')             AS other_c,
    SUM(accrued)                                             AS total_c,
    COUNT(*)                                                 AS n_invoices
  FROM inv_accrued
),
rev_agg AS (
  SELECT
    SUM(pub_net_sales)::numeric      AS pub,
    SUM(sandwich_net_sales)::numeric AS cafe_rev,
    SUM(accom_revenue)::numeric      AS accom,
    SUM(total_revenue)::numeric      AS total_r
  FROM v_daily_unit_economics
  WHERE report_date BETWEEN d_from AND d_to
),
expected AS (
  -- Expected invoices for this window = (avg invoices/day over the last 90d) × window_days
  SELECT
    (d_to - d_from + 1)::int * GREATEST(
      (SELECT COUNT(*)::numeric / 90
         FROM vendor_invoice_inbox
         WHERE is_statement = false
           AND status NOT IN ('duplicate','ignored')
           AND COALESCE(delivery_date, invoice_date, received_at::date)
               > CURRENT_DATE - 90), 0.5
    ) AS expected_n
)
SELECT
  d_from, d_to, (d_to - d_from + 1)::int, smoothing,
  r.pub, r.cafe_rev, r.accom, r.total_r,
  COALESCE(c.wet, 0), COALESCE(c.dry, 0), COALESCE(c.cafe, 0),
  COALESCE(c.overhead, 0), COALESCE(c.software, 0), COALESCE(c.other_c, 0),
  COALESCE(c.total_c, 0),
  CASE WHEN COALESCE(r.pub, 0) > 0
       THEN ROUND(100 * (r.pub * 0.60 - COALESCE(c.wet, 0)) / NULLIF(r.pub * 0.60, 0), 1) END,
  CASE WHEN COALESCE(r.pub, 0) > 0
       THEN ROUND(100 * (r.pub * 0.40 - COALESCE(c.dry, 0)) / NULLIF(r.pub * 0.40, 0), 1) END,
  CASE WHEN COALESCE(r.cafe_rev, 0) > 0 AND COALESCE(c.cafe, 0) > 0
       THEN ROUND(100 * (r.cafe_rev - COALESCE(c.cafe, 0)) / r.cafe_rev, 1) END,
  CASE WHEN COALESCE(r.total_r, 0) > 0
       THEN ROUND(100 * (r.total_r - COALESCE(c.total_c, 0)) / r.total_r, 1) END,
  COALESCE(c.n_invoices, 0)::int,
  CASE WHEN expected.expected_n > 0
       THEN LEAST(1.0, COALESCE(c.n_invoices, 0) / expected.expected_n) END
FROM rev_agg r CROSS JOIN cost_agg c CROSS JOIN expected;
$$;

COMMENT ON FUNCTION gp_window_smoothed(date, date, int) IS
  'U47a — GP roll-up with invoice-cost smoothing across the delivery window. ' ||
  'Smoothing defaults to 14d. Returns coverage_ratio in [0,1] indicating ' ||
  'whether invoice volume in the window is normal — amber the tile when < 0.4.';

GRANT EXECUTE ON FUNCTION gp_window_smoothed(date, date, int) TO homeai_readonly;

-- ── 3. Weather seasonality ─────────────────────────────────
-- Side-by-side year-prior comparison. Useful once 400d backfill lands.

CREATE OR REPLACE VIEW v_weather_seasonality AS
SELECT
  w.observation_date,
  w.hours_sunshine, w.rain_mm, w.avg_temp_c, w.peak_temp_c, w.max_wind_mph,
  w_prior.observation_date AS prior_year_date,
  w_prior.hours_sunshine   AS prior_sunshine,
  w_prior.rain_mm          AS prior_rain_mm,
  w_prior.peak_temp_c      AS prior_peak_temp,
  (w.peak_temp_c - w_prior.peak_temp_c) AS temp_delta_yoy,
  (w.rain_mm - w_prior.rain_mm)         AS rain_delta_yoy
FROM weather_daily w
LEFT JOIN weather_daily w_prior
  ON w_prior.observation_date = w.observation_date - INTERVAL '1 year'
ORDER BY w.observation_date DESC;

GRANT SELECT ON v_weather_seasonality TO homeai_pipeline, homeai_readonly, metabase_app;

COMMENT ON VIEW v_weather_seasonality IS
  'U47a — weather year-on-year comparison. Becomes meaningful once 400d backfill is in.';
