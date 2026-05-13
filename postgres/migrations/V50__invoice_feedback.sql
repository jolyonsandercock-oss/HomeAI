-- ============================================================
-- U44 — invoice_feedback: plain-text user training for the categoriser
-- ============================================================

CREATE TABLE IF NOT EXISTS invoice_feedback (
  id            BIGSERIAL PRIMARY KEY,
  invoice_id    BIGINT REFERENCES vendor_invoice_inbox(id) ON DELETE CASCADE,
  feedback_text TEXT NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by    TEXT NOT NULL DEFAULT 'jo',
  ai_proposal   JSONB,        -- Sonnet's structured interpretation
  applied_at    TIMESTAMPTZ,  -- when Jo approved the proposal
  applied_rules JSONB,        -- what landed (which vendor_category_rules / column flips)
  rejected_at   TIMESTAMPTZ,
  rejection_reason TEXT
);

CREATE INDEX IF NOT EXISTS idx_invoice_feedback_pending
  ON invoice_feedback (created_at)
  WHERE applied_at IS NULL AND rejected_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_invoice_feedback_invoice
  ON invoice_feedback (invoice_id);

GRANT SELECT, INSERT, UPDATE ON invoice_feedback TO homeai_pipeline;
GRANT SELECT ON invoice_feedback TO homeai_readonly;
GRANT SELECT ON invoice_feedback TO metabase_app;
GRANT USAGE, SELECT ON SEQUENCE invoice_feedback_id_seq TO homeai_pipeline;

COMMENT ON TABLE invoice_feedback IS
  'U44 — plain-text user feedback per invoice. Sonnet applier (u44-feedback-applier.sh, cron 21:30) reads pending rows and proposes structured action types. Never auto-applies — Jo approves via Action Queue.';
