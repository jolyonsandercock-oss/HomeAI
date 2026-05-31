-- V209__projB_invoices_page_slugs.sql — slugs backing the /invoices page (work realm).

-- KPI totals for the active filter set.
INSERT INTO query_whitelist (slug, display_name, sql_template, param_schema, realm, entity_id, created_by, active, approved_at)
VALUES ('purchase_kpis', 'Invoice KPIs',
$sql$
SELECT round(sum(line_net),2) AS spend,
       count(DISTINCT purchase_id) AS invoices,
       count(*) AS lines,
       count(DISTINCT vendor_name) AS vendors,
       round(sum(line_net)/NULLIF(count(DISTINCT purchase_id),0),2) AS avg_invoice
FROM v_purchase_search
WHERE gate_passed
  AND (:vendor::text     IS NULL OR vendor_name ILIKE '%'||:vendor||'%')
  AND (:department::text IS NULL OR department = :department)
  AND (:product::text    IS NULL OR product ILIKE '%'||:product||'%' OR description ILIKE '%'||:product||'%')
  AND (:q::text          IS NULL OR vendor_name ILIKE '%'||:q||'%' OR description ILIKE '%'||:q||'%' OR COALESCE(product,'') ILIKE '%'||:q||'%')
  AND (:date_from::date  IS NULL OR invoice_date >= :date_from)
  AND (:date_to::date    IS NULL OR invoice_date <= :date_to)
$sql$,
'{"vendor":{"type":"string","optional":true},"department":{"type":"string","optional":true},"product":{"type":"string","optional":true},"q":{"type":"string","optional":true},"date_from":{"type":"string","format":"date","optional":true},"date_to":{"type":"string","format":"date","optional":true}}'::jsonb,
'work', 1, 'projB-V209', true, NOW())
ON CONFLICT (slug) DO UPDATE SET sql_template=EXCLUDED.sql_template, param_schema=EXCLUDED.param_schema, approved_at=NOW();

-- Monthly spend by department (stacked-bar chart).
INSERT INTO query_whitelist (slug, display_name, sql_template, param_schema, realm, entity_id, created_by, active, approved_at)
VALUES ('purchase_spend_by_month', 'Spend by month/department',
$sql$
SELECT date_trunc('month', invoice_date)::date AS month,
       COALESCE(department,'unmapped') AS department,
       round(sum(line_net),2) AS spend
FROM v_purchase_search
WHERE gate_passed AND invoice_date IS NOT NULL
  AND invoice_date >= date_trunc('month', CURRENT_DATE) - (COALESCE(:months,12)||' months')::interval
GROUP BY 1,2 ORDER BY 1
$sql$,
'{"months":{"type":"int","optional":true,"default":12}}'::jsonb,
'work', 1, 'projB-V209', true, NOW())
ON CONFLICT (slug) DO UPDATE SET sql_template=EXCLUDED.sql_template, param_schema=EXCLUDED.param_schema, approved_at=NOW();

-- Exceptions lane: invoices needing attention (uncategorised / low-confidence).
INSERT INTO query_whitelist (slug, display_name, sql_template, param_schema, realm, entity_id, created_by, active, approved_at)
VALUES ('purchase_exceptions', 'Invoices needing attention',
$sql$
SELECT id, invoice_date, vendor_name, gross_amount, extraction_tier, confidence,
       CASE WHEN NOT gate_passed THEN 'low confidence'
            WHEN category IS NULL THEN 'uncategorised'
            ELSE 'review' END AS issue
FROM purchases
WHERE is_invoice AND realm='work'
  AND (NOT gate_passed OR category IS NULL)
ORDER BY (NOT gate_passed) DESC, invoice_date DESC NULLS LAST
LIMIT 200
$sql$,
'{}'::jsonb, 'work', 1, 'projB-V209', true, NOW())
ON CONFLICT (slug) DO UPDATE SET sql_template=EXCLUDED.sql_template, param_schema=EXCLUDED.param_schema, approved_at=NOW();
