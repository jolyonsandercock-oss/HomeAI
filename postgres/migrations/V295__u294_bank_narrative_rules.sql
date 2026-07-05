-- V295 (2026-07-05, U294 T3) — narrative rule pack. Every rule has a real
-- regex (V294 CHECK enforces). Confidence: 0.9 counterparty-anchored,
-- 0.8 pattern-anchored. priority 10-block leaves room above existing rules.
SET app.current_entity='all'; SET app.current_realm='owner';

-- Step 1: known-counterparty rules (evidence: brief's top-uncategorised-token
-- pull, 2026-07-05). Verbatim per task-3-brief.md.
INSERT INTO bank_transaction_rules (priority,name,description_re,amount_op,amount_value,entity_in,category,confidence,notes,realm) VALUES
 (110,'YouLend remit (card takings)','YOULEND|YL LIMITED','>',0,'{1}','income_trading',0.90,'Dojo takings via YouLend MCA, net of loan sweep — see feedback_dojo_youlend_financing','work'),
 (111,'YouLend sweep out','YOULEND|YL LIMITED','<',0,'{1}','financing_repayment',0.90,'MCA repayment legs','work'),
 (112,'Capital on Tap repayment DD','CAPITAL ON TAP|CAPITALONTAP','<',0,'{1}','card_repayment',0.90,'card acct 16 tracked in card_statements','work'),
 (113,'Principality mortgage','PRINCIPALITY','<',0,NULL,'mortgage_payment',0.90,'295905-02 cross-collateral; both entities pay','owner'),
 (114,'HMRC','HMRC|H\.?M\.? REVENUE','<',0,NULL,'tax_hmrc',0.90,'VAT/PAYE/CT out','owner'),
 (115,'HMRC refund in','HMRC|H\.?M\.? REVENUE','>',0,NULL,'income_other',0.85,'tax repayments','owner'),
 (116,'Atlantic Construct payments','ATLANTIC CONSTRUCT','<',0,NULL,'supplier_payment',0.85,'separate payee, NOT inter-entity — ATR recon 2026-06','work'),
 (117,'Dojo settlement credits','DOJO|PAYMENTSENSE','>',0,'{1}','income_trading',0.90,'pre-YouLend era settlements','work'),
 (118,'Interest charged (residual)','DEBIT INTEREST|INTEREST CHARGED','<',0,NULL,'interest_charged',0.90,'','owner'),
 (119,'Wages FP runs','WAGES|SALARY|PAYROLL','<',0,'{1,2}','wages',0.85,'','work');

-- Step 2: the three named anonymous patterns, investigated with 15-sample
-- pulls each (2026-07-05) before ruling.
--
-- (A) 'AUTOMATED CREDIT PAYMENT' (£1.88M evidence figure) — RESOLVED, NO NEW
-- RULE NEEDED. All 1,091 uncategorised rows (£1,874,244.96, 2022-09-30 to
-- 2025-11-03) are on bank_account_id=15 ("ATLANTIC ROAD TRADING — current #2
-- (Dojo settlement)"), all positive, and every single row's description
-- contains BOTH 'DOJO' and 'PAYMENTSENSE'
-- (e.g. "Automated Credit PAYMENTSENSE LIMIT DOJO01NOVCAFE FP 01/11/25 ...").
-- The pre-existing priority-20 rule 'Dojo card settlement'
-- (description_re='DOJO', amount>0 -> card_settlement) already matches this
-- substring case-insensitively; these rows are simply recent statement
-- imports that predate that rule's last apply run. u58 will pick them up
-- with the EXISTING rule on this run — confirmed no gap, no new rule added.
--
-- (B) 'AUTOMATED CREDIT FDEL FA' / 'FDMS 510878762' (£0.29M/526-row evidence
-- figure) — RESOLVED. All 661 uncategorised rows are on bank_account_id=15
-- (the account literally named "...Dojo settlement" in bank_accounts), same
-- recurring merchant ID FDMS 510878762, spanning 2023-03-01 to 2026-06-18:
-- 642 credits (+£400,504.14) and 19 debits (-£20,649.14, all Mar-Jul 2023,
-- presumably refunds/chargebacks netted through the same settlement rail).
-- FDMS = First Data Merchant Services, a card acquirer — same settlement
-- role as the Dojo/iZettle/Worldpay/SumUp/Stripe rules already in the table,
-- just the predecessor processor before the account switched to Dojo.
--
-- CORRECTED after spot-check (Step 4): the first cut of this rule had no
-- amount filter and matched 965 rows, of which 50 negative-amount rows were
-- NOT settlement income — 29 were "Direct Debit FDMS 510878762 SVCCHG"
-- (FDMS's own processing/service-charge fee, a cost not income) and 21 were
-- cases where "FDEL FASTER PAYMEN, FDMS" is a trailing PDF-extraction bleed
-- artifact glued onto a genuinely unrelated direct debit (BOOKING.COM, O2,
-- BT GROUP PLC, etc.) — true false positives. Those 50 rows were reset to
-- NULL and the rule tightened to amount > 0 (settlement credits only),
-- matching the sign convention already used by every other card-settlement
-- rule in the table. 915 genuine credit rows remain matched (£460,429.88).
INSERT INTO bank_transaction_rules (priority,name,description_re,amount_op,amount_value,entity_in,category,confidence,notes,realm) VALUES
 (120,'FDMS card settlement (predecessor acquirer)','FDEL FASTER PAYMEN|FDMS 510878762','>',0,'{1}','card_settlement',0.85,'First Data Merchant Services acquirer settlement into acct 15 (Dojo settlement account), predecessor of Dojo/PAYMENTSENSE rail; credit side only — SVCCHG fee lines and narrative-bleed false positives on the debit side excluded after spot-check','work');

-- (C) 'PAYMENT MADE (DIRECT DEB' (£0.68M evidence figure) — RESOLVED. All 28
-- uncategorised rows (-£682,826.18, 2023-12-29 to 2026-05-28) are on
-- bank_account_id=16 ("Cap On Tap — business credit card"), all negative,
-- description is the bare bank-generated line "Payment made (Direct
-- Debit)" with no counterparty text — this is the account's own periodic
-- balance-repayment sweep line, distinct from the individual purchase
-- lines on the same account (Amazon/Selco/J&R/etc.) which the existing
-- priority-15 'CC purchase (catch-all)' rule already handles. Confirmed the
-- exact phrase appears on NO other bank_account_id (categorised or not).
-- While investigating this exact phrase, also found the sibling narrative
-- "Payment made (VirtualBankTransfer)" — 11 rows, -£208,552.59, same
-- account, same negative-only, same no-counterparty-text shape, also
-- confirmed exclusive to account 16 — evidently the same repayment sweep
-- via a different payment rail. Folded into one rule since both are the
-- same finding (bank-generated CoT repayment line, no counterparty text).
INSERT INTO bank_transaction_rules (priority,name,description_re,amount_op,amount_value,entity_in,category,confidence,notes,realm) VALUES
 (121,'Capital on Tap balance repayment (bank-generated line)','Payment made \(Direct Debit\)|Payment made \(VirtualBankTransfer\)','<',0,'{1}','card_repayment',0.85,'CoT acct 16 own-ledger repayment sweep line, no counterparty text in description; confirmed exclusive to acct 16 across whole table before ruling','work');
