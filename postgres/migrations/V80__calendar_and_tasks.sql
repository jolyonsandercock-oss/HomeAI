-- =============================================================================
-- V80 — calendar_events + tasks (U62 T1+T2)
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. calendar_events — Google Calendar mirror, idempotent on gcal_event_id
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS calendar_events (
    id              BIGSERIAL PRIMARY KEY,
    source_account  TEXT        NOT NULL,
    calendar_id     TEXT        NOT NULL DEFAULT 'primary',
    gcal_event_id   TEXT        NOT NULL,
    title           TEXT,
    description     TEXT,
    location        TEXT,
    start_at        TIMESTAMPTZ NOT NULL,
    end_at          TIMESTAMPTZ,
    all_day         BOOLEAN     NOT NULL DEFAULT FALSE,
    attendees       JSONB,
    organiser_email TEXT,
    status          TEXT        NOT NULL DEFAULT 'confirmed',
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    fetched_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    entity_id       INTEGER,
    realm           TEXT        NOT NULL,
    UNIQUE (source_account, gcal_event_id)
);

ALTER TABLE calendar_events DROP CONSTRAINT IF EXISTS calendar_events_realm_check;
ALTER TABLE calendar_events ADD CONSTRAINT calendar_events_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

CREATE INDEX IF NOT EXISTS idx_calendar_events_start ON calendar_events (start_at DESC);
CREATE INDEX IF NOT EXISTS idx_calendar_events_realm ON calendar_events (realm);

ALTER TABLE calendar_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS entity_isolation ON calendar_events;
CREATE POLICY entity_isolation ON calendar_events
    USING (
        CASE
            WHEN current_setting('app.current_entity', true) = 'all' THEN true
            WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN
                entity_id IS NULL OR entity_id = current_setting('app.current_entity', true)::int
            ELSE false
        END
    );

DROP POLICY IF EXISTS realm_isolation ON calendar_events;
CREATE POLICY realm_isolation ON calendar_events AS RESTRICTIVE
    USING (
        CASE
            WHEN current_setting('app.current_realm', true) = 'owner'  THEN true
            WHEN current_setting('app.current_realm', true) = 'work'   THEN realm IN ('work','shared')
            WHEN current_setting('app.current_realm', true) = 'family' THEN realm IN ('family','shared')
            WHEN current_setting('app.current_realm', true) IS NULL
              OR current_setting('app.current_realm', true) = ''       THEN true
            ELSE false
        END
    );

CREATE OR REPLACE VIEW v_calendar_upcoming AS
SELECT id, source_account, title, location, start_at, end_at, all_day,
       attendees, organiser_email, realm, entity_id
  FROM calendar_events
 WHERE start_at >= NOW() - INTERVAL '1 day'
   AND start_at <= NOW() + INTERVAL '30 days'
   AND status <> 'cancelled'
 ORDER BY start_at ASC;

COMMENT ON VIEW v_calendar_upcoming IS
    'Next 30 days of calendar events across all synced Google accounts.';

-- ---------------------------------------------------------------------------
-- 2. tasks — manual + AI-extracted. email_tasks (U46) feeds in via a view.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS tasks (
    id            BIGSERIAL PRIMARY KEY,
    source        TEXT        NOT NULL DEFAULT 'manual',   -- 'manual','email','bot','rule'
    source_ref    TEXT,                                     -- foreign key text for traceability
    title         TEXT        NOT NULL,
    body          TEXT,
    priority      TEXT        NOT NULL DEFAULT 'normal',   -- low/normal/high/urgent
    status        TEXT        NOT NULL DEFAULT 'open',     -- open/in_progress/done/snoozed/cancelled
    due_at        TIMESTAMPTZ,
    snoozed_until TIMESTAMPTZ,
    completed_at  TIMESTAMPTZ,
    assigned_to   TEXT,
    entity_id     INTEGER,
    realm         TEXT        NOT NULL DEFAULT 'owner',
    created_by    TEXT        NOT NULL DEFAULT 'jo',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE tasks DROP CONSTRAINT IF EXISTS tasks_priority_check;
ALTER TABLE tasks ADD CONSTRAINT tasks_priority_check
    CHECK (priority IN ('low','normal','high','urgent'));

ALTER TABLE tasks DROP CONSTRAINT IF EXISTS tasks_status_check;
ALTER TABLE tasks ADD CONSTRAINT tasks_status_check
    CHECK (status IN ('open','in_progress','done','snoozed','cancelled'));

ALTER TABLE tasks DROP CONSTRAINT IF EXISTS tasks_realm_check;
ALTER TABLE tasks ADD CONSTRAINT tasks_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

CREATE INDEX IF NOT EXISTS idx_tasks_status_due ON tasks (status, due_at NULLS LAST);
CREATE INDEX IF NOT EXISTS idx_tasks_realm      ON tasks (realm);

ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS realm_isolation ON tasks;
CREATE POLICY realm_isolation ON tasks AS RESTRICTIVE
    USING (
        CASE
            WHEN current_setting('app.current_realm', true) = 'owner'  THEN true
            WHEN current_setting('app.current_realm', true) = 'work'   THEN realm IN ('work','shared')
            WHEN current_setting('app.current_realm', true) = 'family' THEN realm IN ('family','shared')
            WHEN current_setting('app.current_realm', true) IS NULL
              OR current_setting('app.current_realm', true) = ''       THEN true
            ELSE false
        END
    );

DROP POLICY IF EXISTS entity_isolation ON tasks;
CREATE POLICY entity_isolation ON tasks
    USING (
        CASE
            WHEN current_setting('app.current_entity', true) = 'all' THEN true
            WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN
                entity_id IS NULL OR entity_id = current_setting('app.current_entity', true)::int
            ELSE false
        END
    );

-- Unified view: manual tasks + AI-extracted email_tasks
CREATE OR REPLACE VIEW v_tasks_unified AS
SELECT
    'task:' || id::text       AS uid,
    'manual'                  AS kind,
    id                        AS task_id,
    NULL::bigint              AS email_task_id,
    title,
    body,
    priority,
    status,
    due_at,
    entity_id,
    realm,
    assigned_to,
    created_at
  FROM tasks
 WHERE status <> 'cancelled'
UNION ALL
SELECT
    'etask:' || et.id::text   AS uid,
    'email_task'              AS kind,
    NULL::bigint              AS task_id,
    et.id                     AS email_task_id,
    et.subject                AS title,
    et.notes                  AS body,
    CASE WHEN et.severity >= 4 THEN 'urgent'
         WHEN et.severity >= 3 THEN 'high'
         WHEN et.severity >= 2 THEN 'normal'
         ELSE 'low' END       AS priority,
    et.status                 AS status,
    et.due_by::timestamptz    AS due_at,
    NULL::int                 AS entity_id,
    et.realm,
    NULL::text                AS assigned_to,
    et.detected_at            AS created_at
  FROM email_tasks et
 WHERE et.status NOT IN ('done','rejected','closed')
 ORDER BY due_at NULLS LAST, created_at DESC;

COMMENT ON VIEW v_tasks_unified IS
    'Manual tasks + AI-extracted email_tasks in one feed for /tasks UI.';

-- ---------------------------------------------------------------------------
-- 3. document_expiry helper view (for U62 T4 alerts cron)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_documents_expiry_due AS
SELECT id, title, category, expiry_date, review_date, linked_table, linked_id,
       entity_id, realm,
       CASE
         WHEN expiry_date IS NOT NULL AND expiry_date <= CURRENT_DATE THEN 'expired'
         WHEN expiry_date IS NOT NULL AND expiry_date <= CURRENT_DATE + INTERVAL '30 days' THEN 'expiring_soon'
         WHEN review_date IS NOT NULL AND review_date <= CURRENT_DATE THEN 'review_due'
         ELSE NULL
       END AS state,
       LEAST(expiry_date, review_date) AS soonest_date
  FROM documents
 WHERE (expiry_date IS NOT NULL AND expiry_date <= CURRENT_DATE + INTERVAL '30 days')
    OR (review_date IS NOT NULL AND review_date <= CURRENT_DATE)
 ORDER BY soonest_date NULLS LAST;

COMMENT ON VIEW v_documents_expiry_due IS
    'Docs in expired / expiring_soon (≤30d) / review_due states. Drives the '
    'u62-doc-alerts.sh cron + Mission Control "needs review" tile.';

COMMIT;
