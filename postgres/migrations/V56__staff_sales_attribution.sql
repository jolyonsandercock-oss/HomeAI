-- ============================================================
-- U47b — Per-staff sales attribution + cost-aware shift view
-- ============================================================
-- TouchOffice department_sales is daily-level; we apportion each day's
-- (site,department) value by each staff member's share of total hours
-- in the mapped Tanda team for that day. Output:
--   - shift_cost = hours × hourly_rate × (1 + on_cost_pct/100)
--   - attributable_sales = SUM(daily_dept_sales × this_staff_hours / total_dept_hours)
--   - sales_per_hour = attributable_sales / hours_worked
-- FoH gets BOTH alcohol and food (with `shared_attribution=true`),
-- because they handle drinks and run food — the consumer of this view
-- should flag the badge in the UI.
-- ============================================================

-- Tanda team → TouchOffice (site, department) mapping table.
-- Promoting hard-coded business rules to a maintainable lookup.
CREATE TABLE IF NOT EXISTS workforce_to_sales_map (
  team           TEXT NOT NULL,                  -- workforce_departments.team
  site           TEXT NOT NULL,                  -- 'malthouse' | 'sandwich'
  department     TEXT NOT NULL,                  -- touchoffice department label
  share          NUMERIC(4,3) NOT NULL DEFAULT 1.0,
                                                  -- e.g. FoH might get 0.5 of food (kitchen gets the other 0.5)
  shared_attribution BOOLEAN NOT NULL DEFAULT false,
  PRIMARY KEY (team, site, department)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON workforce_to_sales_map
  TO homeai_pipeline;
GRANT SELECT ON workforce_to_sales_map TO homeai_readonly;

-- Seed mapping (matches Jo's spec: Tom kitchen→food, Ben FoH→drink+food, Tanya cafe→cafe)
INSERT INTO workforce_to_sales_map (team, site, department, share, shared_attribution) VALUES
  ('kitchen',        'malthouse', 'FOOD SALES',       1.000, false),
  ('front_of_house', 'malthouse', 'ALCOHOL SALES',    1.000, false),
  ('front_of_house', 'malthouse', 'HOT DRINKS',       1.000, false),
  ('front_of_house', 'malthouse', 'FOOD SALES',       0.500, true),   -- FoH shares food with kitchen
  ('cafe',           'sandwich',  'Cafe Ice Cream',   1.000, false),
  ('cafe',           'sandwich',  'Cafe Soft Drinks', 1.000, false),
  ('cafe',           'sandwich',  'SNACK',            1.000, false),
  ('cafe',           'sandwich',  'DEPT 16',          1.000, false),
  ('cafe',           'sandwich',  'DEPART 8',         1.000, false),
  ('cafe',           'sandwich',  'ALCOHOL SALES',    1.000, false),
  ('accommodation',  'malthouse', 'ACCOM',            1.000, false)
ON CONFLICT (team, site, department) DO UPDATE SET
  share = EXCLUDED.share,
  shared_attribution = EXCLUDED.shared_attribution;

-- Per-shift cost view (derives the £ from staff_meta when cost_estimate is NULL)
CREATE OR REPLACE VIEW v_workforce_shifts_costed AS
SELECT
  s.id,
  s.shift_date,
  s.user_external_id,
  u.full_name,
  u.preferred_name,
  s.department_external_id,
  d.team               AS team,
  s.location_external_id,
  s.start_time, s.end_time, s.hours_worked,
  COALESCE(
    s.cost_estimate,
    ROUND(
      (s.hours_worked::numeric *
       COALESCE(sm.hourly_rate_pence, u.base_pay_rate::int * 100, 0) / 100.0 *
       (1 + COALESCE(sm.on_cost_pct, 12.5) / 100.0))::numeric, 2
    )
  ) AS shift_cost,
  CASE
    WHEN s.cost_estimate IS NOT NULL                                 THEN 'tanda'
    WHEN sm.hourly_rate_pence IS NOT NULL                            THEN 'staff_meta'
    WHEN u.base_pay_rate IS NOT NULL                                 THEN 'workforce_users'
    ELSE 'unknown'
  END AS cost_source
FROM workforce_shifts s
LEFT JOIN workforce_users       u  ON u.external_id = s.user_external_id
LEFT JOIN staff_meta            sm ON sm.user_external_id = s.user_external_id
LEFT JOIN workforce_departments d  ON d.external_id = s.department_external_id;

GRANT SELECT ON v_workforce_shifts_costed
  TO homeai_pipeline, homeai_readonly, metabase_app;

-- Function: sales-per-staff for a date range
CREATE OR REPLACE FUNCTION staff_sales_window(d_from DATE, d_to DATE)
RETURNS TABLE (
  user_external_id   BIGINT,
  full_name          TEXT,
  team               TEXT,
  shifts             INT,
  hours              NUMERIC,
  shift_cost         NUMERIC,
  attributable_sales NUMERIC,
  sales_per_hour     NUMERIC,
  has_shared_attribution BOOLEAN
)
LANGUAGE sql STABLE AS $$
WITH shifts AS (
  SELECT
    s.user_external_id,
    s.full_name,
    s.team,
    s.shift_date,
    s.hours_worked,
    s.shift_cost
  FROM v_workforce_shifts_costed s
  WHERE s.shift_date BETWEEN d_from AND d_to
    AND s.team IS NOT NULL
    AND s.team NOT IN ('unassigned')
    AND s.hours_worked > 0
),
day_team_hours AS (
  SELECT shift_date, team, SUM(hours_worked) AS team_hours_day
  FROM shifts GROUP BY 1,2
),
day_dept_sales AS (
  SELECT
    ds.report_date AS shift_date,
    m.team,
    SUM(ds.value * m.share) AS dept_value_day,
    bool_or(m.shared_attribution) AS shared
  FROM touchoffice_department_sales ds
  JOIN workforce_to_sales_map m
    ON m.site = ds.site AND m.department = ds.department
  WHERE ds.report_date BETWEEN d_from AND d_to
  GROUP BY 1,2
),
per_staff_day AS (
  SELECT
    s.user_external_id,
    s.full_name,
    s.team,
    s.shift_date,
    s.hours_worked,
    s.shift_cost,
    COALESCE(
      ds.dept_value_day * s.hours_worked / NULLIF(dth.team_hours_day, 0),
      0
    ) AS attributable,
    COALESCE(ds.shared, false) AS shared
  FROM shifts s
  LEFT JOIN day_team_hours dth ON dth.shift_date = s.shift_date AND dth.team = s.team
  LEFT JOIN day_dept_sales ds  ON ds.shift_date  = s.shift_date AND ds.team  = s.team
)
SELECT
  user_external_id,
  full_name,
  team,
  COUNT(*)::int                                                     AS shifts,
  ROUND(SUM(hours_worked)::numeric, 2)                              AS hours,
  ROUND(SUM(shift_cost)::numeric, 2)                                AS shift_cost,
  ROUND(SUM(attributable)::numeric, 2)                              AS attributable_sales,
  CASE WHEN SUM(hours_worked) > 0
       THEN ROUND((SUM(attributable) / SUM(hours_worked))::numeric, 2)
       ELSE NULL END                                                AS sales_per_hour,
  bool_or(shared)                                                   AS has_shared_attribution
FROM per_staff_day
GROUP BY user_external_id, full_name, team
HAVING SUM(hours_worked) > 0
ORDER BY sales_per_hour DESC NULLS LAST;
$$;

COMMENT ON FUNCTION staff_sales_window(date, date) IS
  'U47b — per-staff attributable sales over a window. Sales apportioned by each staff member share of their team daily hours. FoH gets a shared-attribution flag.';

GRANT EXECUTE ON FUNCTION staff_sales_window(date, date)
  TO homeai_readonly, homeai_pipeline;
