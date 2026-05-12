-- ============================================================
-- U29 — bot_instructions: queue for inbound user instructions
-- ============================================================
-- Inputs come from two sources today:
--   * Email — jolyon.sandercock@gmail.com → jolyboxbot@gmail.com
--   * Telegram — bot DM from the authorised chat_id
--
-- Polled every 5 min by scripts/u29-bot-instructions-poll.sh which
-- INSERTs new rows + acks the user via TG. Pending rows are read by
-- Claude Code on every session start (per memory note).
-- ============================================================

CREATE TABLE bot_instructions (
  id              BIGSERIAL PRIMARY KEY,
  source          TEXT NOT NULL CHECK (source IN ('email','telegram','manual')),
  source_id       TEXT,                       -- gmail msg id / telegram message id
  from_user       TEXT NOT NULL,
  received_at     TIMESTAMPTZ NOT NULL,
  ingested_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

  raw_subject     TEXT,
  raw_text        TEXT NOT NULL,
  triage_summary  TEXT,                       -- short one-liner derived at ingest time

  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','triaged','done','rejected','duplicate')),

  picked_up_at    TIMESTAMPTZ,
  picked_up_by    TEXT,                       -- claude session id / human ack
  resolution      TEXT,
  resolved_at     TIMESTAMPTZ,

  entity_id       INT NOT NULL DEFAULT 3,     -- 3 = personal
  UNIQUE (source, source_id)
);
CREATE INDEX idx_bi_status_received ON bot_instructions (status, received_at DESC);

ALTER TABLE bot_instructions ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON bot_instructions
  USING (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'        THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'      THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END)
  WITH CHECK (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'        THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'      THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END);

GRANT SELECT, INSERT, UPDATE, DELETE ON bot_instructions TO homeai_pipeline;
GRANT USAGE, SELECT ON bot_instructions_id_seq TO homeai_pipeline;
GRANT SELECT, UPDATE ON bot_instructions TO homeai_readonly;
