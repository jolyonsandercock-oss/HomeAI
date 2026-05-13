-- ============================================================
-- U42 — VAT Return Preparation Workflow (DORMANT)
-- SPEC §7.7
-- ============================================================
-- Quarterly Xero query → pre-filled Box 1-9 → anomaly flags →
-- Action Queue. Gated on system_state.p3_xero = 'live'.
-- Built now; activates automatically when Xero unblocks.
-- ============================================================

-- system_state: simple key/value gate table for dormant features.
CREATE TABLE IF NOT EXISTS system_state (
  key         TEXT PRIMARY KEY,
  value       TEXT NOT NULL,
  notes       TEXT,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO system_state (key, value, notes) VALUES
  ('p3_xero', 'parked', 'Xero OAuth blocked on Xero support reply. Set to ''live'' when unblocked to activate u42-vat-return-prep.')
ON CONFLICT (key) DO NOTHING;

GRANT SELECT ON system_state TO homeai_pipeline;
GRANT UPDATE, INSERT ON system_state TO homeai_pipeline;
GRANT SELECT ON system_state TO homeai_readonly;
GRANT SELECT ON system_state TO metabase_app;

-- vat_returns_log
CREATE TABLE IF NOT EXISTS vat_returns_log (
  id                       BIGSERIAL PRIMARY KEY,
  entity_id                INT NOT NULL DEFAULT 1 REFERENCES entities(id),
  quarter_end              DATE NOT NULL,
  box_1                    NUMERIC(12,2),   -- VAT due on sales/other outputs
  box_2                    NUMERIC(12,2),   -- VAT due on acquisitions from other EC member states
  box_3                    NUMERIC(12,2),   -- Total VAT due (1 + 2)
  box_4                    NUMERIC(12,2),   -- VAT reclaimed on purchases (input tax)
  box_5                    NUMERIC(12,2),   -- Net VAT to pay HMRC (3 - 4)
  box_6                    NUMERIC(12,2),   -- Total net value of sales (excluding VAT)
  box_7                    NUMERIC(12,2),   -- Total net value of purchases (excluding VAT)
  box_8                    NUMERIC(12,2),   -- Total net value of supplies to other EC member states
  box_9                    NUMERIC(12,2),   -- Total net value of acquisitions from other EC member states
  anomalies                JSONB DEFAULT '[]'::jsonb,
  status                   TEXT NOT NULL DEFAULT 'draft'
                           CHECK (status IN ('draft', 'reviewed', 'filed')),
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  accountant_reviewed_at   TIMESTAMPTZ,
  filed_at                 TIMESTAMPTZ,
  UNIQUE (entity_id, quarter_end)
);

CREATE INDEX IF NOT EXISTS idx_vrl_status ON vat_returns_log (status, quarter_end DESC);

ALTER TABLE vat_returns_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON vat_returns_log
  USING (
    CASE WHEN current_setting('app.current_entity', true) = 'all' THEN true
         WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN entity_id = current_setting('app.current_entity', true)::int
         ELSE false
    END);

GRANT SELECT, INSERT, UPDATE ON vat_returns_log TO homeai_pipeline;
GRANT SELECT ON vat_returns_log TO homeai_readonly;
GRANT SELECT ON vat_returns_log TO metabase_app;
GRANT USAGE, SELECT ON SEQUENCE vat_returns_log_id_seq TO homeai_pipeline;

COMMENT ON TABLE vat_returns_log IS
  'U42 — quarterly pre-filled UK VAT return (Box 1-9). Dormant until system_state.p3_xero=''live''. Jo files manually in Xero — this just pre-checks the figures.';
