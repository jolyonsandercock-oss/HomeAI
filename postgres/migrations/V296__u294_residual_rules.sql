-- V296 (2026-07-05, U294 T5 round 4) — residual-tail rule pack from
-- top-cluster triage. The LLM tail pass was abandoned after three failed
-- quality gates (see .superpowers/sdd/task-5-report.md); every rule below is
-- instead anchored to DB evidence pulled 2026-07-05 from the 11,802
-- category-IS-NULL residual (counts/sums quoted per rule). Conventions per
-- V295: real regex, evidence comment, registered category, confidence
-- 0.85-0.90 counterparty-anchored / 0.80 pattern-anchored, priority 130+.
-- Card-account note: on credit-card accounts (Cap On Tap acct 16 etc.)
-- POSITIVE amount = purchase; the "- Card Ending: NNNN" suffix is unique to
-- those purchase lines, so supplier rules anchor on it rather than on sign
-- semantics.
SET app.current_entity='all'; SET app.current_realm='owner';

INSERT INTO bank_transaction_rules (priority,name,description_re,amount_op,amount_value,entity_in,category,confidence,notes,realm) VALUES

-- Principality Building Society CHAPS credits: 5 uncategorised rows,
-- +£340,586.38 (accts 5/6, entities 2/3, 2020-02-18..2025-06-10), all
-- "PRINCIPALITY BUI, LDING SOCIETY ... CHAPS TFR" or "PBS FUNDS UNIT 1"
-- lines = mortgage advances/drawdowns landing at completion. Debit side
-- already covered (rule 113 mortgage_payment, legacy 45 loan_repayment).
 (130,'Principality mortgage advance (CHAPS in)','PRINCIPALITY','>',0,NULL,'financing_advance',0.85,'PBS CHAPS advance credits; 5 rows +£340,586.38 evidence 2026-07-05; debit side is rule 113','owner'),

-- Cap On Tap "Save" own-money sweeps: 14 rows +£265,005.61, all on acct 15
-- (ATR trading current), all "ATLANTIC ROAD TRAD CAPNTAPSAVE<ref>" — the
-- company moving money OUT OF its own CoT Save pot INTO the current account.
-- Own name on the sender = own-money movement, never income (this exact
-- cluster was the round-2 LLM miss that inflated income_trading by £221k).
 (131,'Cap On Tap Save own-money sweep','CAPNTAPSAVE',NULL,NULL,'{1}','internal_transfer',0.85,'own CoT Save pot <-> current acct; 14 rows +£265,005.61 evidence 2026-07-05; own-name sender','work'),

-- CoT facility drawdown, card-account leg: 6 rows +£65,000 on acct 16
-- ("Draw down of GBP 20000.0" etc., 2024-01-30..2026-04-21). The financing
-- event books here; the matching bank-side receipt is rule 133's transfer
-- leg (verified pair: +£20,000 both sides on 2024-01-30, ref MT50130967).
 (132,'Cap On Tap facility drawdown (card leg)','DRAW DOWN OF GBP','>',0,'{1}','financing_advance',0.85,'CoT credit facility drawdowns on card acct 16; 6 rows +£65,000; bank leg = rule 133','work'),

-- CoT credits into the bank account: 7 rows +£160,000.06 on acct 15
-- ("Automated Credit CAPITAL ON TAP GCT…/MT…"). Two are the receiving legs
-- of acct-16 balance refunds (+£53,838.98 / +£46,161.08, 2025-07-24/31,
-- amounts match acct 16's "Balance Refund transaction" rows exactly), the
-- rest receive facility drawdowns. Money from our own card facility =
-- transfer leg, not income (the financing event is booked by rule 132).
-- Sign-disjoint from rule 112 (<0 card_repayment).
 (133,'Cap On Tap credit to bank (own facility leg)','CAPITAL ON TAP','>',0,'{1}','internal_transfer',0.80,'bank-side receipts from own CoT facility; 7 rows +£160,000.06; pairs verified vs acct 16','work'),

-- CoT balance refund, card-account leg: 2 rows +£100,000.06 on acct 16
-- ("Balance Refund transaction of ?53-838.98." / ?46-161.08), paired
-- penny-exact with rule 133's bank receipts. Transfer leg.
 (134,'Cap On Tap balance refund (card leg)','BALANCE REFUND TRANSACTION','>',0,'{1}','internal_transfer',0.80,'card-side legs of the 2025-07 balance refunds; 2 rows +£100,000.06, penny-matched to acct 15','work'),

-- YouLend II funding advances: 2 rows +£85,000 on acct 15 ("YL II A LIMITED
-- YL…FND … FUNDING FOR ADVANC E"). Explicit advance language = loan
-- drawdown, NOT trading remit. V295 rule 110 ('YOULEND|YL LIMITED') does not
-- match the 'YL II A LIMITED' entity string, hence the gap.
 (135,'YouLend II funding advance','YL II A LIMITED|FUNDING FOR ADVANC','>',0,'{1}','financing_advance',0.90,'MCA drawdowns; 2 rows +£85,000 evidence 2026-07-05; remit/sweep legs stay rules 110/111','work'),

-- NatWest TYL acquiring settlements: 120 rows +£193,277.98 on acct 15
-- (2020-2023), "AUTOMATED CREDIT <ref> <merchant#> NATWES, T ACQUIRING …"
-- (PDF splits NATWEST across a comma). Same settlement rail role as the
-- existing Dojo/FDMS/PSLTD rules — the pre-FDMS/TYL era. Anchored to rows
-- that ARE automated credits (trailing text after ACQUIRING is next-line
-- statement bleed, e.g. "…TYENA TAIT, MALTHOUSE WAGES" — the amount belongs
-- to the credit; V295's FDMS bleed lesson applied via ^ anchor + >0).
 (136,'NatWest TYL acquiring settlement','^AUTOMATED CREDIT.*NATWES,? ?T,? ?ACQUIRING','>',0,'{1}','card_settlement',0.85,'NatWest acquiring credits into acct 15; 120 rows +£193,277.98 evidence 2026-07-05','work'),

-- PaymentSense settlements, short-form refs: 56 rows +£72,779.72 on acct 15
-- (Mar-Aug 2021), "AUTOMATED CREDIT PSLTD06AUG21000001 …". PSLTD =
-- PaymentSense Ltd; 67 sibling rows spelling out PAYMENTSENSE are already
-- categorised. card_settlement per the settlement-rail convention
-- (Dojo prio-20 / FDMS 120 rules), not rule 117's income_trading.
 (137,'PaymentSense PSLTD settlement','^AUTOMATED CREDIT PSLTD','>',0,'{1}','card_settlement',0.85,'PaymentSense short-ref settlement credits; 56 rows +£72,779.72 evidence 2026-07-05','work'),

-- Post Office counter cash banking: 69 rows +£193,130.00 on acct 15,
-- "POST OFFICE 27SEP COUNTER" (+ occasional next-line bleed). Pub cash
-- takings banked over the PO counter; the existing prio-60 cash rule only
-- knew COUNTER CREDIT/CASH PAID IN/BRANCH DEPOSIT phrasings.
-- CORRECTED after spot-check: the first cut ('POST OFFICE.*COUNTER') also
-- caught 6 tiny card PURCHASES AT post offices ("POST OFFICE COUNTER -
-- BODMIN - Card Ending: 7526", £3-£12) — false positives reset to NULL and
-- the regex tightened to the date-token deposit formats below.
 (138,'Post Office counter cash deposit','POST OFFICE [0-9]{1,2}[A-Z]{3} COUNTER|POST OFFICE COUNTER POST OFFICE','>',0,'{1}','cash_deposit',0.85,'PO counter banking of cash takings; 69 rows +£193,130.00 evidence 2026-07-05; CORRECTED after spot-check: 2 card purchases AT a post office (Bodmin, Card Ending lines) were false positives — regex now requires the date-token deposit format','work'),

-- Rolys Fudge Pantry rent: 37 rows +£117,257.53, ALL entity 2 (ARE property
-- co, acct 5), monthly-pattern FP credits 2019-2025 ("ROLYS FUDGE PANTRY,
-- ROLYS.S FUDGE , FP …"). Known tenant (plan-owner confirmed 2026-07-05).
 (139,'Rolys Fudge Pantry tenant rent','ROLYS.*FUDGE','>',0,'{2}','income_rent',0.90,'tenant of ARE premises; 37 rows +£117,257.53 evidence 2026-07-05','work'),

-- The Cornish Bakery rent: 80 rows +£151,171.06, entity 3 (personal
-- property, acct 6), regular FP credits 2019-2026 — commercial tenant of a
-- personally-held premises. Entity-scoped {3} because one entity-1 row
-- ("THE CORNISH BAKERY-TIN - … Card Ending: 0386") is a £168 card PURCHASE
-- at their Tintagel shop, not rent (POSIX ERE has no lookahead to exclude).
 (140,'Cornish Bakery tenant rent','^THE CORNISH BAKERY','>',0,'{3}','income_rent',0.85,'commercial tenant of personal premises; 80 rows +£151,171.06 evidence 2026-07-05','owner'),

-- Card-account supplier purchases (all "- Card Ending: NNNN" lines on CoT
-- acct 16, positive = spend; known suppliers per department taxonomy):
-- J&R Foodservice (kitchen/cafe): 48 rows +£216,870.44.
 (141,'J&R Foodservice card purchase','J (AND|&) ?R FOOD SERVI.*CARD ENDING','>',0,'{1}','supplier_payment',0.90,'kitchen/cafe food supplier on CoT card; 48 rows +£216,870.44 evidence 2026-07-05','work'),
-- St Austell Brewery (bar): 11 rows +£94,627.19.
 (142,'St Austell Brewery card purchase','ST AUSTELL BREWERY.*CARD ENDING','>',0,'{1}','supplier_payment',0.90,'bar supplier on CoT card; 11 rows +£94,627.19 evidence 2026-07-05','work'),
-- St Austell "Free Trade & Tenanted" division, same ST COLUMB depot: 7 rows
-- +£68,843.01.
 (143,'St Austell Free Trade card purchase','FREE TRADE & TENANTED.*CARD ENDING','>',0,'{1}','supplier_payment',0.85,'St Austell free-trade arm on CoT card; 7 rows +£68,843.01 evidence 2026-07-05','work'),
-- Westcountry Fruit Sales (kitchen produce): 11 rows +£67,698.52.
 (144,'Westcountry Fruit Sales card purchase','WESTCOUNTRY FRT SAL.*CARD ENDING','>',0,'{1}','supplier_payment',0.90,'produce supplier on CoT card; 11 rows +£67,698.52 evidence 2026-07-05','work'),

-- Utility DDs in the newer "Direct Debit <name>" import format, which the
-- legacy ^-anchored prio-45 rules miss:
-- British Gas: 126 uncategorised debit rows -£46,115.27 (+3 unruled).
 (145,'British Gas DD (new import format)','BRITISH GAS','<',0,NULL,'direct_debit',0.90,'legacy rule anchors ^BRITISH GAS variants only; 129 rows -£46,987.95 evidence 2026-07-05','owner'),
-- EDF Energy: 34 debit rows -£88,077.52 missed by ^EDF ENERGY anchor.
 (146,'EDF Energy DD (new import format)','EDF ENERGY','<',0,NULL,'direct_debit',0.90,'"Direct Debit EDF ENERGY …" rows the ^-anchored prio-45 rule misses; 35 rows -£91,513.01 evidence 2026-07-05','owner'),

-- Booking.com commission DDs: 63 rows -£92,609.89 on acct 15 ("Direct Debit
-- BOOKING.COM B.V. …") = OTA commission invoices collected by DD. A real
-- trading cost with a named counterparty -> supplier_payment rather than
-- the generic direct_debit bucket.
 (147,'Booking.com commission DD','BOOKING\.COM','<',0,'{1}','supplier_payment',0.85,'OTA commission collected by DD; 63 rows -£92,609.89 evidence 2026-07-05; credit-side refunds left unruled','work');

-- WITHDRAWN after spot-check: a planned priority-148 'QTOS Catering
-- transfer' rule (QTOS CATERING -> inter_entity_transfer) was inserted and
-- then DELETED + its 7 rows reset. The premise failed on the samples: "QTOS
-- CATERING EQUI(PMEN), NEWTON ABBOT/IPPLEPEN" is QTOS Catering Equipment, a
-- kitchen-equipment RETAILER (card purchases + refunds at a shop), and one
-- match was an Amazon refund caught purely via trailing "MOBILE/ONLINE QTOS
-- CATERING, MALTHOUSE" statement bleed. The acct-15 "TRANSACTION XFER …
-- QTOS CATERING, MALTHOUSE" credits remain ambiguous -> left to the
-- needs_review sweep.
