-- V61: audit log for due_date Haiku extractions (T3 of U50).
BEGIN;

CREATE TABLE IF NOT EXISTS due_date_extractions (
  id              BIGSERIAL PRIMARY KEY,
  invoice_id      BIGINT NOT NULL REFERENCES vendor_invoice_inbox(id) ON DELETE CASCADE,
  source          TEXT NOT NULL CHECK (source IN ('stated','computed','absent','error')),
  due_date        DATE,
  confidence      NUMERIC(4,3),
  text_snippet    TEXT,
  model           TEXT NOT NULL DEFAULT 'claude-haiku-4-5-20251001',
  raw_response    JSONB,
  extracted_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  entity_id       INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_dde_invoice ON due_date_extractions(invoice_id);

ALTER TABLE due_date_extractions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS entity_isolation ON due_date_extractions;
CREATE POLICY entity_isolation ON due_date_extractions
  USING (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all' THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'
        THEN entity_id = current_setting('app.current_entity', true)::integer
      ELSE false
    END);

COMMIT;
