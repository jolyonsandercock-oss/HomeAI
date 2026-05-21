-- =============================================================================
-- V192 — U174: profitability slugs
-- =============================================================================
-- Surfaces margin per room type, per PLU, and top drivers today with
-- gross-margin annotation. Cost-side comes from xero_bill_lines spend
-- attributed to plu_descriptor where possible; falls back to category.
-- =============================================================================

BEGIN;

-- Per room type revenue 30d
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'revenue_by_room_type_30d',
  'Revenue by room type — last 30 days',
  'U174: per room_type, nights sold + revenue + avg rate. Drives which rooms earn most £.',
  E'SELECT room_type,
           count(*) AS nights_sold,
           SUM(rate_per_night)::numeric(12,2) AS revenue_gbp,
           AVG(rate_per_night)::numeric(10,2) AS avg_rate,
           MIN(rate_per_night)::numeric(10,2) AS min_rate,
           MAX(rate_per_night)::numeric(10,2) AS max_rate
      FROM caterbook_room_nights
     WHERE night_date BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE - 1
     GROUP BY room_type
     ORDER BY revenue_gbp DESC NULLS LAST',
  '{}', 'shared', true, NOW(), 'u174', 'u174'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- PLU "profitability" proxy — value sold (no per-PLU cost yet, will improve
-- once recipe cost model lands in Phase 8).
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'plu_top_sellers_30d',
  'PLU top sellers — last 30 days',
  'U174: top-selling items by gross value. (True margin needs recipe-cost model; Phase 8.)',
  E'SELECT site, descriptor,
           SUM(quantity)::numeric(12,2) AS qty_sold,
           SUM(value)::numeric(12,2) AS gross_gbp,
           CASE WHEN SUM(quantity) > 0
                THEN (SUM(value) / SUM(quantity))::numeric(10,2) ELSE NULL END AS avg_unit_price,
           count(DISTINCT report_date) AS days_with_sales
      FROM touchoffice_plu_sales
     WHERE report_date BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE - 1
     GROUP BY site, descriptor
     ORDER BY SUM(value) DESC NULLS LAST
     LIMIT 30',
  '{}', 'shared', true, NOW(), 'u174', 'u174'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- Top revenue drivers today (replaces frontend_today_gross with site detail)
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'top_revenue_drivers_today',
  'Top revenue drivers — today',
  'U174: today top revenue items per site. Where is today money coming from.',
  E'SELECT site, descriptor,
           SUM(quantity)::numeric(10,2) AS qty,
           SUM(value)::numeric(12,2) AS gross_gbp
      FROM touchoffice_plu_sales
     WHERE report_date = CURRENT_DATE
     GROUP BY site, descriptor
     ORDER BY SUM(value) DESC NULLS LAST
     LIMIT 20',
  '{}', 'shared', true, NOW(), 'u174', 'u174'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- Decomposition slug: revenue → cost-of-goods (xero food/drink suppliers)
-- → gross margin
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'gross_margin_30d',
  'Gross margin — last 30 days',
  'U174: revenue minus food/drink supplier spend. Crude — does not yet attribute per dish.',
  E'WITH revenue AS (
      SELECT SUM(value)::numeric(12,2) AS food_drink_rev
        FROM touchoffice_department_sales
       WHERE report_date BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE - 1
    ),
    rooms_rev AS (
      SELECT SUM(rate_per_night)::numeric(12,2) AS rooms_rev
        FROM caterbook_room_nights
       WHERE night_date BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE - 1
    ),
    cogs AS (
      SELECT SUM(total)::numeric(12,2) AS supplier_spend
        FROM xero_bills xb
       WHERE invoice_date BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE - 1
         AND xb.contact_name IN (
           ''St Austell Brewery'', ''J&R Food Services Ltd'',
           ''West Country Food Service'', ''Forest Produce'',
           ''Kingfisher Brixham'', ''Dole Foodservice Bodmin'',
           ''Quatra'', ''Hopwell Limited''
         )
    )
    SELECT
      (SELECT food_drink_rev FROM revenue)        AS food_drink_revenue,
      (SELECT rooms_rev FROM rooms_rev)           AS rooms_revenue,
      ((SELECT food_drink_rev FROM revenue) + (SELECT rooms_rev FROM rooms_rev))::numeric(12,2) AS total_revenue,
      (SELECT supplier_spend FROM cogs)           AS cost_of_goods,
      (((SELECT food_drink_rev FROM revenue) + (SELECT rooms_rev FROM rooms_rev)) - (SELECT supplier_spend FROM cogs))::numeric(12,2) AS gross_margin,
      CASE WHEN ((SELECT food_drink_rev FROM revenue) + (SELECT rooms_rev FROM rooms_rev)) > 0
        THEN ROUND(100.0 * (((SELECT food_drink_rev FROM revenue) + (SELECT rooms_rev FROM rooms_rev)) - (SELECT supplier_spend FROM cogs))
             / ((SELECT food_drink_rev FROM revenue) + (SELECT rooms_rev FROM rooms_rev)), 1)
      END AS gross_margin_pct',
  '{}', 'shared', true, NOW(), 'u174', 'u174'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

COMMIT;
