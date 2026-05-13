-- ============================================================
-- U33 — query_rejections: audit log of data-lane refusals
-- ============================================================
-- Every time the strict-source router (Chunk 4) declines to run a
-- request, the attempt is logged here. Reasons fall into a small
-- closed set so the dashboard can surface "top unmet intents" and
-- drive new query_whitelist entries.
--
-- We intentionally keep the user's raw question — that's the signal
-- we need to grow the whitelist. PII concerns are bounded because
-- the data-lane is internal-only (homeai_readonly + bot identities).
-- ============================================================

CREATE TABLE query_rejections (
  id                BIGSERIAL PRIMARY KEY,
  asked_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  asked_by          TEXT NOT NULL,                              -- identity from the bot session
  channel           TEXT NOT NULL,                              -- 'telegram','web','api',...
  raw_question      TEXT NOT NULL,                              -- exactly what the user typed

  classifier_slug   TEXT,                                       -- what the classifier emitted, if anything
  classifier_score  NUMERIC(4,3),                               -- 0.000..1.000, NULL if classifier didn't run
  bound_params      JSONB,                                      -- params the router tried to bind, if any

  reason            TEXT NOT NULL
                    CHECK (reason IN (
                      'no_slug',           -- classifier returned nothing
                      'unknown_slug',      -- slug not in query_whitelist
                      'inactive_slug',     -- slug present but active=false
                      'unapproved_slug',   -- slug active but approved_at is NULL
                      'param_missing',     -- required param absent
                      'param_type',        -- param failed type/shape check
                      'param_range',       -- param out of allowed range
                      'rls_block',         -- query ran but RLS returned 0 rows (likely wrong entity)
                      'runtime_error',     -- SQL exploded after binding
                      'other'
                    )),
  detail            TEXT,                                       -- free-text from the router

  entity_id         INT NOT NULL DEFAULT 3
);

CREATE INDEX idx_qr_asked_at  ON query_rejections (asked_at DESC);
CREATE INDEX idx_qr_reason    ON query_rejections (reason, asked_at DESC);
CREATE INDEX idx_qr_slug      ON query_rejections (classifier_slug) WHERE classifier_slug IS NOT NULL;
CREATE INDEX idx_qr_entity    ON query_rejections (entity_id);

ALTER TABLE query_rejections ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON query_rejections
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

GRANT SELECT, INSERT ON query_rejections TO homeai_pipeline;
GRANT USAGE, SELECT ON query_rejections_id_seq TO homeai_pipeline;
GRANT SELECT ON query_rejections TO homeai_readonly;
