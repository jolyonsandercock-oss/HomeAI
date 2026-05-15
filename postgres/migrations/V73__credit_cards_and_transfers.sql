-- =============================================================================
-- V73 — Credit-card accounts, statements + inter-account transfer linkage
-- =============================================================================
-- Adds:
--   * bank_accounts.account_type CHECK extended to include 'credit_card'
--   * card_statements — one row per credit-card billing cycle
--   * account_transfers — pair-linked txns across Jo's accounts (incl. cards)
--   * Seed rules in bank_transaction_rules for RBS Mastercard CSV semantics
--   * v_card_statements_summary, v_card_fees_interest_by_month,
--     v_account_transfers_open
--
-- Source data: 3 RBS Mastercards owned by Jo personally
--   552085******8864, 552085******2621, 552085******3092
--   All entity_id=3 (Personal), realm=family.
--
-- Idempotent: every CREATE uses IF NOT EXISTS; ALTERs are guarded.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Constrain bank_accounts.account_type. credit_card joins current/savings/joint.
-- -----------------------------------------------------------------------------

ALTER TABLE bank_accounts DROP CONSTRAINT IF EXISTS bank_accounts_account_type_check;
ALTER TABLE bank_accounts ADD CONSTRAINT bank_accounts_account_type_check
    CHECK (account_type IN ('current','savings','joint','credit_card'));

-- -----------------------------------------------------------------------------
-- 2. card_statements — one row per (card, statement_date)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS card_statements (
    id                    BIGSERIAL PRIMARY KEY,
    bank_account_id       INTEGER     NOT NULL REFERENCES bank_accounts(id),
    entity_id             INTEGER     NOT NULL REFERENCES entities(id),
    realm                 TEXT        NOT NULL,
    statement_date        DATE        NOT NULL,
    period_start          DATE        NOT NULL,
    period_end            DATE        NOT NULL,
    opening_balance       NUMERIC(12,2),
    payments_credited     NUMERIC(12,2),
    spending_charged      NUMERIC(12,2),
    interest_charged      NUMERIC(12,2),
    fees_charged          NUMERIC(12,2),
    closing_balance       NUMERIC(12,2),
    min_payment           NUMERIC(12,2),
    min_payment_due_date  DATE,
    credit_limit          NUMERIC(12,2),
    source_pdf_path       TEXT        NOT NULL,
    pdf_sha256            TEXT        NOT NULL,
    raw_text              TEXT,
    extraction_confidence NUMERIC(4,3),
    extracted_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (bank_account_id, statement_date)
);

ALTER TABLE card_statements DROP CONSTRAINT IF EXISTS card_statements_realm_check;
ALTER TABLE card_statements ADD CONSTRAINT card_statements_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

CREATE INDEX IF NOT EXISTS idx_card_stmt_period
    ON card_statements (bank_account_id, statement_date DESC);

-- Mirror the RLS pattern used by bank_accounts + bank_transactions.
ALTER TABLE card_statements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS entity_isolation ON card_statements;
CREATE POLICY entity_isolation ON card_statements
    USING (
        CASE
            WHEN current_setting('app.current_entity', true) = 'all' THEN true
            WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN
                entity_id = current_setting('app.current_entity', true)::int
            ELSE false
        END
    )
    WITH CHECK (
        CASE
            WHEN current_setting('app.current_entity', true) = 'all' THEN true
            WHEN current_setting('app.current_entity', true) ~ '^\d+$' THEN
                entity_id = current_setting('app.current_entity', true)::int
            ELSE false
        END
    );

DROP POLICY IF EXISTS realm_isolation ON card_statements;
CREATE POLICY realm_isolation ON card_statements AS RESTRICTIVE
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

DROP TRIGGER IF EXISTS trg_card_statements_realm ON card_statements;
CREATE TRIGGER trg_card_statements_realm
    BEFORE INSERT ON card_statements
    FOR EACH ROW EXECUTE FUNCTION trg_set_realm_from_entity_id();

-- -----------------------------------------------------------------------------
-- 3. account_transfers — pair-linked txns spanning bank_accounts
--    src = money leaves this txn's account; dst = money lands in this one.
--    e.g. NatWest current → Mastercard DD payment links a debit-side
--    bank_transactions row to the corresponding credit-side bank_transactions
--    row on the credit-card account.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS account_transfers (
    id                BIGSERIAL PRIMARY KEY,
    src_txn_id        BIGINT      NOT NULL REFERENCES bank_transactions(id),
    dst_txn_id        BIGINT      NOT NULL REFERENCES bank_transactions(id),
    amount            NUMERIC(12,2) NOT NULL,
    transfer_date     DATE        NOT NULL,
    realm             TEXT        NOT NULL,
    detection_method  TEXT        NOT NULL,
    confidence        NUMERIC(4,3) NOT NULL DEFAULT 0.80,
    notes             TEXT,
    detected_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (src_txn_id, dst_txn_id),
    CHECK (src_txn_id <> dst_txn_id)
);

ALTER TABLE account_transfers DROP CONSTRAINT IF EXISTS account_transfers_realm_check;
ALTER TABLE account_transfers ADD CONSTRAINT account_transfers_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

ALTER TABLE account_transfers DROP CONSTRAINT IF EXISTS account_transfers_method_check;
ALTER TABLE account_transfers ADD CONSTRAINT account_transfers_method_check
    CHECK (detection_method IN (
        'amount_date_match',   -- ±amount within ±N days
        'narrative_hint',      -- description text references the other account
        'manual',              -- Jo confirmed via UI
        'rule'                 -- explicit deterministic rule (e.g. statement DD)
    ));

CREATE INDEX IF NOT EXISTS idx_atx_date ON account_transfers (transfer_date DESC);
CREATE INDEX IF NOT EXISTS idx_atx_src  ON account_transfers (src_txn_id);
CREATE INDEX IF NOT EXISTS idx_atx_dst  ON account_transfers (dst_txn_id);

-- -----------------------------------------------------------------------------
-- 4. CC-specific categorisation rules
--    Applied at import-time + by the broader categoriser. Priority 10-15 so
--    they outrank the generic "Direct debit" type rule.
-- -----------------------------------------------------------------------------

INSERT INTO bank_transaction_rules
    (priority, name, description_re, type_in, amount_op, amount_value, category, confidence, notes)
VALUES
    (10, 'CC interest charged',       '^INTEREST - SEE SUMMARY$',
        NULL, NULL, NULL, 'interest_charged', 0.99,
        'RBS Mastercard CSV: interest line'),
    (10, 'CC non-sterling fee',       '^NON-STERLING TRANSACTION$',
        NULL, NULL, NULL, 'bank_fee', 0.99,
        'RBS Mastercard CSV: FX fee'),
    (10, 'CC small balance write-off','^SMALL BALANCE WRITE OFF$',
        NULL, NULL, NULL, 'refund', 0.99,
        'RBS Mastercard CSV: clears tiny residual'),
    (12, 'CC direct-debit payment',   '^DIRECT DEBIT PAYMENT',
        NULL, '<', 0, 'inter_entity_transfer', 0.92,
        'RBS Mastercard CSV: monthly DD paid from a NatWest current account'),
    (12, 'CC faster-payment received','^FASTER PAYMENT RECEIVED',
        NULL, '<', 0, 'inter_entity_transfer', 0.92,
        'RBS Mastercard CSV: ad-hoc transfer in from a NatWest account'),
    (15, 'CC fee (catch-all)',        NULL,
        ARRAY['FEES'], NULL, NULL, 'bank_fee', 0.95,
        'RBS Mastercard CSV: any FEES type not matched above'),
    (15, 'CC purchase (catch-all)',   NULL,
        ARRAY['PURCHASE'], '>', 0, 'vendor_payment', 0.80,
        'RBS Mastercard CSV: positive PURCHASE = real spend'),
    (15, 'CC purchase refund',        NULL,
        ARRAY['PURCHASE'], '<', 0, 'refund', 0.85,
        'RBS Mastercard CSV: negative PURCHASE = merchant refund')
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- 5. Roll-up views
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_card_statements_summary AS
SELECT
    cs.id                   AS statement_id,
    ba.id                   AS bank_account_id,
    ba.account_name,
    ba.account_number,
    cs.entity_id,
    cs.realm,
    cs.statement_date,
    cs.period_start,
    cs.period_end,
    cs.opening_balance,
    cs.payments_credited,
    cs.spending_charged,
    cs.interest_charged,
    cs.fees_charged,
    cs.closing_balance,
    cs.min_payment,
    cs.min_payment_due_date,
    cs.credit_limit,
    cs.closing_balance - cs.opening_balance AS net_period_movement
  FROM card_statements cs
  JOIN bank_accounts ba ON ba.id = cs.bank_account_id
 WHERE ba.account_type = 'credit_card'
 ORDER BY ba.id, cs.statement_date DESC;

COMMENT ON VIEW v_card_statements_summary IS
    'One row per credit-card billing cycle with the headline numbers.';

CREATE OR REPLACE VIEW v_card_fees_interest_by_month AS
SELECT
    ba.id           AS bank_account_id,
    ba.account_name,
    ba.entity_id,
    ba.realm,
    DATE_TRUNC('month', bt.transaction_date)::date AS month,
    SUM(CASE WHEN bt.category = 'interest_charged' THEN bt.amount ELSE 0 END)::numeric(12,2) AS interest_charged,
    SUM(CASE WHEN bt.category = 'bank_fee'         THEN bt.amount ELSE 0 END)::numeric(12,2) AS fees_charged,
    COUNT(*) FILTER (WHERE bt.category = 'interest_charged') AS interest_events,
    COUNT(*) FILTER (WHERE bt.category = 'bank_fee')         AS fee_events
  FROM bank_accounts ba
  JOIN bank_transactions bt ON bt.bank_account_id = ba.id
 WHERE ba.account_type = 'credit_card'
   AND bt.category IN ('interest_charged','bank_fee')
 GROUP BY 1,2,3,4,5
 ORDER BY 1, 5 DESC;

COMMENT ON VIEW v_card_fees_interest_by_month IS
    'Credit-card finance-cost rollup. Per (card, month): interest + fees + counts.';

CREATE OR REPLACE VIEW v_account_transfers_open AS
SELECT
    bt.id AS unmatched_txn_id,
    bt.transaction_date,
    bt.bank_account_id,
    ba.account_name,
    bt.amount,
    bt.description,
    bt.category,
    bt.realm
  FROM bank_transactions bt
  JOIN bank_accounts ba ON ba.id = bt.bank_account_id
 WHERE bt.category IN ('inter_entity_transfer','transfer_uncategorised')
   AND NOT EXISTS (
       SELECT 1 FROM account_transfers at
        WHERE at.src_txn_id = bt.id OR at.dst_txn_id = bt.id
   )
 ORDER BY bt.transaction_date DESC;

COMMENT ON VIEW v_account_transfers_open IS
    'Transfer-flagged bank_transactions rows not yet paired in account_transfers.';

-- -----------------------------------------------------------------------------
-- 6. Verification
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    rule_added INT;
BEGIN
    SELECT COUNT(*) INTO rule_added
      FROM bank_transaction_rules
     WHERE name LIKE 'CC %';
    IF rule_added < 8 THEN
        RAISE EXCEPTION 'V73 verification failed: CC rule seed loaded only % rules (expected 8)', rule_added;
    END IF;
    RAISE NOTICE 'V73 verification PASS: % CC rules seeded.', rule_added;
END $$;

COMMIT;
