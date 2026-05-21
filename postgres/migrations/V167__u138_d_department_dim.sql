-- =============================================================================
-- V167 — U138 Phase D-i: department dimension on vendor_invoice_lines.
-- =============================================================================
-- Adds a per-line `department` text column with CHECK on the five operational
-- departments Jo cares about: bar / kitchen / rooms / cafe / overhead.
-- Per-line (not per-invoice) because a single Bidvest order has kitchen + bar
-- lines.
--
-- Seeds from xero_bill_lines.tracking_option_1 where the line is Xero-linked:
--   Bar          → bar
--   Restaurant   → kitchen
--   Accommodation→ rooms
-- The 'cafe' and 'overhead' buckets are not represented in Xero tracking
-- (Xero doesn't separate them) and are populated by feedback in D-ii.
--
-- Also adds slug expense_by_department for the ExpenseRollup department chip.
-- =============================================================================

BEGIN;

ALTER TABLE vendor_invoice_lines
  ADD COLUMN department text;

ALTER TABLE vendor_invoice_lines
  ADD CONSTRAINT vendor_invoice_lines_department_check
  CHECK (department IS NULL OR department IN ('bar','kitchen','rooms','cafe','overhead'));

CREATE INDEX idx_vil_department ON vendor_invoice_lines(department)
  WHERE department IS NOT NULL;

-- Seed: map xero tracking_option_1 → department for Xero-linked lines.
-- Match on (invoice → xero_bill_id, line_no) tuple.
WITH mapped AS (
  SELECT vil.id AS line_id,
         CASE xbl.tracking_option_1
           WHEN 'Bar'           THEN 'bar'
           WHEN 'Restaurant'    THEN 'kitchen'
           WHEN 'Accommodation' THEN 'rooms'
         END AS dept
    FROM vendor_invoice_lines vil
    JOIN vendor_invoice_inbox vii ON vii.id = vil.invoice_id
    JOIN xero_bills xb            ON xb.id = vii.xero_bill_id
    JOIN xero_bill_lines xbl
      ON xbl.xero_bill_id = xb.id
     AND xbl.line_no = vil.line_no
   WHERE xbl.tracking_option_1 IN ('Bar','Restaurant','Accommodation')
)
UPDATE vendor_invoice_lines vil SET department = m.dept
  FROM mapped m
 WHERE vil.id = m.line_id;

-- ---------- Slug: expense_by_department --------------------------------------
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, result_format,
   active, created_by, approved_at, approved_by, notes, realm, intent_examples)
VALUES
('expense_by_department',
 'U138 — expense by department (window + site)',
 'Rolls vendor_invoice_lines.line_gross by department over a date window. NULL department lines fall into "(unassigned)" — large bucket until U138-D-ii training fills in.',
 $sql$SELECT
        COALESCE(vil.department, '(unassigned)') AS department,
        SUM(vil.line_gross)::numeric(12,2) AS total_gross,
        COUNT(*) AS line_count,
        COUNT(DISTINCT vii.id) AS invoice_count
      FROM vendor_invoice_lines vil
      JOIN vendor_invoice_inbox vii ON vii.id = vil.invoice_id
     WHERE COALESCE(vii.invoice_date, vii.received_at::date) >= COALESCE(:date_from::date, CURRENT_DATE - 30)
       AND COALESCE(vii.invoice_date, vii.received_at::date) <= COALESCE(:date_to::date,   CURRENT_DATE)
       AND vii.status NOT IN ('duplicate','ignored')
       AND (COALESCE(:site::text,'all') = 'all' OR vii.site = :site)
     GROUP BY 1
     ORDER BY total_gross DESC NULLS LAST$sql$,
 '{"date_from":{"type":"string","format":"date","optional":true},"date_to":{"type":"string","format":"date","optional":true},"site":{"type":"string","optional":true}}'::jsonb,
 'table', true, 'u138', NOW(), 'u138', NULL, 'shared',
 ARRAY['expense by department','department spend','bar vs kitchen spend']);

COMMIT;
