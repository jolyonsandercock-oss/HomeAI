-- =============================================================================
-- V71 — Bank transaction categorisation (Phase A of reconciliation system)
-- =============================================================================
-- Adds:
--   * bank_transactions.category — coarse semantic category
--   * bank_transactions.category_confidence — 0.0..1.0
--   * bank_transactions.category_source — which rule (or 'manual', 'ai') tagged
--   * bank_transaction_rules — regex-driven rule table for the categoriser
--   * v_uncategorised_summary — quick view of what's not yet tagged
--
-- Categories (enum-via-CHECK):
--   card_settlement       — Dojo / WorldPay / iZettle / SumUp settlement deposits
--   cash_deposit          — counter cash deposits (cashing-up output)
--   customer_payment      — incoming non-card (BACS, FP) from non-vendor names
--   vendor_payment        — outgoing to suppliers / known vendors
--   payroll               — outgoing salaries / wages (regular monthly)
--   tax_payment           — HMRC / VAT / corporation tax / PAYE
--   bank_fee              — service charges, transaction fees, returned-DD fees
--   interest_charged      — overdraft interest debit
--   interest_credit       — savings interest received
--   inter_entity_transfer — between Jo's entities (ATR ↔ AREL ↔ personal)
--   direct_debit          — recurring DD/SO (utilities, subs, insurance)
--   loan_repayment        — mortgage / loan repayments
--   rent_received         — incoming property rent (AREL)
--   rent_paid             — outgoing property rent
--   transfer_uncategorised — confirmed transfer, no entity match yet
--   refund                — explicit refund / waiver text
--   other                 — fall-through
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Columns on bank_transactions
-- -----------------------------------------------------------------------------

ALTER TABLE bank_transactions
    ADD COLUMN IF NOT EXISTS category            TEXT,
    ADD COLUMN IF NOT EXISTS category_confidence NUMERIC(4,3),
    ADD COLUMN IF NOT EXISTS category_source     TEXT;

ALTER TABLE bank_transactions DROP CONSTRAINT IF EXISTS bank_transactions_category_check;
ALTER TABLE bank_transactions ADD CONSTRAINT bank_transactions_category_check
    CHECK (category IS NULL OR category IN (
        'card_settlement','cash_deposit','customer_payment','vendor_payment',
        'payroll','tax_payment','bank_fee','interest_charged','interest_credit',
        'inter_entity_transfer','direct_debit','loan_repayment',
        'rent_received','rent_paid','transfer_uncategorised','refund','other'
    ));

CREATE INDEX IF NOT EXISTS idx_bank_tx_category    ON bank_transactions (category);
CREATE INDEX IF NOT EXISTS idx_bank_tx_uncat_recent
    ON bank_transactions (transaction_date DESC) WHERE category IS NULL;

-- -----------------------------------------------------------------------------
-- Rule table — regex-driven categoriser
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS bank_transaction_rules (
    id              SERIAL PRIMARY KEY,
    priority        INTEGER NOT NULL DEFAULT 100,  -- lower = applied first
    name            TEXT NOT NULL,
    description_re  TEXT,                          -- POSIX regex on description (NULL = any)
    type_in         TEXT[],                        -- match if Type column (BAC/DPC/INT/etc) is in this set
    amount_op       TEXT,                          -- '<', '>', '<=', '>=', '=', '<>' or NULL
    amount_value    NUMERIC(12,2),
    entity_in       INTEGER[],                     -- match if entity_id is in this set (NULL = any)
    category        TEXT NOT NULL,
    confidence      NUMERIC(4,3) NOT NULL DEFAULT 0.90,
    notes           TEXT,
    realm           TEXT NOT NULL DEFAULT 'owner'
);

ALTER TABLE bank_transaction_rules DROP CONSTRAINT IF EXISTS btr_realm_check;
ALTER TABLE bank_transaction_rules ADD CONSTRAINT btr_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

ALTER TABLE bank_transaction_rules DROP CONSTRAINT IF EXISTS btr_category_check;
ALTER TABLE bank_transaction_rules ADD CONSTRAINT btr_category_check
    CHECK (category IN (
        'card_settlement','cash_deposit','customer_payment','vendor_payment',
        'payroll','tax_payment','bank_fee','interest_charged','interest_credit',
        'inter_entity_transfer','direct_debit','loan_repayment',
        'rent_received','rent_paid','transfer_uncategorised','refund','other'
    ));

CREATE INDEX IF NOT EXISTS idx_btr_priority ON bank_transaction_rules (priority);

-- -----------------------------------------------------------------------------
-- Seed rules — built from inspection of the imported data
-- -----------------------------------------------------------------------------

INSERT INTO bank_transaction_rules (priority, name, description_re, type_in, amount_op, amount_value, category, confidence, notes) VALUES
  -- High-priority unambiguous matches
  (10,  'NatWest interest charged',     '^[0-9]{1,2}[A-Z]{3}.*A/C [0-9]+$',  ARRAY['INT'], '<',  0, 'interest_charged', 0.99, 'NatWest "31JAN A/C 49011170" with negative value'),
  (10,  'NatWest interest credit',      '^[0-9]{1,2}[A-Z]{3} GRS [0-9]+$',   ARRAY['INT'], '>=', 0, 'interest_credit',  0.99, 'NatWest "29FEB GRS 69323321"'),
  (10,  'Bank service charge',          '(SERVICE CHARGE|CHARGES PAID|UNPAID ITEM|UNAUTHORISED|RETURNED ITEM)', NULL, NULL, NULL, 'bank_fee', 0.98, NULL),

  -- Card settlements (Phase B will pair these to dojo_transactions / iZettle)
  (20,  'Dojo card settlement',         'DOJO',                              NULL, '>',  0, 'card_settlement', 0.97, 'pub card receipts'),
  (20,  'iZettle card settlement',      'IZETTLE',                           NULL, '>',  0, 'card_settlement', 0.97, 'legacy / café card receipts'),
  (20,  'Worldpay card settlement',     'WORLDPAY',                          NULL, '>',  0, 'card_settlement', 0.97, NULL),
  (20,  'SumUp card settlement',        'SUMUP',                             NULL, '>',  0, 'card_settlement', 0.95, NULL),
  (20,  'Stripe card settlement',       'STRIPE',                            NULL, '>',  0, 'card_settlement', 0.92, NULL),

  -- Tax
  (30,  'HMRC VAT',                     '(HMRC VAT|HMRC NDDS|HMRC SDDS)',    NULL, NULL, NULL, 'tax_payment', 0.99, NULL),
  (30,  'HMRC PAYE',                    '(HMRC PAYE|HMRC P/A|HMRC EMP)',     NULL, NULL, NULL, 'tax_payment', 0.99, NULL),
  (30,  'HMRC Corporation Tax',         'HMRC CUMBERNAULD',                  NULL, NULL, NULL, 'tax_payment', 0.95, 'NatWest CT description'),
  (30,  'Companies House filing fee',   'COMPANIES HOUSE',                   NULL, NULL, NULL, 'tax_payment', 0.90, NULL),

  -- Inter-entity transfers (Phase B will pair-match these)
  (40,  'To/From SANDERCOCK J',         '(SANDERCOCK J|MR J SANDERCOCK|SANDERCOCK MR J)', NULL, NULL, NULL, 'inter_entity_transfer', 0.85, 'tighten in Phase B once we pair them'),
  (40,  'To/From ATLANTIC ROAD ESTATE', 'ATLANTIC ROAD ESTA',                NULL, NULL, NULL, 'inter_entity_transfer', 0.85, NULL),
  (40,  'To/From Malthouse',            'MALTHOUSE.*(TRANSFER|XFER|PYMT)',   NULL, NULL, NULL, 'inter_entity_transfer', 0.85, NULL),
  (40,  'Internal Mobile Xfer',         '(MOBILE XFER|MOBILE - XFER|VIA MOBILE)', NULL, NULL, NULL, 'transfer_uncategorised', 0.80, NULL),
  (40,  'Internal Banking Xfer',        '(ONLINE XFER|VIA BANKLINE)',        NULL, NULL, NULL, 'transfer_uncategorised', 0.75, NULL),

  -- Recurring household / utility direct debits
  (50,  'Direct debit (DD type)',       NULL,                                ARRAY['D/D'], NULL, NULL, 'direct_debit', 0.90, 'NatWest D/D row type'),
  (50,  'Standing order (SO type)',     NULL,                                ARRAY['S/O'], NULL, NULL, 'direct_debit', 0.90, NULL),

  -- POS / contactless / cash-machine — Personal-realm spending; bucket as vendor_payment for now
  (60,  'POS / ATM personal spend',     NULL,                                ARRAY['POS','CWP','C/L'], '<', 0, 'vendor_payment', 0.85, 'tighten with vendor-merge later'),

  -- Cash deposits (Phase B will pair to till_reconciliation)
  (60,  'Cash deposit at branch',       '(CASH PAID IN|COUNTER CREDIT|BRANCH DEPOSIT)', NULL, '>', 0, 'cash_deposit', 0.95, NULL),

  -- Property rent (AREL inbound). Phase B refines with tenant list.
  (70,  'Inbound property rent (AREL)', NULL,                                ARRAY['BAC'], '>', 0, 'rent_received', 0.70, 'TEMP: tighten to AREL account + recurring monthly pattern in Phase B');

-- -----------------------------------------------------------------------------
-- Diagnostic view
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_uncategorised_summary AS
SELECT
    DATE_TRUNC('month', transaction_date)::date AS month,
    ba.account_name,
    bt.realm,
    COUNT(*) AS n,
    SUM(GREATEST(bt.amount, 0))::numeric(12,2) AS sum_in,
    SUM(LEAST(bt.amount, 0))::numeric(12,2)    AS sum_out
  FROM bank_transactions bt
  JOIN bank_accounts ba ON ba.id = bt.bank_account_id
 WHERE bt.category IS NULL
 GROUP BY 1, 2, 3
 ORDER BY 1 DESC, 2;

COMMENT ON VIEW v_uncategorised_summary IS
    'Phase A diagnostic: where is the auto-categoriser still leaving gaps?';

-- -----------------------------------------------------------------------------
-- Verification
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    rule_count INT;
BEGIN
    SELECT COUNT(*) INTO rule_count FROM bank_transaction_rules;
    IF rule_count < 15 THEN
        RAISE EXCEPTION 'V71 verification failed: rule seed loaded only % rules (expected ≥15)', rule_count;
    END IF;
    RAISE NOTICE 'V71 verification PASS: % rules seeded.', rule_count;
END $$;

COMMIT;
