-- V203 / U225 T6 — /app/cafe page: populate the Ice Cream / Soft Drinks /
-- till tiles that were placeholder ("live tomorrow"). Data lives in
-- touchoffice_department_sales for site='sandwich'; we just need slugs.

-- 1. Today's department breakdown for cafe — Ice Cream, Soft Drinks, Hot Drinks
--    and totals. Falls back to the most recent date that has cafe data if
--    today hasn't scraped yet (mirrors V141's frontend_today_gross fallback).
INSERT INTO query_whitelist (slug, display_name, description, sql_template, active, realm, created_by, approved_at, approved_by)
VALUES (
  'cafe_today_depts',
  'Cafe — today department £ values',
  'U225 T6: per-department £ value for site=sandwich on the most recent scraped date (today or last day with data).',
  $T$WITH latest AS (
    SELECT MAX(report_date) d
      FROM touchoffice_department_sales
     WHERE site = 'sandwich'
  )
  SELECT department,
         report_date,
         COALESCE(value, 0)::numeric(10,2)    AS value,
         COALESCE(quantity, 0)::numeric(10,2) AS quantity
    FROM touchoffice_department_sales, latest
   WHERE site = 'sandwich'
     AND report_date = latest.d
   ORDER BY value DESC NULLS LAST$T$,
  true, 'shared', 'U225', NOW(), 'U225'
)
ON CONFLICT (slug) DO UPDATE
  SET sql_template = EXCLUDED.sql_template,
      description  = EXCLUDED.description,
      display_name = EXCLUDED.display_name,
      approved_at  = EXCLUDED.approved_at,
      realm        = EXCLUDED.realm;

-- 2. 7d £ sparkline per cafe department — matches the shape of
--    bar_till_groups_spark_7d so the same UI components can reuse it.
INSERT INTO query_whitelist (slug, display_name, description, sql_template, active, realm, created_by, approved_at, approved_by)
VALUES (
  'cafe_dept_spark_7d',
  'Cafe — 7d £ sparkline per department',
  'U225 T6: per-department 7-day daily £ array for cafe (site=sandwich) sparklines.',
  $T$WITH days AS (
    SELECT generate_series(CURRENT_DATE - 7, CURRENT_DATE - 1, '1 day'::interval)::date AS d
  ),
  daily AS (
    SELECT s.department,
           d.d,
           COALESCE(SUM(s.value), 0)::numeric(12,2) AS val
      FROM days d
      LEFT JOIN touchoffice_department_sales s
        ON s.report_date = d.d
       AND s.site = 'sandwich'
     GROUP BY s.department, d.d
  )
  SELECT department,
         array_agg(val ORDER BY d) AS values,
         SUM(val)::numeric(12,2)   AS total_value
    FROM daily
   WHERE department IS NOT NULL
   GROUP BY department
   ORDER BY total_value DESC$T$,
  true, 'shared', 'U225', NOW(), 'U225'
)
ON CONFLICT (slug) DO UPDATE
  SET sql_template = EXCLUDED.sql_template,
      description  = EXCLUDED.description,
      display_name = EXCLUDED.display_name,
      approved_at  = EXCLUDED.approved_at,
      realm        = EXCLUDED.realm;
