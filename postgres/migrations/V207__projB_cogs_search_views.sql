-- V207__projB_cogs_search_views.sql
-- Project B — searchable COGS layer. Additive/read-side: a department dimension,
-- a property column on purchases, and three views (flat search + COGS + gross margin).

-- 1. Department dimension on the category map
ALTER TABLE cogs_category_map ADD COLUMN IF NOT EXISTS department text;
UPDATE cogs_category_map SET department = CASE purchase_category
    WHEN 'drink_alcohol' THEN 'bar'
    WHEN 'drink_soft'    THEN 'bar'
    WHEN 'food'          THEN 'kitchen'
    WHEN 'packaging'     THEN 'overhead'
    WHEN 'cleaning'      THEN 'overhead'
    WHEN 'utilities'     THEN 'overhead'
    WHEN 'services'      THEN 'overhead'
    WHEN 'repairs'       THEN 'overhead'
    WHEN 'capex'         THEN 'overhead'
    ELSE 'overhead' END;

-- 2. Property linkage column (NULL for business invoices)
ALTER TABLE purchases ADD COLUMN IF NOT EXISTS property_id bigint;
-- Best-effort backfill from the account_property_map registry (by vendor name).
UPDATE purchases p SET property_id = m.property_id
FROM account_property_map m
WHERE p.property_id IS NULL AND m.property_id IS NOT NULL
  AND lower(p.vendor_name) = lower(m.vendor_name);

-- 3. Flat search view — one row per line item, every dimension denormalised.
CREATE OR REPLACE VIEW v_purchase_search AS
SELECT p.id AS purchase_id, pl.id AS line_id, p.invoice_date,
       p.vendor_name, p.vendor_id,
       COALESCE(pl.category, p.category) AS category,
       m.department,
       pl.product_canonical_id, pc.name AS product,
       pl.description, pl.quantity, pl.unit, pl.unit_price, pl.line_net,
       p.entity_id, p.realm, p.property_id, p.gross_amount AS invoice_gross,
       p.gate_passed, p.verified
FROM purchases p
JOIN purchase_lines pl ON pl.purchase_id = p.id
LEFT JOIN cogs_category_map m ON m.purchase_category = COALESCE(pl.category, p.category)
LEFT JOIN product_canonical pc ON pc.id = pl.product_canonical_id
WHERE p.is_invoice;

-- 4. COGS by period × category (work realm, trusted rows only).
CREATE OR REPLACE VIEW v_cogs_period AS
SELECT date_trunc('week',  p.invoice_date)::date AS week,
       date_trunc('month', p.invoice_date)::date AS month,
       COALESCE(pl.category, p.category, 'other') AS category,
       m.department, m.sales_department, m.is_cogs,
       sum(pl.line_net) AS cogs_net
FROM purchases p
JOIN purchase_lines pl ON pl.purchase_id = p.id
LEFT JOIN cogs_category_map m ON m.purchase_category = COALESCE(pl.category, p.category)
WHERE p.gate_passed AND p.is_invoice AND p.realm = 'work' AND p.invoice_date IS NOT NULL
GROUP BY 1,2,3,4,5,6;

-- 5. Gross margin by month × sales department (COGS ↔ TouchOffice sales).
CREATE OR REPLACE VIEW v_gross_margin_period AS
WITH c AS (
  SELECT month, sales_department AS dept, sum(cogs_net) AS cogs
  FROM v_cogs_period WHERE is_cogs AND sales_department IS NOT NULL
  GROUP BY 1,2
),
s AS (
  SELECT date_trunc('month', report_date)::date AS month, department AS dept, sum(value) AS sales
  FROM touchoffice_department_sales
  GROUP BY 1,2
)
SELECT COALESCE(c.month, s.month) AS month, COALESCE(c.dept, s.dept) AS dept,
       s.sales, c.cogs,
       CASE WHEN s.sales > 0 THEN round((((s.sales - COALESCE(c.cogs,0)) / s.sales) * 100)::numeric, 1) END AS gp_pct
FROM c FULL JOIN s ON c.month = s.month AND c.dept = s.dept;

GRANT SELECT ON v_purchase_search, v_cogs_period, v_gross_margin_period TO homeai_readonly;
