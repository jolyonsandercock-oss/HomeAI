-- ============================================================
-- U47a — Bot feedback table + low-confidence classifier queue view
-- ============================================================
-- Captures Jo's corrections to AI classifier output. Sonnet overnight
-- pass (extension of u44-feedback-applier) ingests these and proposes
-- prompt/heuristic changes for the dreaming workflow.
-- ============================================================

CREATE TABLE IF NOT EXISTS bot_feedback (
  id              BIGSERIAL PRIMARY KEY,
  email_id        BIGINT REFERENCES emails(id) ON DELETE SET NULL,
  invoice_id      BIGINT REFERENCES vendor_invoice_inbox(id) ON DELETE SET NULL,
  domain          TEXT NOT NULL DEFAULT 'classifier'
                    CHECK (domain IN ('classifier','invoice','reviews','workforce','other')),
  original_class  TEXT,
  corrected_class TEXT,
  original_conf   NUMERIC(3,2),
  notes           TEXT NOT NULL,
  applied         BOOLEAN DEFAULT false,
  applied_action  TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  applied_at      TIMESTAMPTZ,
  CHECK (email_id IS NOT NULL OR invoice_id IS NOT NULL OR domain = 'other')
);

CREATE INDEX IF NOT EXISTS idx_bot_feedback_pending ON bot_feedback (applied, created_at DESC) WHERE applied = false;
CREATE INDEX IF NOT EXISTS idx_bot_feedback_email ON bot_feedback (email_id) WHERE email_id IS NOT NULL;

GRANT SELECT, INSERT, UPDATE ON bot_feedback TO homeai_pipeline;
GRANT SELECT ON bot_feedback TO homeai_readonly;
GRANT SELECT ON bot_feedback TO metabase_app;
GRANT USAGE, SELECT ON SEQUENCE bot_feedback_id_seq TO homeai_pipeline;

COMMENT ON TABLE bot_feedback IS
  'U47a — captures Jo''s corrections to AI output. Sonnet overnight pass updates prompts/heuristics.';

-- Low-confidence classifier queue. Threshold is 0.85 because the current
-- bot-responder caps confidence at 0.80 as a floor (no rows < 0.7 exist),
-- so anything at 0.80–0.85 is "AI was uncertain".
CREATE OR REPLACE VIEW v_classifier_uncertain AS
SELECT
  e.id                 AS email_id,
  e.gmail_message_id,
  e.account,
  e.from_address,
  e.from_name,
  e.subject,
  e.received_at,
  e.classification,
  e.confidence_score,
  e.requires_human,
  e.action_required,
  EXTRACT(DAY FROM (now() - e.received_at))::int AS age_days,
  COALESCE(bf.applied, false) AS already_reviewed
FROM emails e
LEFT JOIN bot_feedback bf
  ON bf.email_id = e.id AND bf.domain = 'classifier'
WHERE e.confidence_score IS NOT NULL
  AND e.confidence_score <= 0.85
  AND e.received_at > now() - INTERVAL '14 days'
  AND COALESCE(bf.applied, false) = false
ORDER BY e.confidence_score ASC, e.received_at DESC;

GRANT SELECT ON v_classifier_uncertain TO homeai_pipeline, homeai_readonly, metabase_app;

COMMENT ON VIEW v_classifier_uncertain IS
  'U47a — emails the classifier was unsure about (confidence <= 0.85, not yet reviewed). Surfaces in Mission Control "AI uncertain" card.';
