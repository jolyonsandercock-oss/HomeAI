-- =============================================================================
-- V128 — ai_usage: explicit cache token columns + bot-responder logging
-- =============================================================================
-- Prompt caching is wired in bot-responder + several scripts, but ai_usage
-- only has a binary `cached` flag. To measure actual savings, capture the
-- two token counters Anthropic returns on every call:
--
--   cache_creation_input_tokens — tokens written into the cache (first call;
--                                  costs 25% premium over normal input)
--   cache_read_input_tokens     — tokens served from cache (subsequent calls
--                                  within 5 min TTL; cost 10% of normal)
--
-- Adds a service column so we can attribute calls (bot-responder vs u61 etc).
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

ALTER TABLE ai_usage
  ADD COLUMN IF NOT EXISTS cache_creation_tokens INTEGER,
  ADD COLUMN IF NOT EXISTS cache_read_tokens     INTEGER,
  ADD COLUMN IF NOT EXISTS service               TEXT;

CREATE INDEX IF NOT EXISTS idx_ai_usage_service_time
  ON ai_usage (service, timestamp DESC);

COMMENT ON COLUMN ai_usage.cache_creation_tokens IS
'U109 V128. tokens written to ephemeral prompt cache on first call. '
'25% input-cost premium. Anthropic API response.usage.cache_creation_input_tokens';

COMMENT ON COLUMN ai_usage.cache_read_tokens IS
'U109 V128. tokens served from cache on hit. 10% input-cost. '
'Anthropic API response.usage.cache_read_input_tokens';

COMMENT ON COLUMN ai_usage.service IS
'U109 V128. caller — bot-responder, u61-line-items, u68-doc-classify etc.';

-- Convenience view: cache effectiveness per service over last 7d
DROP VIEW IF EXISTS v_ai_cache_effectiveness CASCADE;
CREATE VIEW v_ai_cache_effectiveness AS
SELECT
  service,
  model_used,
  COUNT(*)                                AS calls,
  SUM(prompt_tokens)::bigint              AS prompt_tokens_total,
  SUM(cache_creation_tokens)::bigint      AS cache_writes,
  SUM(cache_read_tokens)::bigint          AS cache_reads,
  ROUND(100.0 * SUM(cache_read_tokens)::numeric
        / NULLIF(SUM(prompt_tokens + COALESCE(cache_creation_tokens,0) + COALESCE(cache_read_tokens,0)), 0),
        1) AS pct_input_cached
FROM ai_usage
WHERE timestamp >= NOW() - INTERVAL '7 days'
  AND service IS NOT NULL
GROUP BY service, model_used
ORDER BY SUM(cache_read_tokens) DESC NULLS LAST;

COMMENT ON VIEW v_ai_cache_effectiveness IS
'U109 V128. Per-service cache hit-rate over last 7d. pct_input_cached close '
'to 0% means caching not engaging (prefix too small for the model tier).';

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES (
  'ai_cache_effectiveness',
  'U109 — prompt cache effectiveness 7d',
  'SELECT * FROM v_ai_cache_effectiveness',
  'Anthropic prompt-cache hit-rate per service over last week',
  'u109','owner',1, ARRAY['prompt cache','cache effectiveness','token saving'],
  now(),'u109'
) ON CONFLICT (slug) DO UPDATE SET
  sql_template=EXCLUDED.sql_template, approved_at=now(), approved_by='u109';

COMMIT;
