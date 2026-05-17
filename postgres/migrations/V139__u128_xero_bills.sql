-- =============================================================================
-- V139 — U128: Xero bills ingest schema
-- =============================================================================
-- One row per Xero bill in xero_bills, one row per line item in xero_bill_lines.
-- vendor_invoice_inbox gains xero_bill_id (the reverse link) and
-- forwarded_to_dext_at (set when an orphan email is forwarded to Dext).
--
-- Source CSV: Xero export "Bills_<TenantName>_<YYYY-MMM-DD.HH.MM.SS>.csv".
-- The CSV explodes bill+line into N rows; the parser collapses on
-- (ContactName, InvoiceNumber, InvoiceDate, Total) to xero_bills.id.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

CREATE TABLE IF NOT EXISTS xero_bills (
  id              BIGSERIAL PRIMARY KEY,
  realm           TEXT NOT NULL DEFAULT 'owner',
  entity_id       INTEGER REFERENCES entities(id),
  contact_name    TEXT NOT NULL,
  invoice_number  TEXT NOT NULL,
  reference       TEXT,
  invoice_date    DATE NOT NULL,
  due_date        DATE,
  planned_date    DATE,
  total           NUMERIC(12,2),
  tax_total       NUMERIC(12,2),
  amount_paid     NUMERIC(12,2),
  amount_due      NUMERIC(12,2),
  currency        TEXT,
  type            TEXT,
  sent            TEXT,
  status          TEXT,
  source_csv      TEXT,
  ingested_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  raw_payload     JSONB,
  UNIQUE (contact_name, invoice_number, invoice_date)
);

CREATE INDEX IF NOT EXISTS idx_xero_bills_invoice_date ON xero_bills(invoice_date DESC);
CREATE INDEX IF NOT EXISTS idx_xero_bills_contact      ON xero_bills(contact_name);
CREATE INDEX IF NOT EXISTS idx_xero_bills_status       ON xero_bills(status);

CREATE TABLE IF NOT EXISTS xero_bill_lines (
  id                BIGSERIAL PRIMARY KEY,
  xero_bill_id      BIGINT NOT NULL REFERENCES xero_bills(id) ON DELETE CASCADE,
  realm             TEXT NOT NULL DEFAULT 'owner',
  line_no           INTEGER NOT NULL,
  inventory_code    TEXT,
  description       TEXT,
  quantity          NUMERIC(14,4),
  unit_amount       NUMERIC(14,4),
  discount          NUMERIC(14,4),
  line_amount       NUMERIC(14,4),
  account_code      TEXT,
  tax_type          TEXT,
  tax_amount        NUMERIC(14,4),
  tracking_name_1   TEXT,
  tracking_option_1 TEXT,
  tracking_name_2   TEXT,
  tracking_option_2 TEXT,
  UNIQUE (xero_bill_id, line_no)
);

CREATE INDEX IF NOT EXISTS idx_xero_bill_lines_account ON xero_bill_lines(account_code);
CREATE INDEX IF NOT EXISTS idx_xero_bill_lines_tag1    ON xero_bill_lines(tracking_option_1);

-- RLS — same pattern as vendor_invoice_inbox: realm-scoped via app.current_realm.
ALTER TABLE xero_bills      ENABLE ROW LEVEL SECURITY;
ALTER TABLE xero_bill_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS xero_bills_realm_read   ON xero_bills;
DROP POLICY IF EXISTS xero_bills_realm_write  ON xero_bills;
CREATE POLICY xero_bills_realm_read  ON xero_bills FOR SELECT
  USING (realm = current_setting('app.current_realm', true) OR current_setting('app.current_realm', true) = 'owner');
CREATE POLICY xero_bills_realm_write ON xero_bills FOR ALL
  USING (current_setting('app.current_realm', true) = 'owner')
  WITH CHECK (current_setting('app.current_realm', true) = 'owner');

DROP POLICY IF EXISTS xero_bill_lines_realm_read  ON xero_bill_lines;
DROP POLICY IF EXISTS xero_bill_lines_realm_write ON xero_bill_lines;
CREATE POLICY xero_bill_lines_realm_read  ON xero_bill_lines FOR SELECT
  USING (realm = current_setting('app.current_realm', true) OR current_setting('app.current_realm', true) = 'owner');
CREATE POLICY xero_bill_lines_realm_write ON xero_bill_lines FOR ALL
  USING (current_setting('app.current_realm', true) = 'owner')
  WITH CHECK (current_setting('app.current_realm', true) = 'owner');

GRANT SELECT ON xero_bills, xero_bill_lines TO homeai_readonly;

-- Reverse link from inbox + forwarded marker
ALTER TABLE vendor_invoice_inbox
  ADD COLUMN IF NOT EXISTS xero_bill_id          BIGINT REFERENCES xero_bills(id),
  ADD COLUMN IF NOT EXISTS forwarded_to_dext_at  TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_inbox_xero_bill_id ON vendor_invoice_inbox(xero_bill_id);
CREATE INDEX IF NOT EXISTS idx_inbox_no_xero      ON vendor_invoice_inbox(invoice_date DESC) WHERE xero_bill_id IS NULL;

-- Convenience view: bills with line-item rollup
CREATE OR REPLACE VIEW v_xero_bills AS
SELECT b.id, b.realm, b.contact_name, b.invoice_number, b.invoice_date,
       b.total, b.tax_total, b.amount_paid, b.amount_due, b.status, b.currency,
       COUNT(l.id) AS line_count,
       STRING_AGG(DISTINCT l.account_code, ', ' ORDER BY l.account_code) AS account_codes,
       STRING_AGG(DISTINCT l.tracking_option_1, ', ' ORDER BY l.tracking_option_1) AS tracking_codes
  FROM xero_bills b
  LEFT JOIN xero_bill_lines l ON l.xero_bill_id = b.id
 GROUP BY b.id;

GRANT SELECT ON v_xero_bills TO homeai_readonly;

-- Orphan view: inbox rows that haven't matched a Xero bill
CREATE OR REPLACE VIEW v_xero_orphan_inbox AS
SELECT i.id AS inbox_id, i.vendor_name, i.invoice_date,
       i.gross_amount, i.amount_seen, i.account,
       i.source_email_id, i.received_at, i.first_attachment_path,
       i.forwarded_to_dext_at,
       (CURRENT_DATE - i.invoice_date::date) AS age_days,
       CASE WHEN i.invoice_date < CURRENT_DATE - 7 AND i.forwarded_to_dext_at IS NULL
            THEN true ELSE false END AS needs_forward
  FROM vendor_invoice_inbox i
 WHERE i.xero_bill_id IS NULL
   AND i.invoice_date IS NOT NULL
   AND i.invoice_date >= CURRENT_DATE - 365;

GRANT SELECT ON v_xero_orphan_inbox TO homeai_readonly;

COMMENT ON TABLE  xero_bills           IS 'U128 V139. Xero Bills export rows, one per bill.';
COMMENT ON TABLE  xero_bill_lines      IS 'U128 V139. Xero bill line items, one per CSV row.';
COMMENT ON COLUMN vendor_invoice_inbox.xero_bill_id         IS 'U128 V139. NULL => no Xero match yet (potential orphan).';
COMMENT ON COLUMN vendor_invoice_inbox.forwarded_to_dext_at IS 'U128 V139. Set when orphan email was auto-forwarded to malthousepub@dext.cc.';

COMMIT;
