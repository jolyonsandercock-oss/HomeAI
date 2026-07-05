-- V294 (2026-07-05, U294) — bank category registry + structural guards.
-- The V293 lesson made structural: every category carries a kind, views
-- aggregate by kind, and a rule can never exist without a match predicate.
SET app.current_entity='all'; SET app.current_realm='owner';

CREATE TABLE IF NOT EXISTS bank_category_registry (
  category    text PRIMARY KEY,
  kind        text NOT NULL CHECK (kind IN ('income','cost','transfer','financing','tax','neutral')),
  description text NOT NULL
);

INSERT INTO bank_category_registry (category, kind, description) VALUES
 ('income_trading','income','card-settlement/takings credits (YouLend remits, Dojo, till banking)'),
 ('income_rent','income','rent received'),
 ('income_other','income','misc credits/refunds in'),
 ('internal_transfer','transfer','between our own accounts, any entity'),
 ('inter_entity_transfer','transfer','between entities (pre-existing category)'),
 ('card_repayment','transfer','payments to our own credit cards'),
 ('financing_advance','financing','loan money in'),
 ('financing_repayment','financing','loan principal+interest out'),
 ('mortgage_payment','financing','Principality + other mortgage DDs'),
 ('property_purchase','cost','completion-scale property outflows'),
 ('supplier_payment','cost','trade suppliers paid by bank'),
 ('wages','cost','payroll FPs/BACS'),
 ('tax_hmrc','tax','VAT, PAYE/NI, CT'),
 ('professional_fees','cost','solicitors, accountants, brokers'),
 ('bank_fee','cost','genuine bank charges (V293-guarded)'),
 ('interest_charged','cost','debit interest'),
 ('interest_credit','income','credit interest'),
 ('refund','income','refunds (pre-existing category)'),
 ('personal_spend','neutral','personal-account outflow, none of the above'),
 ('needs_review','neutral','undecided — surfaced, never summed')
ON CONFLICT (category) DO NOTHING;

-- Legacy categories still referenced by existing bank_transaction_rules rows
-- (pre-V294 vocabulary). Registered so the rules FK below can be plain/valid;
-- later U294 tasks may migrate rules off these, but they stay registered
-- while any rule uses them.
INSERT INTO bank_category_registry (category, kind, description) VALUES
 ('card_settlement','income','legacy: card-settlement credits (superseded by income_trading)'),
 ('cash_deposit','income','legacy: till cash banked (superseded by income_trading)'),
 ('vendor_payment','cost','legacy: supplier/vendor outflow (superseded by supplier_payment)'),
 ('direct_debit','cost','legacy: uncategorised DD outflow (payment method, not a true category)'),
 ('tax_payment','tax','legacy: HMRC payments (superseded by tax_hmrc)'),
 ('loan_repayment','financing','legacy: loan repayments (superseded by financing_repayment)'),
 ('rent_received','income','legacy: rent in (superseded by income_rent)'),
 ('transfer_uncategorised','transfer','legacy: own-account transfer not yet classified')
ON CONFLICT (category) DO NOTHING;

-- Old V71 CHECKs pinned category to a 17-value enum, which would reject most
-- registry categories before the FK is ever consulted. Superseded by the
-- bank_category_registry FKs (V294); the registry is now the single category
-- authority.
ALTER TABLE bank_transactions      DROP CONSTRAINT IF EXISTS bank_transactions_category_check;
ALTER TABLE bank_transaction_rules DROP CONSTRAINT IF EXISTS btr_category_check;

-- FK: added NOT VALID so historical rows don't block; Task 6 validates.
ALTER TABLE bank_transactions
  DROP CONSTRAINT IF EXISTS bank_transactions_category_fk;
ALTER TABLE bank_transactions
  ADD CONSTRAINT bank_transactions_category_fk
  FOREIGN KEY (category) REFERENCES bank_category_registry(category) NOT VALID;

-- Rules FK: plain (valid) — every existing rule category is registered above.
ALTER TABLE bank_transaction_rules
  DROP CONSTRAINT IF EXISTS bank_transaction_rules_category_fk;
ALTER TABLE bank_transaction_rules
  ADD CONSTRAINT bank_transaction_rules_category_fk
  FOREIGN KEY (category) REFERENCES bank_category_registry(category);

-- Rule lint: the V293 root cause (predicate-less rule) becomes impossible.
-- Deliberately NOT widened to accept type_in/entity_in-only rules: the Type
-- column is dropped at import and u58 skips type_in, so a type_in-only rule
-- is exactly the V293 catch-all bug.
ALTER TABLE bank_transaction_rules
  DROP CONSTRAINT IF EXISTS bank_transaction_rules_has_predicate;
ALTER TABLE bank_transaction_rules
  ADD CONSTRAINT bank_transaction_rules_has_predicate CHECK (
    coalesce(description_re,'') <> ''
    OR (amount_op IS NOT NULL AND amount_value IS NOT NULL)
  );
