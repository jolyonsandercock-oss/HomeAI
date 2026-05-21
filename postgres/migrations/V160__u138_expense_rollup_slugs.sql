-- =============================================================================
-- V160 — U138 Phase A: expense rollup slugs for /app/admin
-- =============================================================================
-- Four slugs that power the new "Accumulated expenses from emails" tile:
--   - expense_totals          single-row gross/net/vat + uncategorised £ +
--                             missing_date_count (how many rows lacked an
--                             extracted invoice_date in the window)
--   - expense_top_categories  top-N by vendor_invoice_inbox.category_canonical
--   - expense_top_vendors     top-N by vendor_name (string_agg of sites)
--   - expense_top_families    top-N by vendor_invoice_lines → product_canonical.family
--
-- Date filter uses COALESCE(invoice_date, received_at::date) so emails that
-- haven't had Haiku invoice-date extraction yet still surface (today: 8839
-- of 8951 rows lack invoice_date — almost everything).
--
-- Params (all optional, named — consistent with existing frontend slugs):
--   :date_from  date — defaults CURRENT_DATE - 30
--   :date_to    date — defaults CURRENT_DATE
--   :site       text — 'all' | 'pub' | 'cafe' | 'shared' (default 'all')
--   :limit      int  — default 15 for top-N
--
-- Realm: 'shared' so the /app/* dashboard (request realm = 'work') can read.
-- =============================================================================

BEGIN;

INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, result_format,
   active, created_by, approved_at, approved_by, notes, realm, intent_examples)
VALUES

-- ---------- expense_totals ---------------------------------------------------
('expense_totals',
 'U138 — expense totals (window + site)',
 'Totals of vendor_invoice_inbox over a date range, optionally filtered by site (pub/cafe/all). Includes uncategorised £ and missing-date count so the tile can show data-quality pills.',
 $sql$SELECT
        COALESCE(SUM(gross_amount), 0)::numeric(12,2)   AS total_gross,
        COALESCE(SUM(net_amount),   0)::numeric(12,2)   AS total_net,
        COALESCE(SUM(vat_amount),   0)::numeric(12,2)   AS total_vat,
        COUNT(*)                                        AS invoice_count,
        COUNT(*) FILTER (WHERE category_canonical IS NULL OR category_canonical = '')                                AS uncategorised_count,
        COALESCE(SUM(gross_amount) FILTER (WHERE category_canonical IS NULL OR category_canonical = ''), 0)::numeric(12,2) AS uncategorised_gross,
        COUNT(*) FILTER (WHERE invoice_date IS NULL) AS missing_date_count
      FROM vendor_invoice_inbox
     WHERE COALESCE(invoice_date, received_at::date) >= COALESCE(:date_from::date, CURRENT_DATE - 30)
       AND COALESCE(invoice_date, received_at::date) <= COALESCE(:date_to::date,   CURRENT_DATE)
       AND status NOT IN ('duplicate','ignored')
       AND (COALESCE(:site::text,'all') = 'all' OR site = :site)$sql$,
 '{"date_from":{"type":"string","format":"date","optional":true},"date_to":{"type":"string","format":"date","optional":true},"site":{"type":"string","optional":true}}'::jsonb,
 'table', true, 'u138', NOW(), 'u138', NULL, 'shared',
 ARRAY['expenses total','spend total','invoice totals']),

-- ---------- expense_top_categories -------------------------------------------
('expense_top_categories',
 'U138 — top expense categories (window + site)',
 'Top categories by gross spend on vendor_invoice_inbox in the window. Uses category_canonical with an explicit "(uncategorised)" bucket.',
 $sql$SELECT
        COALESCE(NULLIF(category_canonical, ''), '(uncategorised)') AS category,
        SUM(gross_amount)::numeric(12,2) AS total_gross,
        COUNT(*) AS invoice_count
      FROM vendor_invoice_inbox
     WHERE COALESCE(invoice_date, received_at::date) >= COALESCE(:date_from::date, CURRENT_DATE - 30)
       AND COALESCE(invoice_date, received_at::date) <= COALESCE(:date_to::date,   CURRENT_DATE)
       AND status NOT IN ('duplicate','ignored')
       AND (COALESCE(:site::text,'all') = 'all' OR site = :site)
     GROUP BY 1
     ORDER BY total_gross DESC NULLS LAST
     LIMIT COALESCE(:limit::int, 15)$sql$,
 '{"date_from":{"type":"string","format":"date","optional":true},"date_to":{"type":"string","format":"date","optional":true},"site":{"type":"string","optional":true},"limit":{"type":"int","optional":true}}'::jsonb,
 'table', true, 'u138', NOW(), 'u138', NULL, 'shared',
 ARRAY['top categories','spend by category']),

-- ---------- expense_top_vendors ----------------------------------------------
('expense_top_vendors',
 'U138 — top vendors (window + site)',
 'Top vendors by gross spend in the window. Collapses pub/cafe duplicates into a comma-separated "sites" string.',
 $sql$SELECT
        COALESCE(NULLIF(vendor_name, ''), vendor_domain, '(unknown)') AS vendor,
        SUM(gross_amount)::numeric(12,2) AS total_gross,
        COUNT(*) AS invoice_count,
        MAX(COALESCE(invoice_date, received_at::date)) AS last_seen,
        string_agg(DISTINCT site, ', ' ORDER BY site) AS sites
      FROM vendor_invoice_inbox
     WHERE COALESCE(invoice_date, received_at::date) >= COALESCE(:date_from::date, CURRENT_DATE - 30)
       AND COALESCE(invoice_date, received_at::date) <= COALESCE(:date_to::date,   CURRENT_DATE)
       AND status NOT IN ('duplicate','ignored')
       AND (COALESCE(:site::text,'all') = 'all' OR site = :site)
     GROUP BY 1
     ORDER BY total_gross DESC NULLS LAST
     LIMIT COALESCE(:limit::int, 15)$sql$,
 '{"date_from":{"type":"string","format":"date","optional":true},"date_to":{"type":"string","format":"date","optional":true},"site":{"type":"string","optional":true},"limit":{"type":"int","optional":true}}'::jsonb,
 'table', true, 'u138', NOW(), 'u138', NULL, 'shared',
 ARRAY['top vendors','biggest suppliers','expense vendors']),

-- ---------- expense_top_families ---------------------------------------------
('expense_top_families',
 'U138 — top product families from line items (window + site)',
 'Top product families by line_gross. Joins vendor_invoice_lines → product_canonical. Lines with no canonical mapping fall into "(unclassified)" — heads-up: only ~3% of lines are mapped today, so this bucket will dominate until U138 Phase D training lands.',
 $sql$SELECT
        COALESCE(pc.family, '(unclassified)') AS family,
        SUM(vil.line_gross)::numeric(12,2) AS total_gross,
        COUNT(*) AS line_count,
        COUNT(DISTINCT vii.id) AS invoice_count
      FROM vendor_invoice_lines vil
      JOIN vendor_invoice_inbox vii ON vii.id = vil.invoice_id
      LEFT JOIN product_canonical pc ON pc.id = vil.canonical_id
     WHERE COALESCE(vii.invoice_date, vii.received_at::date) >= COALESCE(:date_from::date, CURRENT_DATE - 30)
       AND COALESCE(vii.invoice_date, vii.received_at::date) <= COALESCE(:date_to::date,   CURRENT_DATE)
       AND vii.status NOT IN ('duplicate','ignored')
       AND (COALESCE(:site::text,'all') = 'all' OR vii.site = :site)
     GROUP BY 1
     ORDER BY total_gross DESC NULLS LAST
     LIMIT COALESCE(:limit::int, 15)$sql$,
 '{"date_from":{"type":"string","format":"date","optional":true},"date_to":{"type":"string","format":"date","optional":true},"site":{"type":"string","optional":true},"limit":{"type":"int","optional":true}}'::jsonb,
 'table', true, 'u138', NOW(), 'u138', NULL, 'shared',
 ARRAY['top product families','line item rollup','what did i buy']);

COMMIT;
