-- =============================================================================
-- V70 — v_ai_calls_by_realm view (U55 R6)
-- =============================================================================
-- Aggregates ai_usage by realm + task_type + tier for the last 30 days.
-- Lets us see at a glance "Sonnet calls per realm per day" and catch any AI
-- worker that's silently writing rows under the wrong realm (which would
-- indicate the script forgot to call SET app.current_realm).
--
-- Useful diagnostic queries against this view:
--   SELECT realm, task_type, calls_24h FROM v_ai_calls_by_realm WHERE day=now()::date;
--   SELECT realm, SUM(cost_gbp_30d) FROM v_ai_calls_by_realm GROUP BY realm;
-- =============================================================================

BEGIN;

CREATE OR REPLACE VIEW v_ai_calls_by_realm AS
SELECT
    DATE_TRUNC('day', timestamp)::date     AS day,
    realm,
    task_type,
    model_used,
    tier,
    COUNT(*)                                AS calls,
    SUM(prompt_tokens)                      AS prompt_tokens,
    SUM(completion_tokens)                  AS completion_tokens,
    ROUND(
        SUM(
            CASE
                WHEN model_used LIKE '%opus%'   THEN (prompt_tokens * 15.0  + completion_tokens * 75.0)  / 1000000.0
                WHEN model_used LIKE '%sonnet%' THEN (prompt_tokens *  3.0  + completion_tokens * 15.0)  / 1000000.0
                WHEN model_used LIKE '%haiku%'  THEN (prompt_tokens *  0.25 + completion_tokens *  1.25) / 1000000.0
                ELSE 0
            END * 0.79  -- USD→GBP approximation, U46 convention
        )::numeric, 4
    ) AS cost_gbp
  FROM ai_usage
 WHERE timestamp > now() - INTERVAL '30 days'
 GROUP BY 1, 2, 3, 4, 5
 ORDER BY 1 DESC, 2, 3;

COMMENT ON VIEW v_ai_calls_by_realm IS
    'U55 R6: AI usage rolled up by (day, realm, task, model). If a task '
    'shows up under realm=owner that should be realm=work (e.g. invoice '
    'extraction tagged owner), the worker is missing SET app.current_realm.';

-- -----------------------------------------------------------------------------
-- Probe: how many rows currently in ai_usage that look like worker output
-- with an unexpected realm? (Today: every row will be owner because the
-- worker scripts only just got patched.)
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    by_realm TEXT;
BEGIN
    SELECT string_agg(realm || '=' || n::text, ', ' ORDER BY realm)
      INTO by_realm
      FROM (
          SELECT realm, COUNT(*) AS n
            FROM ai_usage
           WHERE timestamp > now() - INTERVAL '7 days'
           GROUP BY realm
      ) t;
    RAISE NOTICE 'V70 ai_usage realm distribution (last 7d): %', COALESCE(by_realm, '(no rows)');
END $$;

COMMIT;
