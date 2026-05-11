-- V23: telegram_bot_state — small KV store for the polling bot
--
-- Stores the last seen Telegram update_id so the bot's getUpdates loop
-- doesn't re-process old commands every poll cycle. Single-row table
-- keyed on bot_id (we currently have one bot, but keep it generic).

\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS telegram_bot_state (
  bot_id          TEXT PRIMARY KEY,
  last_update_id  BIGINT NOT NULL DEFAULT 0,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO telegram_bot_state (bot_id, last_update_id)
VALUES ('homeai', 0)
ON CONFLICT (bot_id) DO NOTHING;

GRANT SELECT, INSERT, UPDATE ON telegram_bot_state TO homeai_pipeline;

SELECT 'V23 ready' AS check,
       (SELECT COUNT(*) FROM telegram_bot_state)::text || ' bot row(s)' AS detail;
