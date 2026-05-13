-- ============================================================
-- U34 — Cost Truth: invoice depth + workforce departments + per-team view + cost-vs-sales
-- ============================================================
-- 1. Extend vendor_invoice_inbox with net/vat/gross/delivery_date/is_statement
-- 2. New vendor_invoice_lines table for multi-line invoices
-- 3. New workforce_departments lookup table + team column
-- 4. v_daily_labour_by_team view
-- 5. v_daily_cost_vs_sales view
-- ============================================================

-- ── 1. Invoice depth fields ──────────────────────────────────
ALTER TABLE vendor_invoice_inbox
  ADD COLUMN IF NOT EXISTS net_amount             NUMERIC(12,2),
  ADD COLUMN IF NOT EXISTS vat_amount             NUMERIC(12,2),
  ADD COLUMN IF NOT EXISTS gross_amount           NUMERIC(12,2),
  ADD COLUMN IF NOT EXISTS vat_rate               NUMERIC(5,2),
  ADD COLUMN IF NOT EXISTS delivery_date          DATE,
  ADD COLUMN IF NOT EXISTS is_statement           BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS extraction_confidence  NUMERIC(4,3),
  ADD COLUMN IF NOT EXISTS extraction_method      TEXT,
  ADD COLUMN IF NOT EXISTS extracted_at           TIMESTAMPTZ;

-- Existing status enum needs 'extracted' (already there) + add 'statement' so
-- statements don't get accidentally totalled as invoices.
ALTER TABLE vendor_invoice_inbox
  DROP CONSTRAINT IF EXISTS vendor_invoice_inbox_status_check;
ALTER TABLE vendor_invoice_inbox
  ADD CONSTRAINT vendor_invoice_inbox_status_check
  CHECK (status IN ('new','extracted','paid','disputed','ignored','duplicate','statement','needs_review'));

CREATE INDEX IF NOT EXISTS idx_vii_is_statement ON vendor_invoice_inbox (is_statement, received_at DESC);
CREATE INDEX IF NOT EXISTS idx_vii_delivery     ON vendor_invoice_inbox (delivery_date)     WHERE delivery_date IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_vii_invoice_date ON vendor_invoice_inbox (invoice_date)      WHERE invoice_date IS NOT NULL;

-- ── 2. vendor_invoice_lines ──────────────────────────────────
CREATE TABLE IF NOT EXISTS vendor_invoice_lines (
  id              BIGSERIAL PRIMARY KEY,
  invoice_id      BIGINT NOT NULL REFERENCES vendor_invoice_inbox(id) ON DELETE CASCADE,
  line_no         INT,
  description     TEXT,
  qty             NUMERIC(12,3),
  unit_price      NUMERIC(12,4),
  line_net        NUMERIC(12,2),
  line_vat        NUMERIC(12,2),
  line_gross      NUMERIC(12,2),
  category_hint   TEXT,
  raw_payload     JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (invoice_id, line_no)
);

CREATE INDEX IF NOT EXISTS idx_vil_invoice ON vendor_invoice_lines (invoice_id);

ALTER TABLE vendor_invoice_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation_lines ON vendor_invoice_lines
  USING (EXISTS (
    SELECT 1 FROM vendor_invoice_inbox v
     WHERE v.id = vendor_invoice_lines.invoice_id
       AND (current_setting('app.current_entity', true) = 'all'
            OR v.entity_id = NULLIF(current_setting('app.current_entity', true), '')::int)
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM vendor_invoice_inbox v
     WHERE v.id = vendor_invoice_lines.invoice_id
       AND (current_setting('app.current_entity', true) = 'all'
            OR v.entity_id = NULLIF(current_setting('app.current_entity', true), '')::int)
  ));

GRANT SELECT, INSERT, UPDATE, DELETE ON vendor_invoice_lines TO homeai_pipeline;
GRANT SELECT ON vendor_invoice_lines TO homeai_readonly;
GRANT SELECT ON vendor_invoice_lines TO metabase_app;
GRANT USAGE, SELECT ON SEQUENCE vendor_invoice_lines_id_seq TO homeai_pipeline;

-- ── 3. workforce_departments lookup ──────────────────────────
CREATE TABLE IF NOT EXISTS workforce_departments (
  id              BIGSERIAL PRIMARY KEY,
  external_id     BIGINT UNIQUE NOT NULL,
  entity_id       INT NOT NULL DEFAULT 1,
  name            TEXT NOT NULL,
  team            TEXT,                                   -- kitchen/bar/cafe/front_of_house/accommodation/management/unassigned
  team_source     TEXT NOT NULL DEFAULT 'unmapped',       -- auto | manual | unmapped
  raw_payload     JSONB,
  last_synced_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_wf_dept_team ON workforce_departments (team);
CREATE INDEX IF NOT EXISTS idx_wf_dept_entity ON workforce_departments (entity_id);

ALTER TABLE workforce_departments ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON workforce_departments
  USING (
    CASE WHEN current_setting('app.current_entity', true) = 'all' THEN true
         WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN entity_id = current_setting('app.current_entity', true)::int
         ELSE false
    END)
  WITH CHECK (
    CASE WHEN current_setting('app.current_entity', true) = 'all' THEN true
         WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN entity_id = current_setting('app.current_entity', true)::int
         ELSE false
    END);

GRANT SELECT, INSERT, UPDATE, DELETE ON workforce_departments TO homeai_pipeline;
GRANT SELECT ON workforce_departments TO homeai_readonly;
GRANT SELECT ON workforce_departments TO metabase_app;
GRANT USAGE, SELECT ON SEQUENCE workforce_departments_id_seq TO homeai_pipeline;

-- ── 4. v_daily_labour_by_team ────────────────────────────────
CREATE OR REPLACE VIEW v_daily_labour_by_team AS
SELECT
  s.shift_date AS report_date,
  COALESCE(d.team, 'unassigned') AS team,
  COALESCE(d.name, 'dept_'||s.department_external_id::text) AS department_name,
  s.department_external_id,
  SUM(s.hours_worked)::numeric(10,2) AS hours,
  SUM(
    s.hours_worked
    * (m.hourly_rate_pence::numeric / 100.0)
    * (1::numeric + COALESCE(m.on_cost_pct, 12.5) / 100.0)
  )::numeric(12,2) AS cost_with_oncost,
  COUNT(DISTINCT s.user_external_id) AS staff_count,
  ROUND(
    SUM(s.hours_worked * (m.hourly_rate_pence::numeric / 100.0) * (1::numeric + COALESCE(m.on_cost_pct, 12.5) / 100.0))
    / NULLIF(SUM(s.hours_worked), 0),
  2) AS avg_cost_per_hr
FROM workforce_shifts s
LEFT JOIN staff_meta m            ON m.user_external_id = s.user_external_id
LEFT JOIN workforce_departments d ON d.external_id      = s.department_external_id
WHERE s.hours_worked IS NOT NULL AND s.hours_worked > 0
GROUP BY s.shift_date, d.team, d.name, s.department_external_id;

GRANT SELECT ON v_daily_labour_by_team TO homeai_pipeline;
GRANT SELECT ON v_daily_labour_by_team TO homeai_readonly;
GRANT SELECT ON v_daily_labour_by_team TO metabase_app;

-- ── 5. v_daily_cost_vs_sales ─────────────────────────────────
-- Joins invoice cost (excluding statements) by category to daily revenue.
-- Cost is attributed to delivery_date if present, else invoice_date, else
-- received_at::date as a fallback.
CREATE OR REPLACE VIEW v_daily_cost_vs_sales AS
WITH cost AS (
  SELECT
    COALESCE(delivery_date, invoice_date, received_at::date) AS report_date,
    COALESCE(vendor_category, 'other') AS category,
    SUM(COALESCE(net_amount, 0))::numeric(12,2)   AS net_cost,
    SUM(COALESCE(gross_amount, 0))::numeric(12,2) AS gross_cost,
    COUNT(*) AS invoice_count
  FROM vendor_invoice_inbox
  WHERE is_statement = false
    AND status NOT IN ('duplicate','ignored')
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
    SUM(net_cost) FILTER (WHERE category='wet_purchase')      AS net_wet,
    SUM(net_cost) FILTER (WHERE category='dry_purchase')      AS net_dry,
    SUM(net_cost) FILTER (WHERE category='cafe_stock')        AS net_cafe,
    SUM(net_cost) FILTER (WHERE category='repairs_maintenance') AS net_repairs,
    SUM(net_cost) FILTER (WHERE category='utilities')         AS net_utilities,
    SUM(net_cost) FILTER (WHERE category='other')             AS net_other
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
