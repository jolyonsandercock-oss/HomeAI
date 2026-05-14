-- V68: Dojo card-machine transactions master table.
--
-- Realm: work (pub + cafe = entity 1 = ARTL).
-- Source: Dojo "Transactions" CSV export (manual download by Jo).
-- Idempotency: `transaction_id` is Dojo's per-txn UUID, guaranteed unique.
--
-- Reconciliation expectations (future, not yet wired):
--   - daily Dojo gross (sales + tips − refunds) per site joins to
--     touchoffice_fixed_totals (label = 'Card' tender) and to
--     caterbook_room_nights (room-charge component) on (date, site).
--   - mismatches > £1 → reconciliation_flags row.
--
-- This migration sets up only the master table, RLS, the canonical view
-- (`v_dojo_daily`), and a few indexes the reconciliation queries will
-- need. The importer is `scripts/dojo-import.py` (run by hand or via
-- a cron once Jo settles a cadence).

BEGIN;

-- ── 1. Master table ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS dojo_transactions (
    id                          BIGSERIAL PRIMARY KEY,
    transaction_id              TEXT NOT NULL UNIQUE,
    -- Site routing — derived from MID, validated against allowlist.
    mid                         TEXT NOT NULL,
    site                        TEXT NOT NULL CHECK (site IN ('pub','cafe','unknown')),
    address                     TEXT NOT NULL,
    location                    TEXT,
    -- When the txn happened (card-machine local time = Europe/London).
    transaction_date            DATE NOT NULL,
    transaction_time            TIME NOT NULL,
    transaction_at              TIMESTAMPTZ GENERATED ALWAYS AS
        ((transaction_date + transaction_time) AT TIME ZONE 'Europe/London') STORED,
    -- Money. Refunds are stored signed-negative as Dojo provides them.
    transaction_type            TEXT NOT NULL,
    transaction_outcome         TEXT NOT NULL,
    currency                    TEXT NOT NULL DEFAULT 'GBP',
    transaction_amount          NUMERIC(12,2),
    cashback_amount             NUMERIC(12,2),
    donation_amount             NUMERIC(12,2),
    gratuity_amount             NUMERIC(12,2),
    cardholder_currency         TEXT,
    cardholder_amount           NUMERIC(12,2),
    exchange_rate               NUMERIC(14,6),
    -- Card / payment metadata.
    authorisation_code          TEXT,
    source                      TEXT,
    merchant_order_number       TEXT,
    payment_method              TEXT,
    card_number_masked          TEXT,
    card_type                   TEXT,
    card_scheme                 TEXT,
    card_level                  TEXT,
    card_machine_serial         TEXT,
    card_machine_name           TEXT,
    card_machine_id             TEXT,
    remote_id                   TEXT,
    -- Charges. Dojo VAT-applies these on a delayed schedule.
    total_transaction_charge    NUMERIC(12,4),
    card_transaction_charge     NUMERIC(12,4),
    secure_transaction_charge   NUMERIC(12,4),
    authorisation_fee           NUMERIC(12,4),
    refund_fee                  NUMERIC(12,4),
    fee_vat                     NUMERIC(12,4),
    refund_reason               TEXT,
    notes                       TEXT,
    -- Forensics: keep the raw row so re-parses don't need the CSV.
    raw_row                     JSONB NOT NULL,
    -- Plumbing.
    entity_id                   INTEGER NOT NULL DEFAULT 1
        REFERENCES entities(id),
    realm                       TEXT NOT NULL DEFAULT 'work'
        CHECK (realm IN ('owner','work','family','shared')),
    imported_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    import_source               TEXT
);

CREATE INDEX IF NOT EXISTS idx_dojo_txn_date_site
    ON dojo_transactions (transaction_date, site);
CREATE INDEX IF NOT EXISTS idx_dojo_txn_at
    ON dojo_transactions (transaction_at);
CREATE INDEX IF NOT EXISTS idx_dojo_txn_realm
    ON dojo_transactions (realm);
CREATE INDEX IF NOT EXISTS idx_dojo_txn_outcome
    ON dojo_transactions (transaction_outcome, transaction_type);

-- ── 2. RLS — entity + realm, same pattern as V65 ───────────────────
ALTER TABLE dojo_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS entity_isolation ON dojo_transactions;
CREATE POLICY entity_isolation ON dojo_transactions
  USING (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all' THEN TRUE
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'
           THEN entity_id = current_setting('app.current_entity', true)::integer
      ELSE FALSE
    END);

DROP POLICY IF EXISTS realm_isolation ON dojo_transactions;
CREATE POLICY realm_isolation ON dojo_transactions AS RESTRICTIVE FOR ALL
  USING (
    CASE
      WHEN current_setting('app.current_realm', true) = 'owner' THEN TRUE
      WHEN current_setting('app.current_realm', true) IN ('work','family')
           THEN realm = current_setting('app.current_realm', true)
                OR realm = 'shared'
      WHEN current_setting('app.current_realm', true) IS NULL
        OR current_setting('app.current_realm', true) = ''
           THEN TRUE
      ELSE FALSE
    END);

GRANT SELECT, INSERT, UPDATE ON dojo_transactions TO homeai_pipeline;
GRANT USAGE ON SEQUENCE dojo_transactions_id_seq TO homeai_pipeline;
GRANT SELECT ON dojo_transactions TO homeai_readonly;

-- ── 3. Canonical daily view ────────────────────────────────────────
-- Authorised-only money, signed (refunds negative). Use this view as
-- the source of truth for any dashboard or reconciliation read.
DROP VIEW IF EXISTS v_dojo_daily CASCADE;
CREATE VIEW v_dojo_daily AS
SELECT
    transaction_date                                          AS date,
    site,
    COUNT(*) FILTER (WHERE transaction_type='Sale'
                       AND transaction_outcome='Authorised')  AS sales_count,
    COUNT(*) FILTER (WHERE transaction_type='Refund'
                       AND transaction_outcome='Authorised')  AS refund_count,
    COUNT(*) FILTER (WHERE transaction_outcome='Declined')    AS declined_count,
    COALESCE(SUM(transaction_amount)
        FILTER (WHERE transaction_type='Sale'
                  AND transaction_outcome='Authorised'),0)    AS gross_sales,
    COALESCE(SUM(transaction_amount)
        FILTER (WHERE transaction_type='Refund'
                  AND transaction_outcome='Authorised'),0)    AS refunds,
    COALESCE(SUM(gratuity_amount)
        FILTER (WHERE transaction_type='Sale'
                  AND transaction_outcome='Authorised'),0)    AS tips,
    COALESCE(SUM(cashback_amount)
        FILTER (WHERE transaction_type='Sale'
                  AND transaction_outcome='Authorised'),0)    AS cashback,
    COALESCE(SUM(total_transaction_charge),0)                 AS dojo_charges,
    COALESCE(SUM(fee_vat),0)                                  AS fee_vat,
    COALESCE(SUM(transaction_amount)
        FILTER (WHERE transaction_outcome='Authorised'),0)
      + COALESCE(SUM(gratuity_amount)
        FILTER (WHERE transaction_type='Sale'
                  AND transaction_outcome='Authorised'),0)
      - COALESCE(SUM(cashback_amount)
        FILTER (WHERE transaction_type='Sale'
                  AND transaction_outcome='Authorised'),0)
      - COALESCE(SUM(total_transaction_charge),0)             AS net_to_bank
FROM dojo_transactions
GROUP BY transaction_date, site;

GRANT SELECT ON v_dojo_daily TO homeai_pipeline, homeai_readonly;

COMMENT ON TABLE  dojo_transactions IS
    'Card-machine transactions imported from Dojo CSV. WORK realm. PK = Dojo transaction_id (UUID). Append-by-upsert via scripts/dojo-import.py.';
COMMENT ON COLUMN dojo_transactions.site IS
    'Derived from MID at import: 476621462111863=pub, 146184234181151=cafe. Anything else = unknown (importer raises).';
COMMENT ON VIEW   v_dojo_daily IS
    'Daily authorised-only Dojo totals per site. Source of truth for dashboard /api/dojo/daily and future reconciliation against TouchOffice card tender.';

COMMIT;
