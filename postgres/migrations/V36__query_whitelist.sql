-- ============================================================
-- U33 — query_whitelist: vetted SQL templates for data-lane bot
-- ============================================================
-- The strict-source data-lane router (see Chunk 4) refuses to run
-- any SQL that isn't registered here. Lookup is by `slug` only —
-- the classifier (Chunk 3) chooses a slug from this table, the
-- router fetches the row and binds params into `sql_template`.
--
-- An entry is eligible iff `active=true` AND `approved_at` is set.
-- `intent_examples` is prompt material for the classifier (not a
-- lookup key); the actual match key is the slug it emits.
-- Rejected attempts (no slug, unapproved, param-validation fail)
-- are logged to query_rejections (V37).
-- ============================================================

CREATE TABLE query_whitelist (
  id               BIGSERIAL PRIMARY KEY,
  slug             TEXT NOT NULL UNIQUE,                      -- stable handle, e.g. 'pub_takings_day'
  display_name     TEXT NOT NULL,
  description      TEXT,
  intent_examples  TEXT[] NOT NULL DEFAULT '{}',              -- NL phrasings, fed to classifier prompt
  sql_template     TEXT NOT NULL,                             -- :param placeholders, bound at runtime
  param_schema     JSONB NOT NULL DEFAULT '{}'::jsonb,        -- {name: {type, required, default}}
  result_format    TEXT NOT NULL DEFAULT 'table'
                   CHECK (result_format IN ('table','scalar','markdown')),
  active           BOOLEAN NOT NULL DEFAULT TRUE,

  entity_id        INT NOT NULL DEFAULT 3,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by       TEXT NOT NULL,
  approved_at      TIMESTAMPTZ,
  approved_by      TEXT,
  notes            TEXT
);

CREATE INDEX idx_qw_active_slug ON query_whitelist (active, slug);
CREATE INDEX idx_qw_entity      ON query_whitelist (entity_id);

ALTER TABLE query_whitelist ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON query_whitelist
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

GRANT SELECT, INSERT, UPDATE, DELETE ON query_whitelist TO homeai_pipeline;
GRANT USAGE, SELECT ON query_whitelist_id_seq TO homeai_pipeline;
GRANT SELECT ON query_whitelist TO homeai_readonly;
