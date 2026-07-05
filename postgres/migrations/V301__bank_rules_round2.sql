-- V301 (2026-07-05, U294 round-2 residual burn-down) — evidence-backed rules
-- only. Every row below was individually pulled and read in full (not just
-- the U294 24-char cluster key, which truncates and fragments many of these
-- narratives) before ruling. Confidence 0.9/0.85 = counterparty or exact
-- narrative match; 0.8/0.75 = pattern is unambiguous in shape but the exact
-- destination/purpose required a documented inference (see notes). NO rule
-- below has an empty predicate (CHECK enforces) and NO rule is a loose
-- catch-all (Amazon/eBay/generic marketplace narratives were investigated
-- and deliberately left OUT — see report — because they mix personal and
-- business spend with no textual signal to split them).
--
-- All figures are deduped-row counts/£ against the 11,109-row / £4,428,183
-- category='needs_review' AND category_source='u294:residual-sweep'
-- population as of 2026-07-05, before this migration applied.
SET app.current_entity='all';
SET app.current_realm='owner';

-- ---------------------------------------------------------------------
-- (1) STEPHENS SCOWN (solicitors, Saint Austell). Two distinct narrative
-- shapes with DIFFERENT correct categories, confirmed against the 4 rows of
-- this counterparty ALREADY categorised (all 'transfer_uncategorised',
-- round £20,000 completion-money legs via "STEPHENS SCOWN , <ref> , VIA
-- (ONLINE|MOBILE) - PYMT", Feb-Mar 2021, same solicitor reference '00348').
-- (a) Card-transaction rows "<card> <date> , STEPHENS SCOWN LLP, SAINT
--     AUSTELL GB" — 11 rows, -£7,027.20, 2020-04-17 to 2021-06-08, varying
--     amounts (£195-£1,246) — genuine legal fee invoices paid by debit
--     card -> professional_fees.
-- (b) Two more £20,000 FP legs, same solicitor ref '00348', "STEPHENS SCOWN
--     , 00348 , VIA ONLINE - PYMT" dated 2021-02-24/26 — days before the 3
--     already-categorised £20,000 legs (2021-03-02/04/19) with the exact
--     same reference — same completion-funds event, same category as
--     precedent -> transfer_uncategorised (destination account not
--     resolved to a specific one of our own accounts, hence not upgraded to
--     internal_transfer/inter_entity_transfer without more evidence).
INSERT INTO bank_transaction_rules (priority,name,description_re,amount_op,amount_value,entity_in,category,confidence,notes,realm) VALUES
 (200,'Stephens Scown LLP legal fees (card)','STEPHENS SCOWN LLP','<',0,'{3}','professional_fees',0.9,'11 rows £7,027.20 2020-04 to 2021-06, card-paid solicitor invoices, acct 6','personal'),
 (201,'Stephens Scown completion funds (FP, non-LLP)','STEPHENS SCOWN','<',0,'{3}','transfer_uncategorised',0.85,'2 rows £40,000 2021-02-24/26, same solicitor ref 00348 as 3 already-categorised £20k legs days later; runs AFTER 200 so LLP rows are excluded from pool first','personal');

-- ---------------------------------------------------------------------
-- (2) Card/settlement-style processor feeds on acct 15 (ATLANTIC ROAD
-- TRADING — Dojo settlement account, entity 1). Credit side only in every
-- case below — same discipline as the V295 FDMS finding, because the debit
-- side of these narratives is confirmed (spot-checked full text) to be a
-- PDF-extraction bleed artifact gluing this reference onto UNRELATED
-- transactions (Amazon purchases, Cornwall Council DD, BT Group DD,
-- standing orders all show up with "DMN/COLLINS , DMN/COLLINS , FP" or
-- "ACCESS COLLINS" trailing them) — those debit rows are a mixed bag and
-- deliberately NOT ruled.
--
-- (a) 'WFL MEDIA LTD ACCESS COLLINS' / 'DMN/COLLINS' / 'ACCESS COLLINS' —
-- 105 credit rows, £11,596, weekly small amounts (£10-£800) 2020-2024.
-- Existing (non-needs-review) rows with this same counterparty text are
-- already 82/101 categorised card_settlement — same recurring small-value
-- weekly-cadence processor-remittance shape as Stripe/SumUp/Worldpay rules
-- already in this table. Followed precedent.
-- (b) 'ACCESS PAYSUITE' / 'DESIGNMYNIGHT' — 36 credit rows, £2,704, on the
-- Dojo settlement account, identical fixed trailing merchant/gateway code
-- (Q2BBTK6UTARL) every time — DesignMyNight is a bookings/EPOS platform
-- pubs use for online table/event deposits, routed through the Access
-- PaySuite gateway; same processor-remittance shape as the other
-- card_settlement rules.
-- (c) 'CITIBANK IRE FIN S' + 'AIRBNB PAYMENTS' — 10 credit rows, £1,095,
-- acct 15 only. NOTE: the SAME 'AIRBNB' text also appears on acct 6 (Jo's
-- personal card) as booking CHARGES (Jo paying to stay somewhere) — opposite
-- semantics, deliberately excluded via the 'CITIBANK IRE FIN S' anchor,
-- which only appears on the acct-15 host-payout side. 3 precedent rows
-- already card_settlement.
-- (d) 'ENCONTR WALK' — 20 credit rows, £10,395 (18 on acct 15 £10,010 + 2 on
-- acct 4/Tax Reserve £385, both entity 1), guest-booking-reference shape
-- ("ENCONTR WALK <dates> <surname>"). 8 rows of this exact counterparty
-- already categorised card_settlement — followed precedent rather than the
-- income_rent guess the narrative shape alone would suggest.
INSERT INTO bank_transaction_rules (priority,name,description_re,amount_op,amount_value,entity_in,category,confidence,notes,realm) VALUES
 (202,'WFL Media / Access Collins settlement feed (credit side only)','WFL MEDIA|DMN/COLLINS|ACCESS COLLINS','>',0,'{1}','card_settlement',0.8,'105 rows £11,596 acct 15; debit-side same text is a PDF-bleed artifact on unrelated txns, NOT ruled — see V301 header','work'),
 (203,'DesignMyNight / Access PaySuite settlement','ACCESS PAYSUITE|DESIGNMYNIGHT','>',0,'{1}','card_settlement',0.85,'36 rows £2,704 acct 15, fixed gateway code Q2BBTK6UTARL every occurrence','work'),
 (204,'Airbnb host payout (Citibank Ireland rail)','CITIBANK IRE FIN S.*AIRBNB PAYMENTS','>',0,'{1}','card_settlement',0.85,'10 rows £1,095 acct 15 only; do not broaden to bare AIRBNB — that also matches Jo''s personal booking charges on acct 6, opposite direction','work'),
 (205,'Encontr Walk booking settlement','ENCONTR WALK','>',0,'{1}','card_settlement',0.85,'20 rows £10,395 (18 acct15 + 2 acct4); matches 8 already-categorised precedent rows','work');

-- ---------------------------------------------------------------------
-- (3) Misc single-purpose recurring feeds, acct 15 entity 1.
-- (a) 'CASH & DEP MACHINE' — 36 rows, £34,430, all credit — cash banked via
-- deposit machine (not branch counter, hence not caught by the existing
-- 'Cash deposit at branch' rule which requires CASH PAID IN/COUNTER
-- CREDIT/BRANCH DEPOSIT literal text) -> cash_deposit.
-- (b) 'NEST IT' (Direct Debit NEST IT000005336182) — 29 rows, -£33,632, all
-- debit. NEST is the auto-enrolment pension provider; this is the employer
-- pension contribution DD. No 'pension' category exists in the registry;
-- treated as a payroll on-cost -> wages (kind=cost, closest real fit;
-- flagged for Jo to redirect if he wants pension split out separately).
-- (c) 'TO A/C 48885525' / 'FROM A/C 48885525' — 11 rows, £60,030 net both
-- directions — 48885525 is bank_accounts.id=20 (ATR Trading Reserve), same
-- entity (1) as acct 15 — literal own-account-number match -> internal_transfer.
-- (d) 'ATLANTIC ESTATES' (without 'ROAD') — 2 rows, £10,264, credit — same
-- semantic as the existing 'To/From ATLANTIC ROAD ESTA' rule
-- (inter_entity_transfer), just missing the word ROAD in this narrative
-- variant.
-- (e) 'Standing Order PARTNERSHIP TRANSF' — 29 rows, -£25,873, fixed
-- £900/month for years, explicitly labelled a partnership transfer with no
-- named destination in the text -> transfer_uncategorised (own/partnership
-- transfer, destination not resolved — same treatment as the existing
-- 'transfer_uncategorised' legacy category is defined for).
INSERT INTO bank_transaction_rules (priority,name,description_re,amount_op,amount_value,entity_in,category,confidence,notes,realm) VALUES
 (206,'Cash & Dep Machine banking','CASH & DEP MACHINE','>',0,'{1}','cash_deposit',0.9,'36 rows £34,430 acct 15, deposit-machine banking (not branch counter)','work'),
 (207,'NEST pension contribution DD','NEST IT','<',0,'{1}','wages',0.75,'29 rows £33,632; no pension category in registry, treated as payroll on-cost','work'),
 (208,'Internal xfer to/from ATR Trading Reserve (acct 20)','TO A/C 48885525|FROM A/C 48885525',NULL,NULL,'{1}','internal_transfer',0.85,'11 rows £60,030 net; 48885525 = bank_accounts.id 20, same entity as acct 15','work'),
 (209,'To/From Atlantic Estates (narrative variant w/o ROAD)','ATLANTIC ESTATES',NULL,NULL,NULL,'inter_entity_transfer',0.8,'2 rows £10,264; same semantics as existing To/From ATLANTIC ROAD ESTA rule, narrative variant missing the word ROAD','owner'),
 (210,'Standing Order — partnership transfer (destination unresolved)','Standing Order PARTNERSHIP TRANSF','<',0,'{1}','transfer_uncategorised',0.75,'29 rows £25,873, fixed £900/mo, own/partnership transfer with no named destination in text','work');

-- ---------------------------------------------------------------------
-- (4) Cap On Tap business credit card (acct 16, entity 1) — named trade
-- suppliers only, each verified to recur 3+ times with an unambiguous
-- trade identity (builders' merchants, food wholesalers, decorating
-- suppliers, waste/training services). Amazon/eBay/parking/fuel/generic
-- marketplace narratives on this same card were investigated and
-- DELIBERATELY excluded — genuinely mixed personal/business use with no
-- textual signal to split them; see report remaining-clusters list.
-- 226 rows, £111,868, all card-purchase credits->spend (card-account sign
-- convention: positive = spend).
INSERT INTO bank_transaction_rules (priority,name,description_re,amount_op,amount_value,entity_in,category,confidence,notes,realm) VALUES
 (211,'Named trade suppliers — Cap On Tap card purchases','(PLUMBASE|HOWDENS|BIDFRESH|DOLE CORNWALL|SELCO EXETER|JOHNSTONES DECORATING|NISBETS LTD|CROWN DECORATING|DULUX DECORATOR|SCREWFIX|NEW WORLD TIMBER|IRONMONGERYDIRECT|ELECTRIC CENTRE|LOGAN''S LOGS|PHILIP WARREN AND SON|B & Q WAREHOUSE|KARCHER CENTER|BOOKER LTD|CORNWALL GLASS|HIGH SPEED TRAINING|EMS WASTE SERVICES|TOTAL PRODUCE|BREWERS EXETER).*CARD ENDING','>',0,'{1}','supplier_payment',0.85,'226 rows £111,868 acct 16; Amazon/eBay/parking/fuel deliberately excluded as genuinely ambiguous — see report','work');

-- ---------------------------------------------------------------------
-- (5) Personal current account (acct 6, entity 3) — Jo's personal property
-- rental income. Castle Rd, Salutations and Olde Malthouse are documented
-- Personal-entity properties (project_properties_mortgages). None of these
-- tenant names had ANY prior categorised rows (0 precedent), but the
-- evidence is direct: recurring fixed monthly amounts (£150-£1,500) over
-- multiple years, with explicit "RENT", "RENT SALUTATIONS", "RENT FOR
-- <MONTH>" or "...RENT" narrative text in the large majority of occurrences
-- (a handful of BARNETT JPW rows read "FLATCASTLEROAD"/"FLAT CASTLE ROAD"
-- with no RENT word, same tenant, folded in as the same real-world rent).
-- 147 rows, £92,543, all credit -> income_rent.
--   BORLAS KE / WALTON KE  — "RENT SALUTATIONS", 22 rows £20,780
--   MCCALL B I             — "RENT FOR <MONTH>"/"RENT", 46 rows £33,425
--   PRESTO RETAIL LIMI     — "RENT", 10 rows £15,000
--   ANSELL TL              — "RENT", 4 rows £3,600
--   BARNETT JPW            — Castle Rd flat, 51 rows ~£17,511
--   WAKEFIELDS OF CAME     — "RENT PARTPAYMENT", 1 row £427
--
-- Separately, "ATLANTIC ROAD TRAD...RENT"/"...CLEETON RENT" (4 rows,
-- £13,000, entity 3) is rent paid BY the trading entity TO Jo personally —
-- explicit RENT narrative, same income_rent treatment as the Cornish
-- Bakery/Rolys Fudge tenant-rent rules already do across entities.
--
-- "ATLANTIC ROAD TRAD/TRADING...DRAWDOWN"/"...DIRECTOR LOAN" (4 rows,
-- £27,000, entity 3) is money moving between Jo personally and the trading
-- entity with NO rent/fee narrative — a director's drawdown and its
-- repayment -> inter_entity_transfer.
--
-- "MISS C A COLLINGS" (84 rows, -£16,800, entity 3) — a fixed exact -£200
-- standing order on the 5th of every month, unbroken 2019-2026. No
-- further narrative text to identify the purpose. This is the textbook
-- case the 'personal_spend' category exists for ("personal-account
-- outflow, none of the above") — not upgraded to any more specific
-- category without further evidence.
INSERT INTO bank_transaction_rules (priority,name,description_re,amount_op,amount_value,entity_in,category,confidence,notes,realm) VALUES
 (212,'Personal property rent — named tenants (Castle Rd / Salutations / other)','BORLAS KE|WALTON KE|MCCALL B I|PRESTO RETAIL LIMI|ANSELL TL|BARNETT JPW|WAKEFIELDS OF CAME','>',0,'{3}','income_rent',0.85,'147 rows £92,543 acct 6; 0 prior precedent but explicit RENT text in the large majority + known Personal-entity properties (Castle Rd/Salutations)','personal'),
 (213,'ATR Trading rent paid to Jo personally','ATLANTIC ROAD TRAD.*(RENT|CLEETON RENT)','>',0,'{3}','income_rent',0.8,'4 rows £13,000; explicit RENT narrative, cross-entity rent (same convention as Cornish Bakery/Rolys Fudge tenant-rent rules)','personal'),
 (214,'ATR Trading director drawdown / director loan (personal side)','ATLANTIC (ROAD TRAD|TRADING).*(DRAWDOWN|DIRECTOR LOAN)',NULL,NULL,'{3}','inter_entity_transfer',0.85,'4 rows £27,000 net both directions; no rent/fee narrative, plain drawdown+repayment between Jo and the trading entity','personal'),
 (215,'Miss C A Collings — fixed monthly standing order','MISS C A COLLINGS','<',0,'{3}','personal_spend',0.7,'84 rows £16,800; exact -£200 on the 5th, unbroken 2019-2026, no further narrative — textbook personal_spend catch-all case','personal');

-- ---------------------------------------------------------------------
-- (6) ATLANTIC ROAD ESTATE current account (acct 5, entity 2).
-- (a) 'GARRETT CA...TINTAGEL' — 38 rows, £20,608, fixed ~£550/month for
-- years -> a Tintagel flat let, income_rent.
-- (b) 'EURONET 360 FINANC' — 61 rows, £17,551, fixed £291.67/month (a few
-- other fixed sub-amounts) 2021-2026, ALL CREDIT. Euronet is a well-known
-- ATM/payment-terminal operator; a fixed recurring monthly CREDIT (not a
-- repayment debit) reads as a site/hosting fee paid TO the pub for hosting
-- a Euronet ATM — treated as income_rent at LOWER confidence (0.7) since
-- the exact commercial relationship is inferred from shape+payer identity,
-- not a labelled narrative; flagged for Jo to confirm.
-- (c) 'BG BUSINESS' / 'BRIT GAS BUSINESS' — 35 rows (16 acct5 + 8 acct15 +
-- 11 acct6), -£17,567, all debit — British Gas Business DD narrative
-- variant not caught by the existing 'BRITISH GAS' rule (different literal
-- text) -> direct_debit, matching the existing BRITISH GAS/EDF convention.
INSERT INTO bank_transaction_rules (priority,name,description_re,amount_op,amount_value,entity_in,category,confidence,notes,realm) VALUES
 (216,'Tintagel flat rent (Garrett)','GARRETT CA.*TINTAGEL','>',0,'{2}','income_rent',0.85,'38 rows £20,608 acct 5, fixed ~£550/mo for years','work'),
 (217,'Euronet 360 — likely ATM site fee (inferred)','EURONET 360 FINANC','>',0,'{2}','income_rent',0.7,'61 rows £17,551 acct 5, fixed £291.67/mo credit 2021-2026; Euronet = ATM/payment terminal operator, shape reads as site-hosting fee not a repayment (all credit, not debit) — confidence held at 0.7 pending Jo confirmation','work'),
 (218,'British Gas Business DD (narrative variant)','BG BUSINESS|BRIT GAS BUSINESS','<',0,NULL,'direct_debit',0.9,'35 rows £17,567 across accts 5/6/15; BRITISH GAS rule literal text does not match this variant','owner');
