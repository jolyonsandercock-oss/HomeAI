-- ============================================================
-- HOME AI SYSTEM — PostgreSQL Schema v4.0
-- Run: psql -U postgres -d homeai -f init-db.sql
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ── ENTITIES ─────────────────────────────────────────────────
CREATE TABLE entities (
  id   SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT,
  xero_org_id TEXT
);

-- ── EVENT STORE (partitioned by month) ───────────────────────
CREATE TABLE events (
  id                    BIGSERIAL,
  event_type            TEXT NOT NULL,
  source                TEXT NOT NULL,
  entity_id             INT REFERENCES entities(id),
  payload               JSONB NOT NULL,
  payload_signature     TEXT NOT NULL,
  status                TEXT DEFAULT 'pending',
  trace_id              UUID NOT NULL DEFAULT gen_random_uuid(),
  parent_event_id       BIGINT,
  idempotency_key       TEXT,
  retry_count           INT DEFAULT 0,
  error_message         TEXT,
  pipeline_version      TEXT,
  processing_started_at TIMESTAMPTZ,
  processing_node_id    TEXT,
  created_at            TIMESTAMPTZ DEFAULT NOW(),
  processed_at          TIMESTAMPTZ,
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

CREATE INDEX idx_events_type_status   ON events (event_type, status);
CREATE INDEX idx_events_trace         ON events (trace_id);
CREATE INDEX idx_events_parent        ON events (parent_event_id);
CREATE INDEX idx_events_entity        ON events (entity_id, status);
CREATE INDEX idx_events_idempotency   ON events (idempotency_key)
  WHERE idempotency_key IS NOT NULL;
CREATE INDEX idx_events_processing    ON events (status, processing_started_at)
  WHERE status = 'processing';

-- Initial partitions
CREATE TABLE events_2026_04 PARTITION OF events
  FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE events_2026_05 PARTITION OF events
  FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE events_2026_06 PARTITION OF events
  FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE events_overflow PARTITION OF events DEFAULT;

-- ── DEAD LETTER ───────────────────────────────────────────────
CREATE TABLE dead_letter (
  id               BIGSERIAL PRIMARY KEY,
  event_id         BIGINT,
  pipeline         TEXT NOT NULL,
  error_message    TEXT,
  payload          JSONB,
  retry_count      INT DEFAULT 3,
  created_at       TIMESTAMPTZ DEFAULT NOW(),
  resolved         BOOLEAN DEFAULT FALSE,
  resolved_at      TIMESTAMPTZ,
  resolution_notes TEXT
);

-- ── AUDIT LOG ─────────────────────────────────────────────────
CREATE TABLE audit_log (
  id               BIGSERIAL PRIMARY KEY,
  pipeline         TEXT NOT NULL,
  event_id         BIGINT,
  trace_id         UUID,
  action           TEXT NOT NULL,
  entity_id        INT REFERENCES entities(id),
  record_type      TEXT,
  record_id        BIGINT,
  ai_worker        TEXT,
  ai_model         TEXT,
  pipeline_version TEXT,
  ai_input_hash    TEXT,
  ai_raw_output    TEXT,
  ai_parsed        JSONB,
  result           TEXT,
  error_msg        TEXT,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_audit_pipeline ON audit_log (pipeline, created_at DESC);
CREATE INDEX idx_audit_result   ON audit_log (result, created_at DESC);

-- ── SECURITY AUDIT LOG (append-only) ─────────────────────────
CREATE TABLE security_audit_log (
  id             BIGSERIAL PRIMARY KEY,
  event_time     TIMESTAMPTZ DEFAULT NOW(),
  event_type     TEXT NOT NULL,
  source_service TEXT,
  source_ip      TEXT,
  secret_path    TEXT,
  pipeline       TEXT,
  entity_id      INT,
  details        JSONB,
  severity       TEXT DEFAULT 'info'
);

-- ── STATIC CONTEXT ────────────────────────────────────────────
CREATE TABLE static_context (
  key        TEXT PRIMARY KEY,
  entity_id  INT REFERENCES entities(id),
  value      JSONB NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Note: the previous AFTER UPDATE trigger (notify_context_change) was removed
-- in V4 — it was blocked by RLS and wrote an unsigned 'init_placeholder'
-- event, contradicting SPEC §2.2. Services that mutate static_context now
-- emit a properly HMAC-signed system.config_change event from app code.

-- ── EMAIL TABLES ──────────────────────────────────────────────
CREATE TABLE emails (
  id                BIGSERIAL PRIMARY KEY,
  gmail_message_id  TEXT UNIQUE NOT NULL,
  event_id          BIGINT,
  trace_id          UUID,
  account           TEXT NOT NULL,
  from_address      TEXT,
  from_name         TEXT,
  subject           TEXT,
  body_text         TEXT,
  body_text_safe    TEXT,
  received_at       TIMESTAMPTZ,
  classification    TEXT,
  confidence_score  DECIMAL(4,3),
  entity_id         INT REFERENCES entities(id),
  nanny_relevant    BOOLEAN DEFAULT FALSE,
  action_required   BOOLEAN DEFAULT FALSE,
  has_attachment    BOOLEAN DEFAULT FALSE,
  requires_human    BOOLEAN DEFAULT FALSE,
  processed         BOOLEAN DEFAULT FALSE
);

CREATE TABLE email_attachments (
  id             BIGSERIAL PRIMARY KEY,
  email_id       BIGINT REFERENCES emails(id),
  event_id       BIGINT,
  filename       TEXT,
  mime_type      TEXT,
  drive_url      TEXT,
  extracted_text TEXT,
  processed      BOOLEAN DEFAULT FALSE
);

-- ── INVOICE TABLES ────────────────────────────────────────────
CREATE TABLE invoices (
  id               BIGSERIAL PRIMARY KEY,
  idempotency_key  TEXT UNIQUE NOT NULL,
  event_id         BIGINT,
  trace_id         UUID,
  entity_id        INT REFERENCES entities(id),
  source           TEXT NOT NULL,
  supplier_name    TEXT,
  invoice_number   TEXT,
  invoice_date     DATE,
  due_date         DATE,
  gross_amount     DECIMAL(12,2),
  net_amount       DECIMAL(12,2),
  vat_amount       DECIMAL(12,2),
  currency         TEXT DEFAULT 'GBP',
  category         TEXT,
  status           TEXT DEFAULT 'pending',
  confidence_score DECIMAL(4,3),
  requires_human   BOOLEAN DEFAULT FALSE,
  anomaly_check    TEXT,
  anomaly_reason   TEXT,
  xero_invoice_id  TEXT,
  dext_document_id TEXT,
  drive_url        TEXT,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE supplier_invoice_history (
  id            BIGSERIAL PRIMARY KEY,
  entity_id     INT REFERENCES entities(id),
  supplier_name TEXT NOT NULL,
  invoice_month DATE NOT NULL,
  avg_gross     DECIMAL(12,2),
  min_gross     DECIMAL(12,2),
  max_gross     DECIMAL(12,2),
  invoice_count INT DEFAULT 1,
  updated_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (entity_id, supplier_name, invoice_month)
);
CREATE INDEX idx_supplier_hist ON supplier_invoice_history (entity_id, supplier_name);

-- ── BANK TABLES ───────────────────────────────────────────────
CREATE TABLE bank_accounts (
  id             SERIAL PRIMARY KEY,
  entity_id      INT REFERENCES entities(id),
  bank_name      TEXT,
  account_name   TEXT,
  account_number TEXT,
  sort_code      TEXT,
  account_type   TEXT
);

CREATE TABLE bank_transactions (
  id                  BIGSERIAL PRIMARY KEY,
  idempotency_key     TEXT UNIQUE NOT NULL,
  event_id            BIGINT,
  trace_id            UUID,
  bank_account_id     INT REFERENCES bank_accounts(id),
  entity_id           INT REFERENCES entities(id),
  transaction_date    DATE,
  description         TEXT,
  amount              DECIMAL(12,2),
  balance             DECIMAL(12,2),
  reference           TEXT,
  xero_transaction_id TEXT,
  reconciled          BOOLEAN DEFAULT FALSE,
  source              TEXT
);

CREATE TABLE reconciliation_flags (
  id                   BIGSERIAL PRIMARY KEY,
  event_id             BIGINT,
  entity_id            INT REFERENCES entities(id),
  bank_transaction_id  BIGINT REFERENCES bank_transactions(id),
  xero_transaction_id  TEXT,
  flag_type            TEXT,
  description          TEXT,
  status               TEXT DEFAULT 'open',
  created_at           TIMESTAMPTZ DEFAULT NOW()
);

-- ── PUB TABLES ────────────────────────────────────────────────
CREATE TABLE epos_daily_reports (
  id                  BIGSERIAL PRIMARY KEY,
  idempotency_key     TEXT UNIQUE NOT NULL,
  event_id            BIGINT,
  report_date         DATE NOT NULL,
  session             TEXT,
  gross_sales         DECIMAL(12,2),
  net_sales           DECIMAL(12,2),
  vat                 DECIMAL(12,2),
  cash_total          DECIMAL(12,2),
  card_total          DECIMAL(12,2),
  covers              INT,
  transactions        INT,
  avg_transaction     DECIMAL(8,2),
  voids               DECIMAL(12,2),
  refunds             DECIMAL(12,2),
  gratuities          DECIMAL(12,2),
  food_sales          DECIMAL(12,2),
  drink_sales         DECIMAL(12,2),
  accommodation_sales DECIMAL(12,2),
  source_email_id     BIGINT REFERENCES emails(id),
  created_at          TIMESTAMPTZ DEFAULT NOW(),
  entity_id           INT NOT NULL DEFAULT 1   -- placed after created_at to match the order PostgreSQL has in the live schema (column was added by an early ALTER TABLE)
);

CREATE TABLE till_reconciliation (
  id              BIGSERIAL PRIMARY KEY,
  idempotency_key TEXT UNIQUE NOT NULL,
  event_id        BIGINT,
  recon_date      DATE NOT NULL,
  session         TEXT,
  z_reading       DECIMAL(12,2),
  card_total      DECIMAL(12,2),
  float_returned  DECIMAL(12,2),
  cash_counted    DECIMAL(12,2),
  expected_cash   DECIMAL(12,2),
  variance        DECIMAL(12,2),
  variance_pct    DECIMAL(6,3),
  status          TEXT DEFAULT 'ok',
  staff_notes     TEXT,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  entity_id       INT NOT NULL DEFAULT 1   -- placed after created_at to match live schema
);

CREATE TABLE accommodation_daily_reports (
  id                    BIGSERIAL PRIMARY KEY,
  idempotency_key       TEXT UNIQUE NOT NULL,
  event_id              BIGINT,
  report_date           DATE NOT NULL,
  rooms_occupied        INT,
  total_rooms           INT,
  occupancy_pct         DECIMAL(5,2),
  arrivals              INT,
  departures            INT,
  room_revenue          DECIMAL(12,2),
  adr                   DECIMAL(10,2),
  revpar                DECIMAL(10,2),
  forward_7day_revenue  DECIMAL(12,2),
  forward_30day_revenue DECIMAL(12,2),
  source_email_id       BIGINT REFERENCES emails(id),
  created_at            TIMESTAMPTZ DEFAULT NOW(),
  entity_id             INT NOT NULL DEFAULT 1   -- placed after created_at to match live schema
);

-- ── PROPERTY TABLES ───────────────────────────────────────────
CREATE TABLE properties (
  id             SERIAL PRIMARY KEY,
  entity_id      INT REFERENCES entities(id),
  address_line1  TEXT,
  town           TEXT,
  postcode       TEXT,
  property_type  TEXT,
  purchase_date  DATE,
  purchase_price DECIMAL(12,2),
  current_value  DECIMAL(12,2)
);

CREATE TABLE tenancies (
  id            SERIAL PRIMARY KEY,
  property_id   INT REFERENCES properties(id),
  tenant_name   TEXT,
  tenant_email  TEXT,
  tenant_phone  TEXT,
  start_date    DATE,
  end_date      DATE,
  monthly_rent  DECIMAL(10,2),
  deposit       DECIMAL(10,2),
  status        TEXT DEFAULT 'active'
);

CREATE TABLE rent_payments (
  id                  BIGSERIAL PRIMARY KEY,
  tenancy_id          INT REFERENCES tenancies(id),
  event_id            BIGINT,
  expected_date       DATE,
  expected_amount     DECIMAL(10,2),
  received_date       DATE,
  received_amount     DECIMAL(10,2),
  bank_transaction_id BIGINT REFERENCES bank_transactions(id),
  status              TEXT DEFAULT 'pending'
);

CREATE TABLE property_compliance (
  id              BIGSERIAL PRIMARY KEY,
  property_id     INT REFERENCES properties(id),
  compliance_type TEXT,
  last_completed  DATE,
  expiry_date     DATE,
  document_id     BIGINT,
  status          TEXT DEFAULT 'current',
  alert_sent_90   BOOLEAN DEFAULT FALSE,
  alert_sent_60   BOOLEAN DEFAULT FALSE,
  alert_sent_30   BOOLEAN DEFAULT FALSE
);

-- ── FAMILY TABLES ─────────────────────────────────────────────
CREATE TABLE children (
  id                  SERIAL PRIMARY KEY,
  name                TEXT NOT NULL,
  date_of_birth       DATE,
  school_name         TEXT,
  school_email_domain TEXT,
  gp_name             TEXT,
  nhs_number          TEXT
);

CREATE TABLE child_events (
  id                BIGSERIAL PRIMARY KEY,
  idempotency_key   TEXT UNIQUE NOT NULL,
  event_id          BIGINT,
  trace_id          UUID,
  child_id          INT REFERENCES children(id),
  event_type        TEXT,
  event_date        DATE,
  deadline          DATE,
  urgency           INT DEFAULT 1,
  summary           TEXT,
  requires_human    BOOLEAN DEFAULT FALSE,
  source_email_id   BIGINT REFERENCES emails(id),
  calendar_event_id TEXT,
  status            TEXT DEFAULT 'pending'
);

CREATE TABLE medical_history (
  id              BIGSERIAL PRIMARY KEY,
  child_id        INT REFERENCES children(id),
  event_id        BIGINT,
  event_date      DATE,
  event_type      TEXT,
  practitioner    TEXT,
  notes           TEXT,
  source_email_id BIGINT REFERENCES emails(id)
);

-- ── HEALTH TABLES ─────────────────────────────────────────────
CREATE TABLE garmin_daily_summary (
  id                BIGSERIAL PRIMARY KEY,
  summary_date      DATE UNIQUE NOT NULL,
  steps             INT,
  active_calories   INT,
  body_battery_low  INT,
  body_battery_high INT,
  stress_avg        INT,
  hrv_weekly_avg    DECIMAL(6,2),
  resting_hr        INT
);

CREATE TABLE garmin_sleep (
  id                  BIGSERIAL PRIMARY KEY,
  sleep_date          DATE UNIQUE NOT NULL,
  total_sleep_seconds INT,
  deep_sleep_seconds  INT,
  rem_sleep_seconds   INT,
  sleep_score         INT,
  avg_hrv             DECIMAL(6,2)
);

CREATE TABLE garmin_body_metrics (
  id                  BIGSERIAL PRIMARY KEY,
  measure_date        DATE NOT NULL,
  weight_kg           DECIMAL(5,2),
  body_fat_pct        DECIMAL(5,2),
  muscle_mass_kg      DECIMAL(5,2),
  visceral_fat_rating INT
);

-- ── STAFF AND HR TABLES ───────────────────────────────────────
CREATE TABLE staff (
  id                      SERIAL PRIMARY KEY,
  entity_id               INT REFERENCES entities(id),
  first_name              TEXT NOT NULL,
  last_name               TEXT NOT NULL,
  ni_number               BYTEA,
  date_of_birth           DATE,
  address                 TEXT,
  email                   TEXT,
  phone                   TEXT,
  start_date              DATE,
  end_date                DATE,
  contract_type           TEXT,
  role                    TEXT,
  hourly_rate             DECIMAL(8,2),
  weekly_hours            DECIMAL(5,2),
  pay_frequency           TEXT DEFAULT 'weekly',
  right_to_work_type      TEXT,
  right_to_work_expiry    DATE,
  dbs_check_date          DATE,
  accommodation_deduction DECIMAL(8,2) DEFAULT 0,
  status                  TEXT DEFAULT 'active'
);

CREATE TABLE holiday_entitlement (
  id                 SERIAL PRIMARY KEY,
  staff_id           INT REFERENCES staff(id),
  holiday_year_start DATE,
  holiday_year_end   DATE,
  statutory_days     DECIMAL(5,2),
  contractual_days   DECIMAL(5,2),
  used_days          DECIMAL(5,2) DEFAULT 0,
  remaining_days     DECIMAL(5,2),
  accrual_method     TEXT DEFAULT 'fixed'
);

CREATE TABLE holiday_requests (
  id               BIGSERIAL PRIMARY KEY,
  staff_id         INT REFERENCES staff(id),
  requested_start  DATE,
  requested_end    DATE,
  days_requested   DECIMAL(5,2),
  status           TEXT DEFAULT 'pending',
  notes            TEXT,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE training_records (
  id             BIGSERIAL PRIMARY KEY,
  staff_id       INT REFERENCES staff(id),
  training_type  TEXT,
  mandatory      BOOLEAN DEFAULT TRUE,
  completed_date DATE,
  expiry_date    DATE,
  alert_sent_14  BOOLEAN DEFAULT FALSE,
  status         TEXT DEFAULT 'current'
);

-- ── DOCUMENT CONTROL ──────────────────────────────────────────
CREATE TABLE documents (
  id           BIGSERIAL PRIMARY KEY,
  entity_id    INT REFERENCES entities(id),
  category     TEXT,
  title        TEXT NOT NULL,
  version      TEXT DEFAULT '1.0',
  status       TEXT DEFAULT 'draft',
  owner        TEXT,
  drive_url    TEXT,
  review_date  DATE,
  expiry_date  DATE,
  access_level TEXT DEFAULT 'owner',
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  updated_at   TIMESTAMPTZ
);

CREATE TABLE document_versions (
  id           BIGSERIAL PRIMARY KEY,
  document_id  BIGINT REFERENCES documents(id),
  version      TEXT,
  drive_url    TEXT,
  changed_by   TEXT,
  change_notes TEXT,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

-- ── CASHFLOW ─────────────────────────────────────────────────
CREATE TABLE cashflow_forecast (
  id                 BIGSERIAL PRIMARY KEY,
  entity_id          INT REFERENCES entities(id),
  forecast_date      DATE NOT NULL,
  generated_at       TIMESTAMPTZ DEFAULT NOW(),
  opening_balance    DECIMAL(12,2),
  forecast_income    DECIMAL(12,2),
  forecast_expenses  DECIMAL(12,2),
  forecast_closing   DECIMAL(12,2),
  confirmed_income   DECIMAL(12,2),
  confirmed_expenses DECIMAL(12,2),
  period_days        INT DEFAULT 30
);

-- ── DIAGNOSTIC HISTORY ───────────────────────────────────────
CREATE TABLE diagnostic_history (
  id           BIGSERIAL PRIMARY KEY,
  run_id       UUID NOT NULL DEFAULT gen_random_uuid(),
  test_id      TEXT NOT NULL,
  status       TEXT NOT NULL,
  value        TEXT,
  detail       TEXT,
  duration_ms  INT,
  fix_applied  BOOLEAN DEFAULT FALSE,
  fix_result   TEXT,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_diag_run  ON diagnostic_history (run_id);
CREATE INDEX idx_diag_test ON diagnostic_history (test_id, created_at DESC);

-- ── MODEL STACK EVALUATOR TABLES ─────────────────────────────
CREATE TABLE model_registry (
  id              SERIAL PRIMARY KEY,
  model_name      TEXT UNIQUE NOT NULL,
  family          TEXT,
  params_b        DECIMAL(6,1),
  quantization    TEXT DEFAULT 'Q4_K_M',
  vram_gb         DECIMAL(5,2),
  ram_gb          DECIMAL(5,1),
  installed       BOOLEAN DEFAULT FALSE,
  deployed_tier   TEXT,
  ollama_digest   TEXT,
  discovered_at   TIMESTAMPTZ DEFAULT NOW(),
  last_seen_in_registry TIMESTAMPTZ,
  notes           TEXT
);

CREATE TABLE benchmark_results (
  id              BIGSERIAL PRIMARY KEY,
  model_name      TEXT NOT NULL REFERENCES model_registry(model_name),
  run_id          UUID NOT NULL DEFAULT gen_random_uuid(),
  run_at          TIMESTAMPTZ DEFAULT NOW(),
  tier            TEXT NOT NULL,
  task_id         TEXT NOT NULL,
  score           DECIMAL(5,2),
  speed_tps       DECIMAL(8,2),
  latency_ms      INT,
  input_tokens    INT,
  output_tokens   INT,
  passed          BOOLEAN,
  raw_output      TEXT,
  error_message   TEXT,
  UNIQUE (model_name, run_id, task_id)
);
CREATE INDEX idx_bench_model ON benchmark_results (model_name, tier, run_at DESC);

CREATE TABLE model_scores (
  id              BIGSERIAL PRIMARY KEY,
  model_name      TEXT NOT NULL REFERENCES model_registry(model_name),
  scored_at       TIMESTAMPTZ DEFAULT NOW(),
  score_date      DATE NOT NULL DEFAULT CURRENT_DATE,
  tier            TEXT NOT NULL,
  composite_score DECIMAL(5,2),
  accuracy_score  DECIMAL(5,2),
  speed_score     DECIMAL(5,2),
  format_score    DECIMAL(5,2),
  avg_speed_tps   DECIMAL(8,2),
  avg_latency_ms  INT,
  task_count      INT,
  UNIQUE (model_name, tier, score_date)
);

CREATE TABLE model_recommendations (
  id                BIGSERIAL PRIMARY KEY,
  generated_at      TIMESTAMPTZ DEFAULT NOW(),
  tier              TEXT NOT NULL,
  action            TEXT NOT NULL,
  recommended_model TEXT REFERENCES model_registry(model_name),
  current_model     TEXT REFERENCES model_registry(model_name),
  composite_delta   DECIMAL(6,2),
  speed_delta_pct   DECIMAL(8,2),
  accuracy_delta_pct DECIMAL(6,2),
  reasoning         TEXT,
  confidence        DECIMAL(4,3),
  actioned          BOOLEAN DEFAULT FALSE,
  actioned_at       TIMESTAMPTZ,
  actioned_by       TEXT
);
CREATE INDEX idx_recs_active ON model_recommendations (tier, generated_at DESC)
  WHERE actioned = FALSE;

CREATE TABLE model_scan_log (
  id            BIGSERIAL PRIMARY KEY,
  scanned_at    TIMESTAMPTZ DEFAULT NOW(),
  models_found  INT,
  new_models    TEXT[],
  updated_models TEXT[],
  scan_source   TEXT DEFAULT 'ollama_library'
);

-- ── ENTITY SEED DATA ─────────────────────────────────────────
INSERT INTO entities (id, name, type) VALUES
  (1, 'Atlantic Road Trading Ltd', 'company'),
  (2, 'Atlantic Road Estates Limited', 'company'),
  (3, 'Personal', 'personal'),
  (4, 'Family', 'family');
