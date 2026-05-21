-- =============================================================================
-- V171 — U144: quota_allocations + shadow-mode quota allocator.
-- =============================================================================
-- £3/day Anthropic API-key budget, split P0 30% (floor) / P1 35% / P2 21% / P3 14%.
-- During build/import phase: enforce_mode=false, allocator runs in SHADOW
-- (returns would_block_reason for what it would have denied, but allows
-- everything). Operator flips enforce_mode=true post-import.
--
-- During shadow mode the Max-window subscription can overrule the API-key
-- cap by setting capability_routing.max_window_path='true' on heavy paths
-- (e.g. the U138-E backfill). That work doesn't hit ai_usage cost_gbp at
-- all because Max-window calls don't go via LiteLLM.
-- =============================================================================

BEGIN;

CREATE TABLE quota_allocations (
    business_priority      text PRIMARY KEY
                           CHECK (business_priority IN ('P0','P1','P2','P3')),
    pct_of_total           numeric(4,3) NOT NULL,
    daily_cost_ceiling_gbp numeric(8,4) NOT NULL,
    enforce_mode           boolean NOT NULL DEFAULT FALSE,
    realm                  text NOT NULL DEFAULT 'work'
                           CHECK (realm IN ('owner','work','personal','family','shared')),
    notes                  text,
    updated_at             timestamptz NOT NULL DEFAULT NOW()
);

INSERT INTO quota_allocations (business_priority, pct_of_total, daily_cost_ceiling_gbp, notes) VALUES
  ('P0', 0.300, 0.90, 'Floor — cannot be cannibalised by P1/P2/P3. Financial recon, bank surveillance, cashup.'),
  ('P1', 0.350, 1.05, 'Email triage, compliance checks, invoice extraction.'),
  ('P2', 0.210, 0.63, 'RAG queries, knowledge lookups, Karpathy reads.'),
  ('P3', 0.140, 0.42, 'News digest, exploratory, Storyblok generation.');

CREATE TABLE quota_alert_log (
    id           bigserial PRIMARY KEY,
    tier         text NOT NULL,
    fired_at     timestamptz NOT NULL DEFAULT NOW(),
    spent_gbp    numeric(10,4),
    ceiling_gbp  numeric(8,4),
    suppressed_until_date date NOT NULL,
    realm        text NOT NULL DEFAULT 'work'
);
CREATE INDEX idx_quota_alert_fired ON quota_alert_log(fired_at DESC);
CREATE UNIQUE INDEX idx_quota_alert_tier_day
  ON quota_alert_log(tier, suppressed_until_date);

-- ---------- allocator: home_ai.quota_check ---------------------------------
-- Returns a JSON object {allowed:bool, reason:text|null, spent_gbp, ceiling_gbp,
--                        enforce_mode:bool, p0_remaining_gbp}
-- In shadow mode (enforce_mode=false on the tier), `allowed` is ALWAYS true.
-- `reason` is set to the would-have-blocked reason regardless. Callers should
-- log `reason` to ai_usage.would_block_reason for visibility, then proceed.
CREATE OR REPLACE FUNCTION home_ai.quota_check(
    p_tier text,
    p_est_cost_gbp numeric DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    qa            quota_allocations%ROWTYPE;
    spent_today   numeric(10,4);
    p0_spent      numeric(10,4);
    p0_ceiling    numeric(8,4);
    total_ceiling numeric(8,4);
    sum_lower     numeric(10,4);    -- P1+P2+P3 spend
    would_block   text := NULL;
    allowed       boolean;
BEGIN
    IF p_tier NOT IN ('P0','P1','P2','P3') THEN
        RETURN jsonb_build_object(
            'allowed', false,
            'reason', 'invalid_tier',
            'spent_gbp', NULL,
            'ceiling_gbp', NULL,
            'enforce_mode', NULL
        );
    END IF;

    SELECT * INTO qa FROM quota_allocations WHERE business_priority = p_tier;

    SELECT COALESCE(SUM(cost_gbp), 0) INTO spent_today
      FROM ai_usage
     WHERE business_priority = p_tier
       AND "timestamp" >= CURRENT_DATE;

    -- Hard tier ceiling
    IF spent_today + p_est_cost_gbp >= qa.daily_cost_ceiling_gbp THEN
        would_block := 'tier_ceiling_exceeded';
    END IF;

    -- P0 floor protection: if this is P1/P2/P3, ensure remaining-after-P0 hasn't been eaten
    IF would_block IS NULL AND p_tier <> 'P0' THEN
        SELECT daily_cost_ceiling_gbp INTO p0_ceiling
          FROM quota_allocations WHERE business_priority='P0';
        SELECT COALESCE(SUM(cost_gbp), 0) INTO p0_spent
          FROM ai_usage WHERE business_priority='P0' AND "timestamp" >= CURRENT_DATE;
        SELECT SUM(daily_cost_ceiling_gbp) INTO total_ceiling FROM quota_allocations;
        SELECT COALESCE(SUM(cost_gbp), 0) INTO sum_lower
          FROM ai_usage
         WHERE business_priority IN ('P1','P2','P3') AND "timestamp" >= CURRENT_DATE;
        IF (sum_lower + p_est_cost_gbp) > (total_ceiling - p0_ceiling)
           AND p0_spent < p0_ceiling THEN
            would_block := 'p0_floor_protected';
        END IF;
    END IF;

    allowed := (would_block IS NULL) OR (NOT qa.enforce_mode);

    RETURN jsonb_build_object(
        'allowed',      allowed,
        'reason',       would_block,
        'spent_gbp',    spent_today,
        'ceiling_gbp',  qa.daily_cost_ceiling_gbp,
        'enforce_mode', qa.enforce_mode,
        'p0_ceiling_gbp', COALESCE(p0_ceiling, 0),
        'p0_spent_gbp',  COALESCE(p0_spent, 0)
    );
END
$$;

-- ---------- View: tier ceiling vs spent --------------------------------------
CREATE OR REPLACE VIEW v_quota_status AS
SELECT qa.business_priority AS tier,
       qa.daily_cost_ceiling_gbp AS ceiling_gbp,
       COALESCE(s.spent_gbp, 0)::numeric(10,4) AS spent_gbp,
       qa.enforce_mode,
       (COALESCE(s.spent_gbp, 0) >= qa.daily_cost_ceiling_gbp) AS at_ceiling,
       COALESCE(s.call_count, 0) AS call_count_today,
       COALESCE(s.shadow_blocked_count, 0) AS shadow_blocked_today,
       (qa.daily_cost_ceiling_gbp - COALESCE(s.spent_gbp, 0))::numeric(10,4) AS remaining_gbp
  FROM quota_allocations qa
  LEFT JOIN v_ai_spend_today s ON s.business_priority = qa.business_priority
 ORDER BY qa.business_priority;

-- ---------- Slug: quota status -----------------------------------------------
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, result_format,
   active, created_by, approved_at, approved_by, notes, realm, intent_examples)
VALUES
('quota_status_today',
 'U144 — per-tier quota status (today)',
 'Per-tier ceiling vs spent today. Drives the /admin spend tile. shadow_blocked_today shows how many calls would have been 429d if enforce_mode=true.',
 $sql$SELECT * FROM v_quota_status$sql$,
 '{}'::jsonb,
 'table', true, 'u144', NOW(), 'u144', NULL, 'shared',
 ARRAY['quota status','tier ceilings','remaining budget']);

GRANT EXECUTE ON FUNCTION home_ai.quota_check(text, numeric) TO homeai_readonly;
GRANT SELECT ON quota_allocations, quota_alert_log, v_quota_status TO homeai_readonly;

COMMIT;
