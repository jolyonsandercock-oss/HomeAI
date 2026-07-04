-- V294 (2026-07-04) — accurate fee categorisation (corrects V293's over-null).
--
-- V293 emptied the bank_fee catch-all but its keep-pattern was too tight (14
-- rows) and MISSED real fees for two reasons, both found on review:
--   1. NatWest business current accounts are billed a MONTHLY charge narrated
--      "Charges DDMON A/C <acct>" (£38-328/mo) — 44 rows, £5,816. Not caught.
--   2. Credit-card fees/interest are stored as POSITIVE amounts (they increase
--      the balance owed), so every amount<0 fee scan skipped them: card annual
--      fee, plan fee, late-payment fee, non-sterling transaction fee.
-- Bank code reference: NatWest statement narratives (Charge/CHG, N-S TRN FEE,
-- ARRANGED OD USAGE) per natwest.com support-centre statement-abbreviations.
--
-- Result: bank_fee = 150 rows, £6,733.81 all-time (£953.70 in 12m). Interest
-- stays 'interest_charged' (206 rows — interest, not a fee). The boilerplate
-- "...dispute resolution for agreed overdrafts..." consumer-rights text that
-- NatWest appends to card PURCHASE lines is deliberately excluded (not a fee).
--
-- Applied live 2026-07-04 (already run — recorded here). Sign-aware fee set:
--   description ~* 'Charges [0-9]{1,2}[A-Z]{3} A/C'                       (NatWest monthly)
--   OR 'arranged od usage|unarranged od|unpaid item fee|paid referral fee|o/d renewal'
--   OR 'non-sterling transaction fee'
--   OR ('annual fee' AND NOT 'refund')
--   OR 'late payment fee'
--   OR 'plan fee|cash advance fee|\mcash fee\M|card fee|handling fee|maintenance charge'
--   AND NOT 'via (online|mobile).*pymt|estates .*service'
--   -> category='bank_fee', confidence 0.97, source 'rule:fee-accurate-v2'.
-- The v_finance_kpis fees_paid_12m expression is already sign-aware (card
-- charges positive, current-account fees negated) so no view change needed.
--
-- Persistent rules added to bank_transaction_rules so u58 + future imports
-- categorise these via description_re (which u58 DOES apply, unlike the
-- type_in-only catch-all that V293 removed):
INSERT INTO bank_transaction_rules (priority, name, description_re, category, confidence, realm) VALUES
  (8, 'NatWest monthly account charge', 'Charges [0-9]{1,2}[A-Z]{3} A/C', 'bank_fee', 0.97, 'owner'),
  (8, 'Overdraft / unpaid item fee', 'arranged od usage|unarranged (od|overdraft)|unpaid item fee|paid referral fee|o/d renewal', 'bank_fee', 0.97, 'owner'),
  (8, 'Card non-sterling fee', 'non-sterling transaction fee', 'bank_fee', 0.97, 'owner'),
  (8, 'Card annual/late/plan/cash fee', 'late payment fee|plan fee|cash advance fee|\mcash fee\M|handling fee', 'bank_fee', 0.95, 'owner')
ON CONFLICT DO NOTHING;
-- Rollback of the whole bank_fee saga: _bank_catfix_20260704_backup restores
-- every original category by id (see V293).
