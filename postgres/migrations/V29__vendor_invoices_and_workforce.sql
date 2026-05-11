-- ============================================================
-- U29 + U30 — vendor invoice triage + Workforce.com (Tanda) tables
-- ============================================================
-- Two unrelated concerns but landing in the same migration since
-- they're stub-tier and we want one new migration not two.
-- ============================================================

-- ── A. Vendor invoice triage (U29) ───────────────────────────
-- Light-touch inbox view. Every invoice-shaped email gets a row
-- here so the dashboard can show "you have N unpaid bills" without
-- waiting for Haiku extraction (Pipeline 2). When P2 finishes
-- enriching a row, linked_invoice_id points at the canonical row.
CREATE TABLE vendor_invoice_inbox (
  id              BIGSERIAL PRIMARY KEY,
  idempotency_key TEXT NOT NULL UNIQUE,
  source_email_id TEXT NOT NULL UNIQUE,
  account         TEXT NOT NULL,
  entity_id       INT NOT NULL DEFAULT 1,

  vendor_domain   TEXT NOT NULL,
  vendor_name     TEXT,
  vendor_id       INT,

  subject         TEXT NOT NULL,
  received_at     TIMESTAMPTZ NOT NULL,

  amount_seen     NUMERIC(12,2),
  currency        CHAR(3) DEFAULT 'GBP',
  invoice_date    DATE,
  due_date        DATE,

  attachment_count INT DEFAULT 0,
  first_attachment_path TEXT,
  has_pdf         BOOLEAN DEFAULT FALSE,

  status          TEXT NOT NULL DEFAULT 'new'
                  CHECK (status IN ('new','extracted','paid','disputed','ignored','duplicate')),

  linked_invoice_id BIGINT,  -- nullable FK to invoices(id) when populated

  notes           TEXT,
  ingested_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_vii_status_received ON vendor_invoice_inbox (status, received_at DESC);
CREATE INDEX idx_vii_vendor          ON vendor_invoice_inbox (vendor_domain, received_at DESC);

ALTER TABLE vendor_invoice_inbox ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON vendor_invoice_inbox
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

GRANT SELECT, INSERT, UPDATE, DELETE ON vendor_invoice_inbox TO homeai_pipeline;
GRANT USAGE, SELECT ON vendor_invoice_inbox_id_seq TO homeai_pipeline;
GRANT SELECT ON vendor_invoice_inbox TO homeai_readonly;


-- ── B. Workforce.com (Tanda) tables (U30 stubs) ──────────────
-- Mirror only the fields we actually consume from the API; everything
-- else is in raw_payload jsonb so we never lose information.

CREATE TABLE workforce_users (
  id              BIGSERIAL PRIMARY KEY,
  external_id     BIGINT NOT NULL UNIQUE,   -- Tanda user id
  entity_id       INT NOT NULL DEFAULT 1,
  email           TEXT,
  full_name       TEXT,
  preferred_name  TEXT,
  active          BOOLEAN,
  hire_date       DATE,
  termination_date DATE,
  base_pay_rate   NUMERIC(10,4),
  pay_unit        TEXT,                      -- hour|week|year
  location_ids    INT[],
  department_ids  INT[],
  raw_payload     JSONB,
  last_synced_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_wf_users_email ON workforce_users (email);

CREATE TABLE workforce_locations (
  id              BIGSERIAL PRIMARY KEY,
  external_id     BIGINT NOT NULL UNIQUE,
  entity_id       INT NOT NULL DEFAULT 1,
  name            TEXT NOT NULL,
  raw_payload     JSONB,
  last_synced_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE workforce_shifts (
  id              BIGSERIAL PRIMARY KEY,
  external_id     BIGINT NOT NULL UNIQUE,
  entity_id       INT NOT NULL DEFAULT 1,
  user_external_id BIGINT,
  location_external_id BIGINT,
  department_external_id BIGINT,
  shift_date      DATE NOT NULL,
  start_time      TIMESTAMPTZ,
  end_time        TIMESTAMPTZ,
  break_minutes   INT,
  hours_worked    NUMERIC(6,3),
  cost_estimate   NUMERIC(10,2),             -- if provided
  status          TEXT,                      -- approved|pending|published
  raw_payload     JSONB,
  last_synced_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_wf_shifts_date ON workforce_shifts (shift_date, location_external_id);
CREATE INDEX idx_wf_shifts_user ON workforce_shifts (user_external_id, shift_date);

CREATE TABLE workforce_timesheets (
  id              BIGSERIAL PRIMARY KEY,
  external_id     BIGINT NOT NULL UNIQUE,
  entity_id       INT NOT NULL DEFAULT 1,
  user_external_id BIGINT,
  period_start    DATE,
  period_end      DATE,
  hours_total     NUMERIC(8,3),
  cost_total      NUMERIC(12,2),
  status          TEXT,                      -- finalised|draft|approved
  raw_payload     JSONB,
  last_synced_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_wf_ts_period ON workforce_timesheets (period_start, period_end);

CREATE TABLE workforce_wage_comparisons (
  id              BIGSERIAL PRIMARY KEY,
  external_id     BIGINT NOT NULL UNIQUE,
  entity_id       INT NOT NULL DEFAULT 1,
  location_external_id BIGINT,
  department_external_id BIGINT,
  period_date     DATE,
  scheduled_cost  NUMERIC(12,2),
  actual_cost     NUMERIC(12,2),
  sales_actual    NUMERIC(12,2),             -- comes from TouchOffice→Workforce
  sales_target    NUMERIC(12,2),
  labour_pct      NUMERIC(6,3),              -- actual_cost / sales_actual
  raw_payload     JSONB,
  last_synced_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_wf_wc_period ON workforce_wage_comparisons (period_date, location_external_id);

CREATE TABLE workforce_sync_log (
  id              BIGSERIAL PRIMARY KEY,
  entity_id       INT NOT NULL DEFAULT 1,
  endpoint        TEXT NOT NULL,
  query_params    JSONB,
  records_seen    INT,
  records_inserted INT,
  records_updated INT,
  http_status     INT,
  error_message   TEXT,
  runtime_ms      INT,
  started_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- RLS on all workforce_* tables
DO $$ DECLARE t TEXT;
BEGIN
  FOR t IN SELECT unnest(ARRAY['workforce_users','workforce_locations','workforce_shifts',
                               'workforce_timesheets','workforce_wage_comparisons','workforce_sync_log'])
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format($p$
      CREATE POLICY entity_isolation ON %I
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
          END)
    $p$, t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I TO homeai_pipeline', t);
    EXECUTE format('GRANT SELECT ON %I TO homeai_readonly', t);
  END LOOP;
END $$;

GRANT USAGE, SELECT ON
  workforce_users_id_seq, workforce_locations_id_seq, workforce_shifts_id_seq,
  workforce_timesheets_id_seq, workforce_wage_comparisons_id_seq, workforce_sync_log_id_seq
TO homeai_pipeline;
