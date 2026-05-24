-- V201 / U225 T5 — /app/bar page updates per Jo:
--   1. bar_till_groups_spark_7d: switch from `quantity` to `£ value` so the
--      tiles show what the bar actually earned, not how many drinks went over
--      the bar.
--   2. bar_wage_summary: add purchase_total per period (vendor_invoice_inbox
--      rows with vendor_category='Beverage' over the same window) so each
--      period box can show wage + sales + purchases + labour% together.

-- 1. Switch the per-drink-group 7d sparkline to £ values.
INSERT INTO query_whitelist (slug, display_name, description, sql_template, active, realm, created_by, approved_at, approved_by)
VALUES (
  'bar_till_groups_spark_7d',
  'Bar till — drink group 7d value spark',
  'U210→U225: per-drink-group 7-day daily £ value array, for sparkline per group. Switched from quantity to value 2026-05-24.',
  $T$WITH classified AS (
    SELECT report_date,
           CASE
             WHEN descriptor ~* '(korev|rattler|ale|guinness|cruzcampo|harbour|gold ale|lager|cider|tintagel gold|cornwalls pride|harbour single|harbour arctic|heineken)' THEN 'beer'
             WHEN descriptor ~* '(pinot|sauvignon|rose|chardonnay|merlot|wine|prestige|coastal spring)' THEN 'wine'
             WHEN descriptor ~* '(cocktail|aperol|negroni|spritz|tarquin|tequila)' THEN 'cocktail'
             WHEN descriptor ~* '(gin|vodka|whisky|jameson|smirnoff|kraken|rum|with ice|dash)' THEN 'spirit'
             WHEN descriptor ~* '(coffee|tea|cappuccino|americano|latte|espresso|mocha|chai|breakfast tea)' THEN 'hot_drink'
             WHEN descriptor ~* '(pepsi|coca|lemonade|soda|water|shandy|cordial|fever-tree|ginger beer|apple juice|orange juice|tonic|all together|blackcurrant|lime|sugar.free)' THEN 'soft_drink'
             ELSE NULL
           END AS grp,
           value
      FROM touchoffice_plu_sales
     WHERE site = 'malthouse'
       AND report_date BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE - 1
  ),
  days AS (
    SELECT generate_series(CURRENT_DATE - 7, CURRENT_DATE - 1, '1 day'::interval)::date AS d
  ),
  daily AS (
    SELECT grp, d.d, COALESCE(SUM(value), 0)::numeric(12,2) AS val
      FROM days d
      LEFT JOIN classified c ON c.report_date = d.d
     WHERE grp IS NOT NULL
     GROUP BY grp, d.d
  )
  SELECT grp,
         array_agg(val ORDER BY d) AS values,
         SUM(val)::numeric(12,2) AS total_value
    FROM daily
   GROUP BY grp
   ORDER BY total_value DESC$T$,
  true, 'shared', 'U225', NOW(), 'U225'
)
ON CONFLICT (slug) DO UPDATE
  SET sql_template = EXCLUDED.sql_template,
      description  = EXCLUDED.description,
      display_name = EXCLUDED.display_name,
      approved_at  = EXCLUDED.approved_at,
      realm        = EXCLUDED.realm;


-- 2. bar_wage_summary now also returns purchase_total per window — vendor
--    invoices in the Beverage category settled in the period.
INSERT INTO query_whitelist (slug, display_name, description, sql_template, active, realm, created_by, approved_at, approved_by)
VALUES (
  'bar_wage_summary',
  'Bar wage % + purchases — FOH only, 1/7/30d',
  'U210→U225: bar staff = FOH team. Adds purchase_total (Beverage vendor invoices). Updated 2026-05-24.',
  $T$WITH params AS (SELECT 1 d UNION ALL SELECT 7 UNION ALL SELECT 30),
       labour AS (
         SELECT p.d, SUM(cost_with_oncost) c
           FROM params p
           JOIN v_daily_labour_by_team l
             ON l.report_date BETWEEN CURRENT_DATE - p.d AND CURRENT_DATE - 1
            AND l.team = 'front_of_house'
          GROUP BY p.d
       ),
       sales AS (
         SELECT p.d, SUM(value) s
           FROM params p
           JOIN touchoffice_department_sales s
             ON s.report_date BETWEEN CURRENT_DATE - p.d AND CURRENT_DATE - 1
            AND s.site = 'malthouse'
          GROUP BY p.d
       ),
       purchases AS (
         SELECT p.d,
                COALESCE(SUM(net_amount), 0)::numeric(12,2) AS pur
           FROM params p
           LEFT JOIN vendor_invoice_inbox v
             ON v.invoice_date BETWEEN CURRENT_DATE - p.d AND CURRENT_DATE - 1
            AND v.vendor_category = 'Beverage'
            AND v.status NOT IN ('ignored', 'duplicate', 'disputed')
          GROUP BY p.d
       )
  SELECT p.d AS days,
         labour.c           AS labour,
         sales.s            AS sales,
         purchases.pur      AS purchases,
         ROUND((labour.c / NULLIF(sales.s,0) * 100)::numeric, 1) AS pct
    FROM params p
    LEFT JOIN labour    USING (d)
    LEFT JOIN sales     USING (d)
    LEFT JOIN purchases USING (d)
   ORDER BY p.d$T$,
  true, 'shared', 'U225', NOW(), 'U225'
)
ON CONFLICT (slug) DO UPDATE
  SET sql_template = EXCLUDED.sql_template,
      description  = EXCLUDED.description,
      display_name = EXCLUDED.display_name,
      approved_at  = EXCLUDED.approved_at,
      realm        = EXCLUDED.realm;
