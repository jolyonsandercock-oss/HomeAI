-- V208__projB_search_slugs.sql — Project B searchable slugs (realm work, approved).

INSERT INTO query_whitelist (slug, display_name, sql_template, param_schema, realm, entity_id, created_by, active, approved_at)
VALUES (
'purchase_search', 'Purchase search (line items)',
$sql$
SELECT invoice_date, vendor_name, department, category,
       COALESCE(product, description) AS item, description,
       quantity, unit_price, line_net, entity_id, realm, gate_passed, verified
FROM v_purchase_search
WHERE (:vendor::text     IS NULL OR vendor_name ILIKE '%'||:vendor||'%')
  AND (:department::text IS NULL OR department = :department)
  AND (:category::text   IS NULL OR category = :category)
  AND (:product::text    IS NULL OR product ILIKE '%'||:product||'%' OR description ILIKE '%'||:product||'%')
  AND (:q::text          IS NULL OR vendor_name ILIKE '%'||:q||'%' OR description ILIKE '%'||:q||'%' OR COALESCE(product,'') ILIKE '%'||:q||'%')
  AND (:entity_id::int   IS NULL OR entity_id = :entity_id)
  AND (:date_from::date  IS NULL OR invoice_date >= :date_from)
  AND (:date_to::date    IS NULL OR invoice_date <= :date_to)
ORDER BY invoice_date DESC NULLS LAST
LIMIT 500
$sql$,
'{"vendor":{"type":"string","optional":true},"department":{"type":"string","optional":true},"category":{"type":"string","optional":true},"product":{"type":"string","optional":true},"q":{"type":"string","optional":true},"entity_id":{"type":"int","optional":true},"date_from":{"type":"string","format":"date","optional":true},"date_to":{"type":"string","format":"date","optional":true}}'::jsonb,
'work', 1, 'projB-V208', true, NOW())
ON CONFLICT (slug) DO UPDATE SET sql_template=EXCLUDED.sql_template, param_schema=EXCLUDED.param_schema, approved_at=NOW();

INSERT INTO query_whitelist (slug, display_name, sql_template, param_schema, realm, entity_id, created_by, active, approved_at)
VALUES (
'purchase_spend_summary', 'Purchase spend summary',
$sql$
SELECT CASE COALESCE(:group_by,'vendor')
         WHEN 'vendor'     THEN vendor_name
         WHEN 'department' THEN department
         WHEN 'product'    THEN COALESCE(product, description)
         WHEN 'category'   THEN category
         WHEN 'entity'     THEN entity_id::text
         WHEN 'property'   THEN property_id::text
         ELSE vendor_name END AS group_key,
       count(*) AS lines,
       round(sum(line_net),2) AS spend
FROM v_purchase_search
WHERE (:vendor::text     IS NULL OR vendor_name ILIKE '%'||:vendor||'%')
  AND (:department::text IS NULL OR department = :department)
  AND (:product::text    IS NULL OR product ILIKE '%'||:product||'%' OR description ILIKE '%'||:product||'%')
  AND (:entity_id::int   IS NULL OR entity_id = :entity_id)
  AND (:date_from::date  IS NULL OR invoice_date >= :date_from)
  AND (:date_to::date    IS NULL OR invoice_date <= :date_to)
GROUP BY 1 ORDER BY spend DESC NULLS LAST LIMIT 100
$sql$,
'{"group_by":{"type":"string","optional":true},"vendor":{"type":"string","optional":true},"department":{"type":"string","optional":true},"product":{"type":"string","optional":true},"entity_id":{"type":"int","optional":true},"date_from":{"type":"string","format":"date","optional":true},"date_to":{"type":"string","format":"date","optional":true}}'::jsonb,
'work', 1, 'projB-V208', true, NOW())
ON CONFLICT (slug) DO UPDATE SET sql_template=EXCLUDED.sql_template, param_schema=EXCLUDED.param_schema, approved_at=NOW();

INSERT INTO query_whitelist (slug, display_name, sql_template, param_schema, realm, entity_id, created_by, active, approved_at)
VALUES ('gross_margin_period', 'Gross margin by month/department',
$sql$SELECT month, dept, sales, cogs, gp_pct FROM v_gross_margin_period
WHERE month >= date_trunc('month', CURRENT_DATE) - (COALESCE(:months,12)||' months')::interval
ORDER BY month DESC, dept$sql$,
'{"months":{"type":"int","optional":true,"default":12}}'::jsonb, 'work', 1, 'projB-V208', true, NOW())
ON CONFLICT (slug) DO UPDATE SET sql_template=EXCLUDED.sql_template, param_schema=EXCLUDED.param_schema, approved_at=NOW();

INSERT INTO query_whitelist (slug, display_name, sql_template, param_schema, realm, entity_id, created_by, active, approved_at)
VALUES ('cogs_capture_confidence', 'COGS capture confidence',
$sql$SELECT
  count(*) FILTER (WHERE gate_passed AND is_invoice AND realm='work') AS captured,
  count(*) FILTER (WHERE gate_passed AND is_invoice AND realm='work' AND category IS NOT NULL) AS categorised,
  round(100.0*count(*) FILTER (WHERE gate_passed AND is_invoice AND realm='work' AND category IS NOT NULL)
        / NULLIF(count(*) FILTER (WHERE gate_passed AND is_invoice AND realm='work'),0),1) AS pct_categorised
FROM purchases$sql$,
'{}'::jsonb, 'work', 1, 'projB-V208', true, NOW())
ON CONFLICT (slug) DO UPDATE SET sql_template=EXCLUDED.sql_template, param_schema=EXCLUDED.param_schema, approved_at=NOW();
