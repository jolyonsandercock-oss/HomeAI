-- ============================================================
-- U32 — till_reconciliation: per-day cash-up vs Z-reading
-- ============================================================
-- Drives the SPEC §App-C variance check (>£5 → flag, >0.5% of revenue → flag).
-- Source: 2026CashUp Google Sheet, weekly-block layout (parser in
-- scripts/u32-cashing-up-parser.sh).
-- ============================================================

CREATE TABLE till_reconciliation (
  id                BIGSERIAL PRIMARY KEY,
  idempotency_key   TEXT NOT NULL UNIQUE,
  entity_id         INT NOT NULL DEFAULT 1,
  report_date       DATE NOT NULL,
  manager_name      TEXT,
  -- From the cashing-up sheet
  opening_cash      NUMERIC(10,2),
  expected_opening  NUMERIC(10,2),
  drawer_error      NUMERIC(10,2),               -- positive = over, negative = short
  closing_cash      NUMERIC(10,2),
  -- From TouchOffice (joined at parse time, mirrored here for replay)
  z_reading_net     NUMERIC(10,2),
  z_reading_gross   NUMERIC(10,2),
  -- Computed
  variance_gbp      NUMERIC(10,2),                -- drawer_error (mirrored or computed)
  variance_pct      NUMERIC(8,3),                 -- drawer_error / z_reading_net * 100
  status            TEXT NOT NULL DEFAULT 'open'
                    CHECK (status IN ('open','ok','flagged','resolved')),
  flag_reason       TEXT,
  alert_sent_at     TIMESTAMPTZ,
  raw_row_block     JSONB,                        -- which sheet block + day column
  source_sheet_id   TEXT,
  ingested_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (report_date)
);
CREATE INDEX idx_till_status_date ON till_reconciliation (status, report_date DESC);

ALTER TABLE till_reconciliation ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON till_reconciliation
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

GRANT SELECT, INSERT, UPDATE, DELETE ON till_reconciliation TO homeai_pipeline;
GRANT USAGE, SELECT ON till_reconciliation_id_seq TO homeai_pipeline;
GRANT SELECT, UPDATE ON till_reconciliation TO homeai_readonly;
