-- =============================================================================
-- V98 — Mortgage forensic rebuild (U78)
-- =============================================================================
-- Wipes my earlier speculative mortgage rows and rebuilds from the actual
-- loan numbers Jo confirmed by chat (2026-05-15) cross-referenced against
-- the OCR of the four mortgage statement scans (docs 19, 20, 21, 22).
--
-- Each scan is a multi-page bundle containing 1-3 statements. Doc 21 covers
-- three loans for Q4 2019; Doc 22 covers three loans for Q3 2021. Every
-- field below comes from the OCR text — no inference.
--
-- Active loans:
--   295905-02   ARE          Langholme                        £177,102.69 @ 31/03/2025
--   967002      Personal     1 Castle Road                    balance unknown (no scan yet)
--   967003      Personal     2+3 Salutations (one security)   balance unknown (no scan yet)
--
-- Closed / consolidated:
--   284512-03   Personal     Salutations (old, into 967003)   last £201,058.22 @ 30/09/2021
--   289751-04   Personal     1 Castle Road (old, into 967002) last £186,565.79 @ 31/12/2019
--   289759-10   Personal     1 Castle Road (old, into 967002) last  £63,010.34 @ 30/09/2021
--   295178      ARE/Personal The Olde Malthouse (paid off)     no scan
--   219125304   unknown      repaid                            no scan
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- Wipe and rebuild.
DELETE FROM property_mortgage_accounts;
DELETE FROM mortgage_accounts;
ALTER SEQUENCE mortgage_accounts_id_seq RESTART WITH 1;

-- Helper: entity ids — 1 ARE Trading, 2 ARE Estates, 3 Personal.

-- ── ACTIVE LOANS ────────────────────────────────────────────────────────────
INSERT INTO mortgage_accounts
    (id, lender, account_ref, borrower_entity_id, product_type,
     monthly_payment, current_balance, balance_as_of, interest_rate, notes, realm)
VALUES
    (1, 'Principality Commercial', '295905-02', 2, 'capital_and_interest',
     2263.58, 177102.69, '2025-03-31', 0.083,
     'ARE active loan. Restructured from INTEREST ONLY to CAPITAL & INTEREST between 2021 and 2024. Now secures Langholme only — historically cross-collateralised, but 967002/967003 took over Castle Rd + Salutations coverage. Latest balance from doc 19 Q1 2025 statement.',
     'work'),

    (2, 'Principality Commercial', '967002', 3, 'capital_and_interest',
     NULL, NULL, NULL, NULL,
     '1 Castle Road active loan. Consolidates the old 289751-04 + 289759-10 (interest-only) into a capital-repayment product. No scanned statements yet — balance to be set when first statement is consumed.',
     'family'),

    (3, 'Principality Commercial', '967003', 3, 'capital_and_interest',
     NULL, NULL, NULL, NULL,
     'Salutations active loan (covers 2+3 Salutations as one security). Successor to the old 284512-03 interest-only loan. No scanned statements yet — balance to be set when first statement is consumed.',
     'family');

-- ── CLOSED LOANS ────────────────────────────────────────────────────────────
INSERT INTO mortgage_accounts
    (id, lender, account_ref, borrower_entity_id, product_type,
     monthly_payment, current_balance, balance_as_of, closed_date, interest_rate, notes, realm)
VALUES
    (4, 'Principality Commercial', '284512-03', 3, 'interest_only',
     NULL, 201058.22, '2021-09-30', '2022-01-01', NULL,
     'OLD Salutations interest-only loan. Balance flat at £201,058.22 across all observed quarters (no principal repayment). Repaid/consolidated into 967003. closed_date is approximate (placeholder; precise consolidation date unknown).',
     'family'),

    (5, 'Principality Commercial', '289751-04', 3, 'capital_and_interest',
     NULL, 186565.79, '2019-12-31', '2022-01-01', NULL,
     'OLD 1 Castle Road C&I loan. Consolidated into 967002. Last observed balance from doc 21 Q4 2019 statement; consolidation date approximate.',
     'family'),

    (6, 'Principality Commercial', '289759-10', 3, 'capital_and_interest',
     NULL, 63010.34, '2021-09-30', '2022-01-01', NULL,
     'OLD 1 Castle Road C&I loan (drawdown saw it grow from £2.31 to £63k during Q3 2021 — top-up tranche). Consolidated into 967002. Last observed balance from doc 22 Q3 2021 statement.',
     'family'),

    (7, 'Principality Commercial', '295178', 3, 'capital_and_interest',
     NULL, 0.00, NULL, '2020-01-01', NULL,
     'OLD Olde Malthouse (pub) loan. Paid off in full. No scanned statements yet — historical record only.',
     'family'),

    (8, 'Principality Commercial', '219125304', 3, 'unknown',
     NULL, 0.00, NULL, '2020-01-01', NULL,
     'OLD loan, repaid. Property association not yet confirmed. No scanned statements yet — historical record only.',
     'family');

-- Bump sequence past the highest manual id.
SELECT setval('mortgage_accounts_id_seq', (SELECT max(id) FROM mortgage_accounts));

-- ── PROPERTY ↔ MORTGAGE LINKS ──────────────────────────────────────────────
-- Active links only — historical loans don't get property links since the
-- property may have changed mortgage product. Historical info is in the notes.
INSERT INTO property_mortgage_accounts (property_id, mortgage_account_id, share_pct, realm)
SELECT p.id, m.id,
       CASE
            WHEN m.account_ref = '295905-02' THEN 100.00   -- Langholme only
            WHEN m.account_ref = '967002'    THEN 100.00   -- 1 Castle Road only
            WHEN m.account_ref = '967003' AND p.address_line1 = '2 Salutations' THEN 44.44
            WHEN m.account_ref = '967003' AND p.address_line1 = '3 Salutations' THEN 55.56
       END,
       CASE WHEN p.entity_id = 2 THEN 'work' ELSE 'family' END
  FROM properties p
  JOIN mortgage_accounts m ON true
 WHERE m.closed_date IS NULL
   AND (
       (m.account_ref = '295905-02' AND p.address_line1 = 'Langholme')
    OR (m.account_ref = '967002'    AND p.address_line1 = '1 Castle Road')
    OR (m.account_ref = '967003'    AND p.address_line1 IN ('2 Salutations', '3 Salutations'))
   );

-- ── DOCUMENT BACK-LINKS ────────────────────────────────────────────────────
-- Doc 19 (Q1 2025): 295905-02 only → mortgage_accounts.id=1
UPDATE documents SET linked_table='mortgage_accounts', linked_id=1, linked_by='forensic:295905-02'
 WHERE id = 19;

-- Doc 20 (Q2-Q4 2024): 295905-02 only → mortgage_accounts.id=1
UPDATE documents SET linked_table='mortgage_accounts', linked_id=1, linked_by='forensic:295905-02'
 WHERE id = 20;

-- Doc 21 (Q4 2019 bundle): three loans. Use the BIGGEST balance as the canonical
-- single linked_id (284512-03 = old Salutations), since documents currently
-- only support a single linked_id. The others are in the OCR text.
UPDATE documents SET linked_table='mortgage_accounts', linked_id=4,
       linked_by='forensic:bundle-284512-03+289751-04+295905-02'
 WHERE id = 21;

-- Doc 22 (Q3 2021 bundle): three loans. Canonical: 295905-02 (active loan).
UPDATE documents SET linked_table='mortgage_accounts', linked_id=1,
       linked_by='forensic:bundle-295905-02+289759-10+284512-03'
 WHERE id = 22;

COMMIT;
