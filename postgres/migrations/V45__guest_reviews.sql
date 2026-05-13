-- ============================================================
-- U39 — Guest Review Response Assistant
-- SPEC §7.4 (PRIORITY Phase 2 deliverable)
-- ============================================================
-- Stores reviews scraped from Google Business + TripAdvisor and the
-- Sonnet-drafted responses for Jo to approve/edit/reject in the Action
-- Queue. Posting back to the platforms stays manual.
-- ============================================================

-- ── guest_reviews ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS guest_reviews (
  review_id        TEXT NOT NULL,
  source           TEXT NOT NULL CHECK (source IN ('google', 'tripadvisor')),
  location         TEXT NOT NULL CHECK (location IN ('malthouse', 'sandwich')),
  rating           INTEGER CHECK (rating BETWEEN 1 AND 5),
  reviewer_name    TEXT,
  body             TEXT,
  posted_at        TIMESTAMPTZ,
  scraped_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  raw_payload      JSONB,
  status           TEXT NOT NULL DEFAULT 'new'
                   CHECK (status IN ('new', 'drafted', 'approved', 'posted', 'rejected', 'ignored')),
  entity_id        INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (source, review_id)
);

CREATE INDEX IF NOT EXISTS idx_gr_status_posted ON guest_reviews (status, posted_at DESC);
CREATE INDEX IF NOT EXISTS idx_gr_rating       ON guest_reviews (rating, posted_at DESC) WHERE rating <= 3;
CREATE INDEX IF NOT EXISTS idx_gr_location     ON guest_reviews (location, posted_at DESC);

ALTER TABLE guest_reviews ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON guest_reviews
  USING (
    CASE WHEN current_setting('app.current_entity', true) = 'all' THEN true
         WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN entity_id = current_setting('app.current_entity', true)::int
         ELSE false
    END)
  WITH CHECK (
    CASE WHEN current_setting('app.current_entity', true) = 'all' THEN true
         WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN entity_id = current_setting('app.current_entity', true)::int
         ELSE false
    END);

GRANT SELECT, INSERT, UPDATE ON guest_reviews TO homeai_pipeline;
GRANT SELECT ON guest_reviews TO homeai_readonly;
GRANT SELECT ON guest_reviews TO metabase_app;

-- ── review_drafts ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS review_drafts (
  id              BIGSERIAL PRIMARY KEY,
  review_id       TEXT NOT NULL,
  source          TEXT NOT NULL,
  draft_text      TEXT NOT NULL,
  sonnet_model    TEXT,
  schema_version  TEXT,
  prompt_cache_hit BOOLEAN DEFAULT false,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  approved_by     TEXT,
  approved_at     TIMESTAMPTZ,
  edited_text     TEXT,
  posted_at       TIMESTAMPTZ,
  rejected_at     TIMESTAMPTZ,
  rejection_reason TEXT,
  FOREIGN KEY (source, review_id) REFERENCES guest_reviews(source, review_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_rd_review ON review_drafts (source, review_id);
CREATE INDEX IF NOT EXISTS idx_rd_pending ON review_drafts (created_at DESC)
  WHERE approved_at IS NULL AND rejected_at IS NULL;

GRANT SELECT, INSERT, UPDATE ON review_drafts TO homeai_pipeline;
GRANT SELECT ON review_drafts TO homeai_readonly;
GRANT SELECT ON review_drafts TO metabase_app;
GRANT USAGE, SELECT ON SEQUENCE review_drafts_id_seq TO homeai_pipeline;

COMMENT ON TABLE guest_reviews IS
  'U39 — reviews scraped from Google Business + TripAdvisor for Malthouse (pub) and Sandwich (cafe).';
COMMENT ON TABLE review_drafts IS
  'U39 — Sonnet-drafted responses for guest_reviews. Jo approves/edits/rejects via Action Queue. Posting back to platforms stays manual.';
