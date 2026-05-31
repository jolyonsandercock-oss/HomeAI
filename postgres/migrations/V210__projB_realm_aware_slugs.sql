-- V210__projB_realm_aware_slugs.sql — add optional realm filter to the /invoices
-- driving slugs + a 'realm' group_by, so the page's Business/Personal toggle works.
-- NB: realm RLS is currently transitional (not enforced on the readonly read path),
-- so these return all realms until R4/U147 pins app.current_realm. Owner-only surface
-- for now; gate behind realm-auth before any work-only (Karl) login uses it.

INSERT INTO query_whitelist (slug, display_name, sql_template, param_schema, realm, entity_id, created_by, active, approved_at)
VALUES ('purchase_search', 'Purchase search (line items)',
$sql$
SELECT invoice_date, vendor_name, department, category,
       COALESCE(product, description) AS item, description,
       quantity, unit_price, line_net, entity_id, realm, gate_passed, verified
FROM v_purchase_search
WHERE (:realm::text      IS NULL OR realm = :realm)
  AND (:vendor::text     IS NULL OR vendor_name ILIKE '%'||:vendor||'%')
  AND (:department::text IS NULL OR department = :department)
  AND (:category::text   IS NULL OR category = :category)
  AND (:product::text    IS NULL OR product ILIKE '%'||:product||'%' OR description ILIKE '%'||:product||'%')
  AND (:q::text          IS NULL OR vendor_name ILIKE '%'||:q||'%' OR description ILIKE '%'||:q||'%' OR COALESCE(product,'') ILIKE '%'||:q||'%')
  AND (:date_from::date  IS NULL OR invoice_date >= :date_from)
  AND (:date_to::date    IS NULL OR invoice_date <= :date_to)
ORDER BY invoice_date DESC NULLS LAST LIMIT 500
$sql$,
'{"realm":{"type":"string","optional":true},"vendor":{"type":"string","optional":true},"department":{"type":"string","optional":true},"category":{"type":"string","optional":true},"product":{"type":"string","optional":true},"q":{"type":"string","optional":true},"date_from":{"type":"string","format":"date","optional":true},"date_to":{"type":"string","format":"date","optional":true}}'::jsonb,
'work', 1, 'projB-V210', true, NOW())
ON CONFLICT (slug) DO UPDATE SET sql_template=EXCLUDED.sql_template, param_schema=EXCLUDED.param_schema, approved_at=NOW();

INSERT INTO query_whitelist (slug, display_name, sql_template, param_schema, realm, entity_id, created_by, active, approved_at)
VALUES ('purchase_spend_summary', 'Purchase spend summary',
$sql$
SELECT CASE COALESCE(:group_by,'vendor')
         WHEN 'vendor'     THEN vendor_name
         WHEN 'department' THEN department
         WHEN 'product'    THEN COALESCE(product, description)
         WHEN 'category'   THEN category
         WHEN 'realm'      THEN realm
         WHEN 'entity'     THEN entity_id::text
         ELSE vendor_name END AS group_key,
       count(*) AS lines, round(sum(line_net),2) AS spend
FROM v_purchase_search
WHERE (:realm::text      IS NULL OR realm = :realm)
  AND (:vendor::text     IS NULL OR vendor_name ILIKE '%'||:vendor||'%')
  AND (:department::text IS NULL OR department = :department)
  AND (:product::text    IS NULL OR product ILIKE '%'||:product||'%' OR description ILIKE '%'||:product||'%')
  AND (:date_from::date  IS NULL OR invoice_date >= :date_from)
  AND (:date_to::date    IS NULL OR invoice_date <= :date_to)
GROUP BY 1 ORDER BY spend DESC NULLS LAST LIMIT 100
$sql$,
'{"group_by":{"type":"string","optional":true},"realm":{"type":"string","optional":true},"vendor":{"type":"string","optional":true},"department":{"type":"string","optional":true},"product":{"type":"string","optional":true},"date_from":{"type":"string","format":"date","optional":true},"date_to":{"type":"string","format":"date","optional":true}}'::jsonb,
'work', 1, 'projB-V210', true, NOW())
ON CONFLICT (slug) DO UPDATE SET sql_template=EXCLUDED.sql_template, param_schema=EXCLUDED.param_schema, approved_at=NOW();

INSERT INTO query_whitelist (slug, display_name, sql_template, param_schema, realm, entity_id, created_by, active, approved_at)
VALUES ('purchase_kpis', 'Invoice KPIs',
$sql$
SELECT round(sum(line_net),2) AS spend, count(DISTINCT purchase_id) AS invoices,
       count(*) AS lines, count(DISTINCT vendor_name) AS vendors,
       round(sum(line_net)/NULLIF(count(DISTINCT purchase_id),0),2) AS avg_invoice
FROM v_purchase_search
WHERE gate_passed
  AND (:realm::text      IS NULL OR realm = :realm)
  AND (:vendor::text     IS NULL OR vendor_name ILIKE '%'||:vendor||'%')
  AND (:department::text IS NULL OR department = :department)
  AND (:product::text    IS NULL OR product ILIKE '%'||:product||'%' OR description ILIKE '%'||:product||'%')
  AND (:q::text          IS NULL OR vendor_name ILIKE '%'||:q||'%' OR description ILIKE '%'||:q||'%' OR COALESCE(product,'') ILIKE '%'||:q||'%')
  AND (:date_from::date  IS NULL OR invoice_date >= :date_from)
  AND (:date_to::date    IS NULL OR invoice_date <= :date_to)
$sql$,
'{"realm":{"type":"string","optional":true},"vendor":{"type":"string","optional":true},"department":{"type":"string","optional":true},"product":{"type":"string","optional":true},"q":{"type":"string","optional":true},"date_from":{"type":"string","format":"date","optional":true},"date_to":{"type":"string","format":"date","optional":true}}'::jsonb,
'work', 1, 'projB-V210', true, NOW())
ON CONFLICT (slug) DO UPDATE SET sql_template=EXCLUDED.sql_template, param_schema=EXCLUDED.param_schema, approved_at=NOW();

INSERT INTO query_whitelist (slug, display_name, sql_template, param_schema, realm, entity_id, created_by, active, approved_at)
VALUES ('purchase_spend_by_month', 'Spend by month/department',
$sql$
SELECT date_trunc('month', invoice_date)::date AS month,
       COALESCE(department,'unmapped') AS department, round(sum(line_net),2) AS spend
FROM v_purchase_search
WHERE gate_passed AND invoice_date IS NOT NULL
  AND (:realm::text IS NULL OR realm = :realm)
  AND invoice_date >= date_trunc('month', CURRENT_DATE) - (COALESCE(:months,12)||' months')::interval
GROUP BY 1,2 ORDER BY 1
$sql$,
'{"months":{"type":"int","optional":true,"default":12},"realm":{"type":"string","optional":true}}'::jsonb,
'work', 1, 'projB-V210', true, NOW())
ON CONFLICT (slug) DO UPDATE SET sql_template=EXCLUDED.sql_template, param_schema=EXCLUDED.param_schema, approved_at=NOW();
