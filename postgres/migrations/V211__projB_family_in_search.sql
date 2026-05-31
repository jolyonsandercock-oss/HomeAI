-- V211__projB_family_in_search.sql — expose product family (the reliable canonical
-- level) in the search view + slugs, now that purchase_lines are 100% canonicalised.

-- NB: family appended LAST so CREATE OR REPLACE works over the V207 view (can't
-- insert a column mid-list). On a fresh DB the column order is cosmetic.
CREATE OR REPLACE VIEW v_purchase_search AS
SELECT p.id AS purchase_id, pl.id AS line_id, p.invoice_date,
       p.vendor_name, p.vendor_id,
       COALESCE(pl.category, p.category) AS category,
       m.department,
       pl.product_canonical_id, pc.name AS product,
       pl.description, pl.quantity, pl.unit, pl.unit_price, pl.line_net,
       p.entity_id, p.realm, p.property_id, p.gross_amount AS invoice_gross,
       p.gate_passed, p.verified,
       pc.family AS family
FROM purchases p
JOIN purchase_lines pl ON pl.purchase_id = p.id
LEFT JOIN cogs_category_map m ON m.purchase_category = COALESCE(pl.category, p.category)
LEFT JOIN product_canonical pc ON pc.id = pl.product_canonical_id
WHERE p.is_invoice;

-- purchase_search: + family output + optional family filter
INSERT INTO query_whitelist (slug, display_name, sql_template, param_schema, realm, entity_id, created_by, active, approved_at)
VALUES ('purchase_search', 'Purchase search (line items)',
$sql$
SELECT invoice_date, vendor_name, department, category, family,
       COALESCE(product, description) AS item, description,
       quantity, unit_price, line_net, entity_id, realm, gate_passed, verified
FROM v_purchase_search
WHERE (:realm::text      IS NULL OR realm = :realm)
  AND (:family::text     IS NULL OR family = :family)
  AND (:vendor::text     IS NULL OR vendor_name ILIKE '%'||:vendor||'%')
  AND (:department::text IS NULL OR department = :department)
  AND (:category::text   IS NULL OR category = :category)
  AND (:product::text    IS NULL OR product ILIKE '%'||:product||'%' OR description ILIKE '%'||:product||'%')
  AND (:q::text          IS NULL OR vendor_name ILIKE '%'||:q||'%' OR description ILIKE '%'||:q||'%' OR COALESCE(product,'') ILIKE '%'||:q||'%')
  AND (:date_from::date  IS NULL OR invoice_date >= :date_from)
  AND (:date_to::date    IS NULL OR invoice_date <= :date_to)
ORDER BY invoice_date DESC NULLS LAST LIMIT 500
$sql$,
'{"realm":{"type":"string","optional":true},"family":{"type":"string","optional":true},"vendor":{"type":"string","optional":true},"department":{"type":"string","optional":true},"category":{"type":"string","optional":true},"product":{"type":"string","optional":true},"q":{"type":"string","optional":true},"date_from":{"type":"string","format":"date","optional":true},"date_to":{"type":"string","format":"date","optional":true}}'::jsonb,
'work', 1, 'projB-V211', true, NOW())
ON CONFLICT (slug) DO UPDATE SET sql_template=EXCLUDED.sql_template, param_schema=EXCLUDED.param_schema, approved_at=NOW();

-- purchase_spend_summary: + 'family' group_by + optional family filter
INSERT INTO query_whitelist (slug, display_name, sql_template, param_schema, realm, entity_id, created_by, active, approved_at)
VALUES ('purchase_spend_summary', 'Purchase spend summary',
$sql$
SELECT CASE COALESCE(:group_by,'vendor')
         WHEN 'vendor'     THEN vendor_name
         WHEN 'department' THEN department
         WHEN 'family'     THEN family
         WHEN 'product'    THEN COALESCE(product, description)
         WHEN 'category'   THEN category
         WHEN 'realm'      THEN realm
         WHEN 'entity'     THEN entity_id::text
         ELSE vendor_name END AS group_key,
       count(*) AS lines, round(sum(line_net),2) AS spend
FROM v_purchase_search
WHERE (:realm::text      IS NULL OR realm = :realm)
  AND (:family::text     IS NULL OR family = :family)
  AND (:vendor::text     IS NULL OR vendor_name ILIKE '%'||:vendor||'%')
  AND (:department::text IS NULL OR department = :department)
  AND (:product::text    IS NULL OR product ILIKE '%'||:product||'%' OR description ILIKE '%'||:product||'%')
  AND (:date_from::date  IS NULL OR invoice_date >= :date_from)
  AND (:date_to::date    IS NULL OR invoice_date <= :date_to)
GROUP BY 1 ORDER BY spend DESC NULLS LAST LIMIT 100
$sql$,
'{"group_by":{"type":"string","optional":true},"realm":{"type":"string","optional":true},"family":{"type":"string","optional":true},"vendor":{"type":"string","optional":true},"department":{"type":"string","optional":true},"product":{"type":"string","optional":true},"date_from":{"type":"string","format":"date","optional":true},"date_to":{"type":"string","format":"date","optional":true}}'::jsonb,
'work', 1, 'projB-V211', true, NOW())
ON CONFLICT (slug) DO UPDATE SET sql_template=EXCLUDED.sql_template, param_schema=EXCLUDED.param_schema, approved_at=NOW();
