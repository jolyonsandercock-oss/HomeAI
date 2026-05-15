-- =============================================================================
-- V102 — U84 Phase 5: Build hub views
-- =============================================================================
-- Powers the /build/* screens (Pipelines, Models, Forensics).
-- Owner-only via Authelia + realm check; no realm filter needed here.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- ── v_build_model_spend_30d ────────────────────────────────────────────────
-- Per-model token counts + crude cost estimate over last 30 days. Cost rates
-- are the 2025 published rates per million tokens (approx).
DROP VIEW IF EXISTS v_build_model_spend_30d CASCADE;
CREATE VIEW v_build_model_spend_30d AS
WITH rates AS (
  -- per-1M-tokens GBP-ish (rough; USD * 0.80 approximation)
  SELECT 'claude-opus-4-7'::text          AS model_used, 12.00 AS in_per_m, 60.00 AS out_per_m UNION ALL
  SELECT 'claude-opus-4-6',                              12.00,             60.00 UNION ALL
  SELECT 'claude-sonnet-4-6',                             2.40,             12.00 UNION ALL
  SELECT 'claude-haiku-4-5-20251001',                     0.64,              3.20 UNION ALL
  SELECT 'claude-haiku-4-5',                              0.64,              3.20 UNION ALL
  SELECT 'qwen2.5:7b',                                    0.00,              0.00 UNION ALL
  SELECT 'qwen3:8b',                                      0.00,              0.00 UNION ALL
  SELECT 'phi4',                                          0.00,              0.00
)
SELECT
  u.model_used,
  COALESCE(u.tier, '—')                                   AS tier,
  COUNT(*)                                                 AS calls,
  SUM(u.prompt_tokens)                                     AS prompt_tokens,
  SUM(u.completion_tokens)                                 AS completion_tokens,
  ROUND(
    (SUM(u.prompt_tokens)::numeric     * COALESCE(r.in_per_m, 0)  / 1e6) +
    (SUM(u.completion_tokens)::numeric * COALESCE(r.out_per_m, 0) / 1e6),
    2
  )                                                        AS est_cost_gbp,
  AVG(u.latency_ms)::int                                   AS avg_latency_ms,
  MAX(u.timestamp)                                         AS last_call_at
FROM ai_usage u
LEFT JOIN rates r ON r.model_used = u.model_used
WHERE u.timestamp > now() - INTERVAL '30 days'
GROUP BY u.model_used, COALESCE(u.tier, '—'), r.in_per_m, r.out_per_m
ORDER BY calls DESC;

COMMENT ON VIEW v_build_model_spend_30d IS
'U84 /build/models — per-model tokens + cost over last 30 days (V102).';

-- ── v_build_pipeline_status ────────────────────────────────────────────────
-- Simple service health rollup: last successful ai_usage timestamp per
-- realm + per provider gives a rough liveness signal.
DROP VIEW IF EXISTS v_build_pipeline_status CASCADE;
CREATE VIEW v_build_pipeline_status AS
WITH last_calls AS (
  SELECT
    COALESCE(provider, 'unknown')         AS provider,
    MAX(timestamp)                        AS last_call_at,
    COUNT(*) FILTER (WHERE timestamp > now() - INTERVAL '24 hours') AS calls_24h,
    COUNT(*) FILTER (WHERE timestamp > now() - INTERVAL '1 hour')    AS calls_1h
  FROM ai_usage
  WHERE timestamp > now() - INTERVAL '7 days'
  GROUP BY COALESCE(provider, 'unknown')
)
SELECT
  provider,
  last_call_at,
  calls_24h,
  calls_1h,
  CASE
    WHEN last_call_at IS NULL                              THEN 'idle'
    WHEN last_call_at > now() - INTERVAL '15 minutes'      THEN 'live'
    WHEN last_call_at > now() - INTERVAL '6 hours'         THEN 'recent'
    WHEN last_call_at > now() - INTERVAL '24 hours'        THEN 'stale'
    ELSE                                                        'cold'
  END                                                      AS status
FROM last_calls
ORDER BY last_call_at DESC NULLS LAST;

COMMENT ON VIEW v_build_pipeline_status IS
'U84 /build/pipelines — AI pipeline activity by provider over 7 days (V102).';

-- ── v_build_forensic_summary ───────────────────────────────────────────────
-- Summary metrics for the /build/forensics page.
DROP VIEW IF EXISTS v_build_forensic_summary CASCADE;
CREATE VIEW v_build_forensic_summary AS
SELECT
  (SELECT COUNT(*) FROM mart.exceptions
     WHERE status = 'open' AND severity = 'critical')              AS critical_open,
  (SELECT COUNT(*) FROM mart.exceptions
     WHERE status = 'open' AND severity = 'high')                  AS high_open,
  (SELECT COUNT(*) FROM mart.exceptions
     WHERE status = 'open' AND severity = 'medium')                AS medium_open,
  (SELECT COUNT(*) FROM mart.exceptions
     WHERE status = 'open' AND severity = 'low')                   AS low_open,
  (SELECT COUNT(*) FROM mart.exceptions
     WHERE raised_at > now() - INTERVAL '24 hours')                AS raised_24h,
  (SELECT COUNT(*) FROM mart.exceptions
     WHERE resolved_at > now() - INTERVAL '24 hours')              AS resolved_24h,
  (SELECT COUNT(*) FROM v_kpi_anomalies WHERE flagged = true)      AS anomalies_flagged,
  (SELECT COUNT(*) FROM v_classifier_uncertain)                    AS classifier_uncertain;

COMMENT ON VIEW v_build_forensic_summary IS
'U84 /build/forensics — DLQ + drift + classifier-uncertain counts (V102).';

-- ── Permissions ────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'homeai_pipeline') THEN
    EXECUTE 'GRANT SELECT ON v_build_model_spend_30d, v_build_pipeline_status,
                              v_build_forensic_summary TO homeai_pipeline';
  END IF;
END$$;

-- ── Whitelist slugs ────────────────────────────────────────────────────────
INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES
  ('build_pipeline_status',
   'U84 /build/pipelines — AI pipeline activity',
   'SELECT * FROM v_build_pipeline_status',
   'AI provider activity over 7d: live/recent/stale/cold + 24h + 1h call counts',
   'u84-phase5', 'owner', 1,
   ARRAY['ai pipeline health', 'is the AI live'],
   now(), 'u84-phase5'),
  ('build_model_spend_30d',
   'U84 /build/models — per-model spend 30d',
   'SELECT * FROM v_build_model_spend_30d',
   'Token counts + crude cost (GBP) per model over last 30 days',
   'u84-phase5', 'owner', 1,
   ARRAY['model spend', 'AI cost'],
   now(), 'u84-phase5'),
  ('build_forensic_summary',
   'U84 /build/forensics — summary counts',
   'SELECT * FROM v_build_forensic_summary',
   'Exception counts by severity, anomaly z-score count, classifier uncertain',
   'u84-phase5', 'owner', 1,
   ARRAY['forensics summary', 'what is broken'],
   now(), 'u84-phase5')
ON CONFLICT (slug) DO UPDATE
  SET sql_template = EXCLUDED.sql_template,
      description  = EXCLUDED.description,
      display_name = EXCLUDED.display_name,
      approved_at  = now(),
      approved_by  = 'u84-phase5';

COMMIT;
