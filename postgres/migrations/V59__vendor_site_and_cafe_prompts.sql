-- V59: site-aware vendor classification + cafe-vendor prompt staging
--
-- vendor_category_rules previously had no site dimension — every rule
-- attributed spend to 'shared'. U47d Track 4 adds a 'cafe' lane so the
-- ice cream shop's spend separates from pub/inn shared overheads.
--
-- A staging table `cafe_vendor_prompt_state` retains the candidate set
-- between the prompt-send and reply-apply phases so the Telegram round-
-- trip can be async (user not necessarily at phone when prompt fires).

BEGIN;

ALTER TABLE vendor_category_rules
  ADD COLUMN IF NOT EXISTS site TEXT NOT NULL DEFAULT 'shared'
    CHECK (site IN ('shared', 'cafe', 'pub', 'inn'));

ALTER TABLE vendor_category_rules
  DROP CONSTRAINT IF EXISTS vendor_category_rules_domain_pattern_key;

ALTER TABLE vendor_category_rules
  ADD CONSTRAINT vendor_category_rules_pattern_site_key
    UNIQUE (domain_pattern, site);

CREATE TABLE IF NOT EXISTS cafe_vendor_prompt_state (
  id                   BIGSERIAL PRIMARY KEY,
  telegram_message_id  BIGINT,
  telegram_chat_id     BIGINT,
  candidates           JSONB NOT NULL,
  sent_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  applied_at           TIMESTAMPTZ,
  applied_rule_ids     BIGINT[],
  entity_id            INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_cvps_unapplied
  ON cafe_vendor_prompt_state (sent_at DESC)
  WHERE applied_at IS NULL;

ALTER TABLE cafe_vendor_prompt_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS entity_isolation ON cafe_vendor_prompt_state;
CREATE POLICY entity_isolation ON cafe_vendor_prompt_state
  USING (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all' THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'
        THEN entity_id = current_setting('app.current_entity', true)::integer
      ELSE false
    END);

COMMIT;
