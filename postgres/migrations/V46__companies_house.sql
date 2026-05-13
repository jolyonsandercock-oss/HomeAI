-- ============================================================
-- U40 — Companies House API integration
-- SPEC §7.5
-- ============================================================
-- Free, no-auth UK Companies House API for filing-deadline tracking
-- and on-demand supplier/tenant verification.
-- ============================================================

-- ── Extend entities ──────────────────────────────────────────
ALTER TABLE entities
  ADD COLUMN IF NOT EXISTS companies_house_number TEXT;

CREATE INDEX IF NOT EXISTS idx_entities_companies_house
  ON entities (companies_house_number) WHERE companies_house_number IS NOT NULL;

COMMENT ON COLUMN entities.companies_house_number IS
  'UK Companies House registration number. Set for ARTL (entity_id=1) and AREL (entity_id=2). Used by u40-companies-house-sync.sh.';

-- ── companies_house_log ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS companies_house_log (
  id                                  BIGSERIAL PRIMARY KEY,
  snapshot_at                         TIMESTAMPTZ NOT NULL DEFAULT now(),
  company_number                      TEXT NOT NULL,
  name                                TEXT,
  status                              TEXT,
  registered_address                  JSONB,
  accounts_next_due_date              DATE,
  accounts_last_made_up_to            DATE,
  confirmation_statement_next_due_date DATE,
  confirmation_statement_last_made_up_to DATE,
  raw_payload                         JSONB
);

CREATE INDEX IF NOT EXISTS idx_chl_company ON companies_house_log (company_number, snapshot_at DESC);
CREATE INDEX IF NOT EXISTS idx_chl_recent  ON companies_house_log (snapshot_at DESC);

GRANT SELECT, INSERT ON companies_house_log TO homeai_pipeline;
GRANT SELECT ON companies_house_log TO homeai_readonly;
GRANT SELECT ON companies_house_log TO metabase_app;
GRANT USAGE, SELECT ON SEQUENCE companies_house_log_id_seq TO homeai_pipeline;

-- ── companies_house_alerts ───────────────────────────────────
CREATE TABLE IF NOT EXISTS companies_house_alerts (
  id              BIGSERIAL PRIMARY KEY,
  entity_id       INT NOT NULL REFERENCES entities(id),
  company_number  TEXT NOT NULL,
  alert_type      TEXT NOT NULL CHECK (alert_type IN ('accounts_due', 'confirmation_due')),
  due_date        DATE NOT NULL,
  days_until      INT NOT NULL,
  status          TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'acknowledged', 'filed')),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at     TIMESTAMPTZ,
  UNIQUE (entity_id, alert_type, due_date)
);

CREATE INDEX IF NOT EXISTS idx_cha_open ON companies_house_alerts (status, due_date) WHERE status = 'open';

ALTER TABLE companies_house_alerts ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON companies_house_alerts
  USING (
    CASE WHEN current_setting('app.current_entity', true) = 'all' THEN true
         WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN entity_id = current_setting('app.current_entity', true)::int
         ELSE false
    END);

GRANT SELECT, INSERT, UPDATE ON companies_house_alerts TO homeai_pipeline;
GRANT SELECT ON companies_house_alerts TO homeai_readonly;
GRANT SELECT ON companies_house_alerts TO metabase_app;
GRANT USAGE, SELECT ON SEQUENCE companies_house_alerts_id_seq TO homeai_pipeline;
