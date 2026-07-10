-- V309 (2026-07-10) — mop-up segment rules (personal-card credits + ARE).
-- Source: single mining agent over the three segments whose panel batch
-- crashed twice; every rule re-verified by hand before shipping. The agent's
-- headline rule (bare 'malthouse' >=1000) FAILED my independent blast-radius
-- check (21 needs_review rows/£140,750 + 28 card_settlement rows vs its
-- claimed 9/£39,000) and was narrowed to the terminal merchant format below,
-- which matches exactly the 9 known DLA card-injection rows.
-- Rejected as owner-decisions (NOT ruled): SANDERCOCK H&P 'HARRY' credits
-- into ARE (£20k — Dad pile), SIAN LIBBY MILLS 'REPAYMENT' rows on ARE
-- (round-1 verifier had explicitly held these for owner review).
INSERT INTO bank_transaction_rules
  (priority, name, description_re, type_in, amount_op, amount_value, entity_in, category, confidence, notes)
VALUES
  (165, 'Pub terminal capital injection (Jo personal card at own till)', '^Ye ?Olde ?Malthouse ?Inn', NULL, '>=', 1000, NULL, 'inter_entity_transfer', 0.95, 'mop-up 2026-07-10; owner-confirmed via DLA session: round >=£1k charges on Jo''s personal Mastercards at the pub''s own terminal are capital introduced, not spending; 9 rows £39,000 verified exact'),
  (170, 'Cornwall Cooling — ARE supplier', 'CORNWALL COOLING', NULL, '<', 0, ARRAY[2]::int[], 'supplier_payment', 0.90, 'mop-up 2026-07-10; 2 rows £2,763.60, invoice-referenced, clean blast radius'),
  (170, 'Berry Smith LLP — ARE professional fees', 'BERRY SMITH', NULL, '<', 0, ARRAY[2]::int[], 'professional_fees', 0.90, 'mop-up 2026-07-10; solicitor invoices on ARE account; debits only (a mirrored positive leg exists and is excluded by amount_op)'),
  (170, 'Reg Hambly — ARE Langholme maintenance', 'REG HAMBLY', NULL, '<', 0, ARRAY[2]::int[], 'supplier_payment', 0.88, 'mop-up 2026-07-10; recurring Langholme-referenced trade payments'),
  (175, 'Plumbase — ARE materials', '^PLUMBASE', NULL, '<', 0, ARRAY[2]::int[], 'supplier_payment', 0.90, 'mop-up 2026-07-10; 4 rows £1,167.76, invoice-referenced')
ON CONFLICT DO NOTHING;
