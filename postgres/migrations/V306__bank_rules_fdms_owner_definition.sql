-- V306 (2026-07-10) — FDMS terminal rules from Jo's definition:
-- "faster payments are bank transfers FROM the pub card terminal — also come
-- up as FDMS". FDMS merchant no. 510878762 is the reliable anchor; bare
-- ", FDMS" tails on unrelated DDs (O2, MMSL — 'FDEL FASTER PAYMEN, FDMS')
-- are statement-extraction artifacts and are NOT matched by these anchors
-- (verified overlap = 0). Broader FP-credit classification runs through the
-- verified mining panel, not a blanket rule, because the residue's credit
-- side still contains the un-ruled one-off large credits.
INSERT INTO bank_transaction_rules
  (priority, name, description_re, type_in, amount_op, amount_value, entity_in, category, confidence, notes)
VALUES
  (145, 'FDMS terminal service charge (SVCCHG, all formats)', 'FDMS.*SVCCHG', NULL, '<', 0, ARRAY[1]::int[], 'bank_fee', 0.95, 'owner-definition 2026-07-10; 39 rows £6,782 verified; supersedes the narrower PAYMENTSENSE-suffixed V305 rule for remaining formats'),
  (146, 'FDMS settlement adjustment credit', 'FDMS ADJ', NULL, '>', 0, ARRAY[1]::int[], 'card_settlement', 0.92, 'owner-definition 2026-07-10; 2 rows £1,300; acquirer adjustment credits are terminal settlements'),
  (147, 'FDMS terminal misc direct debit (merchant 510878762)', 'Direct Debit FDMS 510878762', NULL, '<', 0, ARRAY[1]::int[], 'bank_fee', 0.90, 'owner-definition 2026-07-10; 5 rows £580 after SVCCHG; terminal rental/misc charges on the FDMS merchant number')
ON CONFLICT DO NOTHING;
