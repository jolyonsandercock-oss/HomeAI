-- ============================================================
-- U46 — Email "To Do" scaffold
-- ============================================================
-- Tracks the operational task that an inbound email implies:
--   - explicit ask ("please reply", "can you confirm")
--   - implicit complaint ("disappointed", "refund", "letter from lawyer")
--   - follow-up due (no reply received within N days of an outbound)
-- Urgency = age_days × severity, surfaced in Mission Control.
-- ============================================================

CREATE TABLE IF NOT EXISTS email_tasks (
  id                BIGSERIAL PRIMARY KEY,
  email_id          BIGINT NOT NULL REFERENCES emails(id) ON DELETE CASCADE,
  gmail_message_id  TEXT,
  account           TEXT,
  subject           TEXT,
  task_type         TEXT NOT NULL CHECK (task_type IN
                      ('action','complaint','follow_up','renewal','enquiry')),
  severity          INT NOT NULL CHECK (severity BETWEEN 1 AND 5),
  detected_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  due_by            DATE,
  status            TEXT NOT NULL DEFAULT 'open'
                      CHECK (status IN ('open','snoozed','done','dismissed')),
  resolved_at       TIMESTAMPTZ,
  resolved_by       TEXT,
  notes             TEXT,
  extractor_payload JSONB,
  UNIQUE (email_id)
);

CREATE INDEX IF NOT EXISTS idx_email_tasks_open ON email_tasks (status, detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_email_tasks_due ON email_tasks (due_by) WHERE status = 'open';

GRANT SELECT, INSERT, UPDATE ON email_tasks TO homeai_pipeline;
GRANT SELECT ON email_tasks TO homeai_readonly;
GRANT SELECT ON email_tasks TO metabase_app;
GRANT USAGE, SELECT ON SEQUENCE email_tasks_id_seq TO homeai_pipeline;

-- Open task list ordered by urgency = age_days × severity
CREATE OR REPLACE VIEW v_email_tasks_open AS
SELECT
  t.id,
  t.email_id,
  t.account,
  t.subject,
  t.task_type,
  t.severity,
  t.detected_at,
  t.due_by,
  e.from_address,
  e.from_name,
  e.received_at,
  EXTRACT(DAY FROM (now() - e.received_at))::int   AS age_days,
  EXTRACT(DAY FROM (now() - e.received_at))::int
    * t.severity                                    AS urgency_score,
  CASE WHEN t.due_by IS NOT NULL AND t.due_by < CURRENT_DATE
       THEN (CURRENT_DATE - t.due_by) ELSE 0 END    AS days_overdue
FROM email_tasks t
JOIN emails e ON e.id = t.email_id
WHERE t.status = 'open'
ORDER BY urgency_score DESC, t.detected_at ASC;

GRANT SELECT ON v_email_tasks_open TO homeai_pipeline, homeai_readonly, metabase_app;

COMMENT ON TABLE  email_tasks IS
  'U46 — extracted operational tasks from inbound emails (action/complaint/follow_up/renewal/enquiry).';
COMMENT ON VIEW   v_email_tasks_open IS
  'U46 — open email tasks ranked by urgency (age × severity).';
