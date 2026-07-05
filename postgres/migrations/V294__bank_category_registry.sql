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

-- FK: added NOT VALID so historical rows don't block; Task 6 validates.
ALTER TABLE bank_transactions
  ADD CONSTRAINT bank_transactions_category_fk
  FOREIGN KEY (category) REFERENCES bank_category_registry(category) NOT VALID;

-- Rule lint: the V293 root cause (predicate-less rule) becomes impossible.
ALTER TABLE bank_transaction_rules
  ADD CONSTRAINT bank_transaction_rules_has_predicate CHECK (
    coalesce(description_re,'') <> ''
    OR (amount_op IS NOT NULL AND amount_value IS NOT NULL)
  );
