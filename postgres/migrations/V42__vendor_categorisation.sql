-- ============================================================
-- U34 — Vendor categorisation backfill + canonical mapping
-- ============================================================
-- The existing vendor_category_rules uses display-style labels (Food,
-- Beverage, Maintenance, ...). Jo asked for canonical buckets:
-- wet_purchase, dry_purchase, cafe_stock, repairs_maintenance, utilities, other.
--
-- This migration:
--  1. Backfills vendor_invoice_inbox.vendor_category for rows where
--     vendor_domain matches a rule.
--  2. Adds a `category_canonical` column derived from vendor_category via
--     a small canonical-mapping function.
--  3. Updates v_daily_cost_vs_sales to use category_canonical so totals
--     line up with Jo's preferred labels.
-- ============================================================

-- ── 1. Canonical mapping function ────────────────────────────
CREATE OR REPLACE FUNCTION vendor_category_canonical(raw TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN raw IS NULL                                     THEN NULL
    WHEN lower(raw) IN ('beverage','wet','wet_purchase') THEN 'wet_purchase'
    WHEN lower(raw) IN ('food','dry','dry_purchase')     THEN 'dry_purchase'
    WHEN lower(raw) = 'cafe_stock'                       THEN 'cafe_stock'
    WHEN lower(raw) IN ('maintenance','laundry','repairs','repairs_maintenance') THEN 'repairs_maintenance'
    WHEN lower(raw) IN ('utilities','utility','energy','power','water','gas','electricity') THEN 'utilities'
    WHEN lower(raw) IN ('software','subscriptions','saas') THEN 'software'
    WHEN lower(raw) = 'bookings'                         THEN 'income'        -- guest bookings, not a cost
    ELSE 'other'
  END;
$$;

-- ── 2. Add category_canonical (generated column) ────────────
ALTER TABLE vendor_invoice_inbox
  ADD COLUMN IF NOT EXISTS category_canonical TEXT
  GENERATED ALWAYS AS (vendor_category_canonical(vendor_category)) STORED;

CREATE INDEX IF NOT EXISTS idx_vii_cat_canonical
  ON vendor_invoice_inbox (category_canonical, received_at DESC);

-- ── 3. Backfill vendor_category from rules ──────────────────
-- Match vendor_domain against each rule's domain_pattern (regex). Highest
-- priority (lowest priority number) wins. Skip if vendor_category already set
-- to anything non-null.
UPDATE vendor_invoice_inbox v
   SET vendor_category = r.category
  FROM (
    SELECT DISTINCT ON (vii.id) vii.id, rule.category, rule.priority
      FROM vendor_invoice_inbox vii
      JOIN vendor_category_rules rule
        ON vii.vendor_domain ~ rule.domain_pattern
     WHERE vii.vendor_category IS NULL
     ORDER BY vii.id, rule.priority ASC
  ) r
 WHERE v.id = r.id;

-- ── 4. Rebuild v_daily_cost_vs_sales using category_canonical ─
DROP VIEW IF EXISTS v_daily_cost_vs_sales;
CREATE VIEW v_daily_cost_vs_sales AS
WITH cost AS (
  SELECT
    COALESCE(delivery_date, invoice_date, received_at::date) AS report_date,
    COALESCE(category_canonical, 'other')                    AS category,
    SUM(COALESCE(net_amount, 0))::numeric(12,2)              AS net_cost,
    SUM(COALESCE(gross_amount, 0))::numeric(12,2)            AS gross_cost,
    COUNT(*) AS invoice_count
  FROM vendor_invoice_inbox
  WHERE is_statement = false
    AND status NOT IN ('duplicate','ignored')
    AND COALESCE(category_canonical, 'other') <> 'income'   -- exclude guest-booking emails
  GROUP BY 1, 2
),
cost_total AS (
  SELECT report_date,
         SUM(net_cost)::numeric(12,2)   AS net_cost_all,
         SUM(gross_cost)::numeric(12,2) AS gross_cost_all
  FROM cost GROUP BY 1
),
cat_pivot AS (
  SELECT
    report_date,
    SUM(net_cost) FILTER (WHERE category='wet_purchase')        AS net_wet,
    SUM(net_cost) FILTER (WHERE category='dry_purchase')        AS net_dry,
    SUM(net_cost) FILTER (WHERE category='cafe_stock')          AS net_cafe,
    SUM(net_cost) FILTER (WHERE category='repairs_maintenance') AS net_repairs,
    SUM(net_cost) FILTER (WHERE category='utilities')           AS net_utilities,
    SUM(net_cost) FILTER (WHERE category='software')            AS net_software,
    SUM(net_cost) FILTER (WHERE category='other')               AS net_other
  FROM cost GROUP BY 1
)
SELECT
  e.report_date,
  e.total_revenue,
  e.pub_net_sales,
  e.sandwich_net_sales,
  e.accom_revenue,
  COALESCE(t.net_cost_all, 0)    AS net_cost_all,
  COALESCE(t.gross_cost_all, 0)  AS gross_cost_all,
  COALESCE(p.net_wet, 0)         AS net_wet,
  COALESCE(p.net_dry, 0)         AS net_dry,
  COALESCE(p.net_cafe, 0)        AS net_cafe,
  COALESCE(p.net_repairs, 0)     AS net_repairs,
  COALESCE(p.net_utilities, 0)   AS net_utilities,
  COALESCE(p.net_software, 0)    AS net_software,
  COALESCE(p.net_other, 0)       AS net_other,
  CASE WHEN e.total_revenue > 0
       THEN ROUND(100 * COALESCE(t.net_cost_all, 0) / e.total_revenue, 1)
       ELSE NULL
  END AS cost_pct_of_revenue
FROM v_daily_unit_economics e
LEFT JOIN cost_total t ON t.report_date = e.report_date
LEFT JOIN cat_pivot  p ON p.report_date = e.report_date
WHERE e.report_date <= CURRENT_DATE
ORDER BY e.report_date DESC;

GRANT SELECT ON v_daily_cost_vs_sales TO homeai_pipeline;
GRANT SELECT ON v_daily_cost_vs_sales TO homeai_readonly;
GRANT SELECT ON v_daily_cost_vs_sales TO metabase_app;
