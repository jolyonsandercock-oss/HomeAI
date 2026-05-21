-- =============================================================================
-- V170 — U143: extend ai_usage for cost + tier + workflow telemetry.
-- =============================================================================
-- Adds the columns LiteLLM's post-callback (and llm-router) needs to
-- write per-call data:
--   workflow_id        — n8n workflow id, bot-responder slug name, etc.
--   prompt_hash        — sha256 of the prompt; lets us spot cache hits
--   cost_gbp           — computed from tokens × ai.prices at write-time
--   business_priority  — P0..P3 (or NULL for legacy rows)
--   capability_tag     — CAP_FINANCIAL_TRIAGE / CAP_DOC_CLASSIFY / etc.
--   system_fingerprint — Anthropic returns this on every response; tracks
--                        which LiteLLM backend served the call (failover)
--   would_block_reason — set in shadow mode (U144) when quota WOULD have
--                        blocked but enforce_mode=false; NULL otherwise.
--
-- Plus a model-price table in static_context under key 'ai.prices' (USD,
-- converted at write-time to GBP via a fixed rate stored in same key).
-- =============================================================================

BEGIN;

ALTER TABLE ai_usage
  ADD COLUMN workflow_id        text,
  ADD COLUMN prompt_hash        text,
  ADD COLUMN cost_gbp           numeric(10,6),
  ADD COLUMN business_priority  text,
  ADD COLUMN capability_tag     text,
  ADD COLUMN system_fingerprint text,
  ADD COLUMN would_block_reason text;

ALTER TABLE ai_usage
  ADD CONSTRAINT ai_usage_priority_check
  CHECK (business_priority IS NULL OR business_priority IN ('P0','P1','P2','P3'));

CREATE INDEX idx_ai_usage_priority_time ON ai_usage(business_priority, "timestamp" DESC)
  WHERE business_priority IS NOT NULL;
CREATE INDEX idx_ai_usage_workflow_time ON ai_usage(workflow_id, "timestamp" DESC)
  WHERE workflow_id IS NOT NULL;
CREATE INDEX idx_ai_usage_capability    ON ai_usage(capability_tag, "timestamp" DESC)
  WHERE capability_tag IS NOT NULL;

-- ---------- View: today's spend by priority --------------------------------
CREATE OR REPLACE VIEW v_ai_spend_today AS
SELECT business_priority,
       COALESCE(SUM(cost_gbp), 0)::numeric(10,4) AS spent_gbp,
       COUNT(*) AS call_count,
       COUNT(*) FILTER (WHERE would_block_reason IS NOT NULL) AS shadow_blocked_count
  FROM ai_usage
 WHERE "timestamp" >= CURRENT_DATE
 GROUP BY business_priority;

-- ---------- View: 7-day spend by capability + tier --------------------------
CREATE OR REPLACE VIEW v_ai_spend_7d_by_capability AS
SELECT capability_tag,
       business_priority,
       COALESCE(SUM(cost_gbp), 0)::numeric(10,4) AS spent_gbp,
       COUNT(*) AS call_count,
       COUNT(*) FILTER (WHERE cached) AS cache_hits
  FROM ai_usage
 WHERE "timestamp" >= NOW() - INTERVAL '7 days'
   AND capability_tag IS NOT NULL
 GROUP BY 1, 2
 ORDER BY 1, 2;

-- ---------- Seed: model price table ---------------------------------------
-- USD per million tokens. cache_read tokens carry separate rate.
-- gbp_per_usd is the conversion rate the LiteLLM callback applies.
INSERT INTO static_context (key, value, updated_at)
VALUES ('ai.prices',
        '{
          "gbp_per_usd": 0.79,
          "models": {
            "claude-opus-4-7":     {"input_per_mtok": 15.00, "output_per_mtok": 75.00, "cache_read_per_mtok": 1.50, "cache_creation_per_mtok": 18.75},
            "claude-sonnet-4-6":   {"input_per_mtok":  3.00, "output_per_mtok": 15.00, "cache_read_per_mtok": 0.30, "cache_creation_per_mtok":  3.75},
            "claude-haiku-4-5":    {"input_per_mtok":  0.80, "output_per_mtok":  4.00, "cache_read_per_mtok": 0.08, "cache_creation_per_mtok":  1.00},
            "claude-haiku-4-5-20251001": {"input_per_mtok":  0.80, "output_per_mtok":  4.00, "cache_read_per_mtok": 0.08, "cache_creation_per_mtok":  1.00},
            "qwen2.5:7b":          {"input_per_mtok":  0.00, "output_per_mtok":  0.00, "cache_read_per_mtok": 0.00, "cache_creation_per_mtok":  0.00},
            "phi4:14b":            {"input_per_mtok":  0.00, "output_per_mtok":  0.00, "cache_read_per_mtok": 0.00, "cache_creation_per_mtok":  0.00}
          }
        }'::jsonb,
        NOW())
ON CONFLICT (key) DO UPDATE
  SET value      = EXCLUDED.value,
      updated_at = NOW();

-- ---------- SQL helper to compute GBP cost from a usage row ----------------
-- Returns NULL if model not in price table. Callers should fall back to NULL.
CREATE OR REPLACE FUNCTION home_ai.compute_ai_cost_gbp(
    p_model           text,
    p_prompt_tokens   integer,
    p_completion_tokens integer,
    p_cache_creation_tokens integer,
    p_cache_read_tokens integer
) RETURNS numeric(10,6)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    prices   jsonb;
    model    jsonb;
    rate_gbp numeric;
    cost_usd numeric := 0;
BEGIN
    SELECT value INTO prices FROM static_context WHERE key = 'ai.prices';
    IF prices IS NULL THEN
        RETURN NULL;
    END IF;
    rate_gbp := COALESCE((prices->>'gbp_per_usd')::numeric, 0.79);
    model    := prices->'models'->p_model;
    IF model IS NULL THEN
        RETURN NULL;
    END IF;
    -- Subtract cache-creation + cache-read from the "fresh input" portion to avoid double-charging
    cost_usd := cost_usd
              + COALESCE(p_prompt_tokens, 0)         * COALESCE((model->>'input_per_mtok')::numeric, 0) / 1e6
              + COALESCE(p_completion_tokens, 0)     * COALESCE((model->>'output_per_mtok')::numeric, 0) / 1e6
              + COALESCE(p_cache_creation_tokens, 0) * COALESCE((model->>'cache_creation_per_mtok')::numeric, 0) / 1e6
              + COALESCE(p_cache_read_tokens, 0)     * COALESCE((model->>'cache_read_per_mtok')::numeric, 0) / 1e6;
    RETURN ROUND(cost_usd * rate_gbp, 6);
END
$$;

-- ---------- Backfill cost_gbp on existing ai_usage rows --------------------
UPDATE ai_usage
   SET cost_gbp = home_ai.compute_ai_cost_gbp(model_used,
                                              prompt_tokens, completion_tokens,
                                              cache_creation_tokens, cache_read_tokens)
 WHERE cost_gbp IS NULL;

-- ---------- Slug: today's spend by tier (for /admin tile) ------------------
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, result_format,
   active, created_by, approved_at, approved_by, notes, realm, intent_examples)
VALUES
('ai_spend_today',
 'U143 — AI spend today by priority tier',
 'Per-tier (P0..P3) spend today in GBP, call count, and would-have-blocked count from shadow-mode quota.',
 $sql$SELECT COALESCE(business_priority, '(untagged)') AS tier,
              spent_gbp,
              call_count,
              shadow_blocked_count
         FROM v_ai_spend_today
        ORDER BY tier$sql$,
 '{}'::jsonb,
 'table', true, 'u143', NOW(), 'u143', NULL, 'shared',
 ARRAY['ai spend','tier spend','cost today']),

('ai_spend_7d_by_capability',
 'U143 — AI spend 7d by capability + tier',
 'Per-capability_tag × business_priority spend over last 7 days.',
 $sql$SELECT * FROM v_ai_spend_7d_by_capability$sql$,
 '{}'::jsonb,
 'table', true, 'u143', NOW(), 'u143', NULL, 'shared',
 ARRAY['ai spend 7d','capability spend']);

COMMIT;
