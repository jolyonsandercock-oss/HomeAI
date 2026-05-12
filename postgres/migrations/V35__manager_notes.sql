-- ============================================================
-- U32 — manager_notes: free-text per-day notes from the manager
-- ============================================================
-- Drives the "Manager's Note" field at the top of /m (and / later).
-- Lets the human override or annotate any day with context the data
-- doesn't carry (e.g. "Power cut 14:00-16:00 — Z reading short").
-- ============================================================

CREATE TABLE manager_notes (
  id              BIGSERIAL PRIMARY KEY,
  entity_id       INT NOT NULL DEFAULT 1,
  note_date       DATE NOT NULL,
  body            TEXT NOT NULL,
  author          TEXT,
  tags            JSONB DEFAULT '[]'::jsonb,    -- ["staff","weather","incident"]
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_manager_notes_date ON manager_notes (note_date DESC);

ALTER TABLE manager_notes ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON manager_notes
  USING (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'   THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END)
  WITH CHECK (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'   THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END);

GRANT SELECT, INSERT, UPDATE, DELETE ON manager_notes TO homeai_pipeline;
GRANT USAGE, SELECT ON manager_notes_id_seq TO homeai_pipeline;
GRANT SELECT, INSERT, UPDATE ON manager_notes TO homeai_readonly;
