-- =============================================================================
-- V173 — U143: extend v_quota_status with 7d spend columns.
-- =============================================================================
-- v_quota_status today-only made the tile look broken on quiet days. Add
-- spent_gbp_7d + call_count_7d so callers see the steady-state pattern.
-- =============================================================================

BEGIN;

CREATE OR REPLACE VIEW v_ai_spend_7d AS
SELECT business_priority,
       COALESCE(SUM(cost_gbp), 0)::numeric(10,4) AS spent_gbp,
       COUNT(*) AS call_count
  FROM ai_usage
 WHERE "timestamp" >= NOW() - INTERVAL '7 days'
 GROUP BY business_priority;

DROP VIEW IF EXISTS v_quota_status;
CREATE VIEW v_quota_status AS
SELECT qa.business_priority AS tier,
       qa.daily_cost_ceiling_gbp AS ceiling_gbp,
       COALESCE(s_today.spent_gbp, 0)::numeric(10,4) AS spent_gbp,
       qa.enforce_mode,
       (COALESCE(s_today.spent_gbp, 0) >= qa.daily_cost_ceiling_gbp) AS at_ceiling,
       COALESCE(s_today.call_count, 0) AS call_count_today,
       COALESCE(s_today.shadow_blocked_count, 0) AS shadow_blocked_today,
       (qa.daily_cost_ceiling_gbp - COALESCE(s_today.spent_gbp, 0))::numeric(10,4) AS remaining_gbp,
       COALESCE(s_7d.spent_gbp, 0)::numeric(10,4) AS spent_gbp_7d,
       COALESCE(s_7d.call_count, 0) AS call_count_7d
  FROM quota_allocations qa
  LEFT JOIN v_ai_spend_today s_today ON s_today.business_priority = qa.business_priority
  LEFT JOIN v_ai_spend_7d    s_7d    ON s_7d.business_priority    = qa.business_priority
 ORDER BY qa.business_priority;

GRANT SELECT ON v_ai_spend_7d, v_quota_status TO homeai_readonly;

COMMIT;
