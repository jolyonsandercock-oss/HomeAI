-- V26: command_log — audit trail for Telegram bot commands.
--
-- The bot now supports destructive commands (/pause, /resume, /sweep) so we
-- need a defensive log of who ran what when. Single-table append-only.

\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS command_log (
  id           BIGSERIAL PRIMARY KEY,
  channel      TEXT NOT NULL DEFAULT 'telegram',
  user_id      TEXT,                                   -- Telegram user id (string)
  command      TEXT NOT NULL,                          -- e.g. '/pause'
  args         TEXT,                                   -- raw text after command
  result       TEXT NOT NULL CHECK (result IN ('success','denied','error')),
  result_note  TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_command_log_command_created
  ON command_log (command, created_at DESC);

GRANT SELECT, INSERT ON command_log TO homeai_pipeline;
GRANT USAGE ON SEQUENCE command_log_id_seq TO homeai_pipeline;

SELECT 'V26 ready' AS check,
       (SELECT COUNT(*) FROM information_schema.tables
         WHERE table_name='command_log')::text || ' table(s)' AS detail;
