-- V60: Per-site labour cost allocation
--
-- workforce_departments has a `team` column already (sourced='unmapped').
-- Add `site` to mirror vendor_category_rules.site so per-site labour cost
-- can be derived. v_daily_unit_economics rewritten to split labour_cost
-- into pub / cafe / inn / shared columns based on department.site.
--
-- Mapping (set explicitly, since only 4 departments exist):
--   Kitchen        → pub   (pub kitchen serves bar + restaurant)
--   Front of house → pub   (bar + restaurant FOH)
--   Housekeeping   → inn   (accommodation only)
--   Cafe           → cafe  (sandwich bar / ice cream shop)
--
-- Unmapped departments default to 'shared' so they never silently zero out
-- the labour total.

BEGIN;

ALTER TABLE workforce_departments
  ADD COLUMN IF NOT EXISTS site TEXT NOT NULL DEFAULT 'shared'
    CHECK (site IN ('shared', 'cafe', 'pub', 'inn'));

UPDATE workforce_departments SET site='pub'  WHERE lower(name) IN ('kitchen', 'front of house');
UPDATE workforce_departments SET site='inn'  WHERE lower(name) = 'housekeeping';
UPDATE workforce_departments SET site='cafe' WHERE lower(name) = 'cafe';

DROP VIEW IF EXISTS v_daily_unit_economics CASCADE;

CREATE VIEW v_daily_unit_economics AS
WITH to_pub AS (
  SELECT x.d AS report_date,
    (SELECT f.value FROM touchoffice_fixed_totals f
       WHERE f.site='malthouse' AND f.report_date=x.d AND f.label='NET sales')   AS net_sales,
    (SELECT f.value FROM touchoffice_fixed_totals f
       WHERE f.site='malthouse' AND f.report_date=x.d AND f.label='GROSS Sales') AS gross_sales,
    (SELECT f.quantity FROM touchoffice_fixed_totals f
       WHERE f.site='malthouse' AND f.report_date=x.d AND f.label='Covers')      AS covers
  FROM (SELECT DISTINCT report_date AS d FROM touchoffice_fixed_totals) x
),
to_sand AS (
  SELECT x.d AS report_date,
    (SELECT f.value FROM touchoffice_fixed_totals f
       WHERE f.site='sandwich' AND f.report_date=x.d AND f.label='NET sales')   AS net_sales,
    (SELECT f.value FROM touchoffice_fixed_totals f
       WHERE f.site='sandwich' AND f.report_date=x.d AND f.label='GROSS Sales') AS gross_sales,
    (SELECT f.quantity FROM touchoffice_fixed_totals f
       WHERE f.site='sandwich' AND f.report_date=x.d AND f.label='Covers')      AS covers
  FROM (SELECT DISTINCT report_date AS d FROM touchoffice_fixed_totals
         WHERE site='sandwich') x
),
cb AS (
  SELECT a.report_date, a.accom_revenue, s_1.in_house_count,
         a.rooms_occupied AS accom_rooms_occupied
    FROM v_daily_accom_revenue a
    LEFT JOIN caterbook_daily_snapshots s_1 ON s_1.report_date=a.report_date
),
wf AS (
  SELECT s_1.shift_date AS report_date,
         (sum(s_1.hours_worked))::numeric(10,2) AS labour_hours,
         (sum((s_1.hours_worked * ((m.hourly_rate_pence)::numeric / 100.0)
               * ((1)::numeric + (COALESCE(m.on_cost_pct, 12.5) / 100.0))
              )))::numeric(12,2) AS labour_cost_est,
         count(DISTINCT s_1.user_external_id) AS staff_on_shift
    FROM workforce_shifts s_1
    LEFT JOIN staff_meta m ON m.user_external_id = s_1.user_external_id
   WHERE s_1.hours_worked IS NOT NULL AND s_1.hours_worked > 0
   GROUP BY s_1.shift_date
),
wf_site AS (
  SELECT s_1.shift_date AS report_date,
         COALESCE(d.site, 'shared') AS site,
         (sum(s_1.hours_worked))::numeric(10,2) AS hours,
         (sum((s_1.hours_worked * ((m.hourly_rate_pence)::numeric / 100.0)
               * ((1)::numeric + (COALESCE(m.on_cost_pct, 12.5) / 100.0))
              )))::numeric(12,2) AS cost
    FROM workforce_shifts s_1
    LEFT JOIN staff_meta m ON m.user_external_id = s_1.user_external_id
    LEFT JOIN workforce_departments d ON d.external_id = s_1.department_external_id
   WHERE s_1.hours_worked IS NOT NULL AND s_1.hours_worked > 0
   GROUP BY s_1.shift_date, COALESCE(d.site, 'shared')
),
wf_pivot AS (
  SELECT report_date,
    SUM(cost)   FILTER (WHERE site='pub')    AS labour_cost_pub,
    SUM(cost)   FILTER (WHERE site='cafe')   AS labour_cost_cafe,
    SUM(cost)   FILTER (WHERE site='inn')    AS labour_cost_inn,
    SUM(cost)   FILTER (WHERE site='shared') AS labour_cost_shared,
    SUM(hours)  FILTER (WHERE site='pub')    AS labour_hours_pub,
    SUM(hours)  FILTER (WHERE site='cafe')   AS labour_hours_cafe,
    SUM(hours)  FILTER (WHERE site='inn')    AS labour_hours_inn,
    SUM(hours)  FILTER (WHERE site='shared') AS labour_hours_shared
  FROM wf_site GROUP BY report_date
),
all_dates AS (
  SELECT report_date FROM to_pub
  UNION SELECT report_date FROM to_sand
  UNION SELECT report_date FROM cb
  UNION SELECT report_date FROM wf
)
SELECT
  d.report_date,
  p.net_sales      AS pub_net_sales,
  p.gross_sales    AS pub_gross_sales,
  p.covers         AS pub_covers,
  s.net_sales      AS sandwich_net_sales,
  s.gross_sales    AS sandwich_gross_sales,
  s.covers         AS sandwich_covers,
  (COALESCE(p.net_sales,0) + COALESCE(s.net_sales,0))     AS total_net_sales,
  (COALESCE(p.gross_sales,0) + COALESCE(s.gross_sales,0)) AS total_gross_sales,
  (COALESCE(p.covers,0) + COALESCE(s.covers,0))           AS total_covers,
  cb.accom_revenue,
  cb.accom_rooms_occupied,
  cb.in_house_count,
  (COALESCE(p.net_sales,0) + COALESCE(s.net_sales,0) + COALESCE(cb.accom_revenue,0))::numeric(12,2)
                                                          AS total_revenue,
  wf.labour_hours,
  wf.labour_cost_est,
  wf.staff_on_shift,
  CASE WHEN COALESCE(p.net_sales,0)+COALESCE(s.net_sales,0) > 0
       THEN ROUND((wf.labour_cost_est /
            (COALESCE(p.net_sales,0)+COALESCE(s.net_sales,0))) * 100, 1)
       ELSE NULL END                                       AS labour_pct,
  CASE WHEN wf.labour_hours > 0
       THEN ROUND((COALESCE(p.net_sales,0)+COALESCE(s.net_sales,0)) / wf.labour_hours, 2)
       ELSE NULL END                                       AS splh,
  wp.labour_cost_pub,
  wp.labour_cost_cafe,
  wp.labour_cost_inn,
  wp.labour_cost_shared,
  wp.labour_hours_pub,
  wp.labour_hours_cafe,
  wp.labour_hours_inn,
  wp.labour_hours_shared,
  CASE WHEN COALESCE(p.net_sales,0) > 0 AND wp.labour_cost_pub IS NOT NULL
       THEN ROUND((wp.labour_cost_pub / p.net_sales) * 100, 1)
       ELSE NULL END                                       AS pub_labour_pct,
  CASE WHEN COALESCE(s.net_sales,0) > 0 AND wp.labour_cost_cafe IS NOT NULL
       THEN ROUND((wp.labour_cost_cafe / s.net_sales) * 100, 1)
       ELSE NULL END                                       AS cafe_labour_pct
FROM all_dates d
LEFT JOIN to_pub  p  ON p.report_date  = d.report_date
LEFT JOIN to_sand s  ON s.report_date  = d.report_date
LEFT JOIN cb         ON cb.report_date = d.report_date
LEFT JOIN wf         ON wf.report_date = d.report_date
LEFT JOIN wf_pivot wp ON wp.report_date = d.report_date;

COMMIT;
