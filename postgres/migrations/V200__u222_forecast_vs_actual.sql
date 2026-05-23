-- U222: workforce planned-vs-actual visibility
--
-- Closes the loop that U47b flagged stale-in-memory: Tanda timesheets sync
-- has been running daily (cron `20 2 * * *` u47-tanda-timesheets-sync.sh)
-- since U47 era, but no view ever compared the resulting rows against
-- workforce_shifts (the rota). 48 timesheet rows accumulated covering
-- 2026-03-26 → 2026-05-25 without being surfaced anywhere.
--
-- This view joins each timesheet to the rota for the same user + period
-- and surfaces the deltas. Negative hours_delta = worked fewer hours than
-- rostered; positive cost_delta = labour overspend vs plan.
--
-- One row per (user, pay period). Empty for users with shifts but no
-- timesheet yet — that's the "not yet finalised" state.

CREATE OR REPLACE VIEW v_workforce_forecast_vs_actual AS
SELECT
    t.id                              AS timesheet_id,
    t.entity_id,
    t.realm,
    t.user_external_id,
    COALESCE(u.preferred_name, u.full_name) AS user_name,
    t.period_start,
    t.period_end,
    -- Actual (from Tanda timesheets)
    t.hours_total                     AS actual_hours,
    t.cost_total                      AS actual_cost,
    -- Planned (aggregated from rota for the same period + user)
    COALESCE(s.planned_hours, 0)      AS planned_hours,
    COALESCE(s.planned_cost, 0)       AS planned_cost,
    -- Deltas (actual − planned). Negative cost_delta = saved labour;
    -- positive = overspend.
    t.hours_total - COALESCE(s.planned_hours, 0) AS hours_delta,
    t.cost_total  - COALESCE(s.planned_cost, 0)  AS cost_delta,
    -- Percentage cost variance, NULL when planned was zero
    CASE
        WHEN COALESCE(s.planned_cost, 0) = 0 THEN NULL
        ELSE ROUND(100.0 * (t.cost_total - s.planned_cost) / s.planned_cost, 1)
    END                               AS cost_delta_pct,
    t.status                          AS timesheet_status,
    COALESCE(s.shift_count, 0)        AS shift_count,
    t.last_synced_at                  AS timesheet_synced_at
  FROM workforce_timesheets t
  LEFT JOIN workforce_users u
    ON u.external_id = t.user_external_id
  LEFT JOIN LATERAL (
      SELECT
          SUM(hours_worked)                     AS planned_hours,
          SUM(COALESCE(cost_estimate, 0))       AS planned_cost,
          COUNT(*)                              AS shift_count
        FROM workforce_shifts ws
       WHERE ws.user_external_id = t.user_external_id
         AND ws.shift_date BETWEEN t.period_start AND t.period_end
         AND ws.entity_id = t.entity_id
  ) s ON true;

COMMENT ON VIEW v_workforce_forecast_vs_actual IS
'U222: per-user pay-period comparison of Tanda timesheets (actual) vs '
'workforce_shifts rota (planned). One row per finalised timesheet.';
