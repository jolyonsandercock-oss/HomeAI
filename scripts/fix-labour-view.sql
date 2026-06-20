-- fix-labour-view.sql — Phase 3.2. v_daily_labour_by_team was recomputing labour as
-- staff_meta.hourly_rate * hours * (1 + 12.5%) — the OLD fallback basis. The canonical
-- basis is workforce_shifts.cost_estimate = award_cost * 1.2692 (Tanda-anchored to Jo's
-- May report £44,447). Prefer cost_estimate; fall back to the staff_meta computation only
-- where cost_estimate is NULL. Columns/grouping unchanged (build-dashboard + u109 safe).
CREATE OR REPLACE VIEW v_daily_labour_by_team AS
SELECT s.shift_date AS report_date,
   COALESCE(d.team, 'unassigned'::text) AS team,
   COALESCE(d.name, 'dept_'::text || s.department_external_id::text) AS department_name,
   s.department_external_id,
   sum(s.hours_worked)::numeric(10,2) AS hours,
   sum(COALESCE(s.cost_estimate,
       s.hours_worked * (m.hourly_rate_pence::numeric / 100.0) * (1::numeric + COALESCE(m.on_cost_pct, 12.5) / 100.0)
   ))::numeric(12,2) AS cost_with_oncost,
   count(DISTINCT s.user_external_id) AS staff_count,
   round(sum(COALESCE(s.cost_estimate,
       s.hours_worked * (m.hourly_rate_pence::numeric / 100.0) * (1::numeric + COALESCE(m.on_cost_pct, 12.5) / 100.0)
   )) / NULLIF(sum(s.hours_worked), 0::numeric), 2) AS avg_cost_per_hr
  FROM workforce_shifts s
    LEFT JOIN staff_meta m ON m.user_external_id = s.user_external_id
    LEFT JOIN workforce_departments d ON d.external_id = s.department_external_id
 WHERE s.hours_worked IS NOT NULL AND s.hours_worked > 0::numeric
 GROUP BY s.shift_date, d.team, d.name, s.department_external_id;
