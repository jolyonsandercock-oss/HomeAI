-- stmt-sweep-20260705.sql
-- Financial-correctness sweep: supplier/bank STATEMENTS sitting in
-- vendor_invoice_inbox with is_statement=false AND gross_amount>0, which
-- double-count costs (their underlying invoices/transactions are booked
-- separately). Follow-up to scripts/oneoff/flagfix-20260703.sql (Capital on
-- Tap x12 + J&R id 17131).
--
-- Run as: docker exec -i homeai-postgres psql -U postgres -d homeai \
--           -v ON_ERROR_STOP=1 -f - < this file
--
-- Candidate query: is_statement=false AND gross_amount>0 AND
--   (subject/vendor_name/first_attachment_path ~* 'statement|stmt'
--    OR pdf_text_extracted ~* statement markers)  -> 109 candidates.
-- EVERY flagged row was verified by PDF evidence (pdf_text_extracted,
-- pdftotext over the local PDF, Gmail re-fetch via google-fetch, or vision
-- read of the rendered page for image-only id 10496). 38 candidates were
-- REJECTED as real invoices/receipts (36 Stripe "invoice+statements@" sender
-- receipts, Charles E Ware fee invoice id 1426, British Gas VAT bill id
-- 10119 whose filename merely says 'statement').
--
-- 71 confirmed rows, gross total 1,793,959.05, in 12 vendor groups.
-- Only is_statement flips; status/gross/notes untouched.
-- Backup: _backup_stmt_sweep_20260705 (all 71 rows, pre-update).
--
-- Notable sub-populations:
--  * natwest (15 rows, 1,214,760.89): NatWest bank/loan statements forwarded
--    to the accountant and mis-ingested as invoices ("gross" is a page-1
--    balance/paid-in figure). Truth lives in public.bank_transactions.
--  * cap_on_tap (4 rows, 106,483.42): Capital on Tap monthly statements the
--    2026-07-03 flagfix missed (older/newer forwards), incl. id 9821
--    ("Re: Meeting Tomorrow", 8,883.73) = CoT statement 21-03-2024..20-04-2024,
--    Closing Balance 8,883.73 paid by Direct Debit — verdict: statement.
--  * completion (1 row, 375,000.00): 2018 sale completion statement for
--    113 Egloshayle Road (Jo is the SELLER — sale proceeds, not a cost).
--  * booking (8 rows, 12,929.78): Booking.com "Statement of Accounts";
--    6 already status='ignored' (no cost impact — flag is metadata
--    correction), 2 needs_review forwards (17106/17107) did double-count.
--  * duplicate statements noted (same doc, multiple rows): 10171=10177,
--    9814=9815, 16640/16697/16748/17197/17241 (x5), 17193=17237,
--    14608/16032/16033 (x3), 10800=10801, 10027=14663, booking pairs.
--    All become is_statement=true so no residual double-count.

SET app.current_entity = 'all';
SET app.current_realm = 'owner';

BEGIN;

CREATE TABLE _backup_stmt_sweep_20260705 AS
SELECT * FROM vendor_invoice_inbox
WHERE id IN (
  9752,9821,17193,17237,                                              -- cap_on_tap
  9796,9814,9815,9858,9872,9883,9884,9885,9894,10171,10176,10177,
  10360,10446,10733,                                                  -- natwest
  10806,                                                              -- completion
  10496,10148,9994,9912,9838,10781,16640,16697,16748,17197,17241,     -- accountants
  17106,17107,10811,10812,10831,10832,10878,10879,                    -- booking
  10718,14608,16032,16033,1706,1600,5324,1150,                        -- tintagel_brewery
  8633,10701,10703,10800,10801,15277,15342,                           -- gclimo
  15664,10027,14663,13034,13003,                                      -- cpnitro
  9010,9006,8816,5305,                                                -- forest
  5301,5290,                                                          -- staustell
  16026,                                                              -- brewer_bunney
  17086,17088,17117,17158,16785                                       -- misc
);

DO $$
DECLARE n int; g numeric;
BEGIN
  SELECT count(*), sum(gross_amount) INTO n, g FROM _backup_stmt_sweep_20260705;
  IF n <> 71 OR g <> 1793959.05 THEN
    RAISE EXCEPTION 'backup pre-check failed: n=% gross=% (expected 71 / 1793959.05)', n, g;
  END IF;
  IF EXISTS (SELECT 1 FROM _backup_stmt_sweep_20260705 WHERE is_statement) THEN
    RAISE EXCEPTION 'backup pre-check failed: some rows already is_statement=true';
  END IF;
END $$;

COMMIT;

-- ========================================================================
-- One transaction per vendor group; each asserts its own count + gross.
-- ========================================================================

-- Capital on Tap monthly statements (fwd-chained; card spend booked via
-- card_statements/bank pipelines). 17193=17237 dup forwards of Mar-Apr 2026.
BEGIN;
UPDATE vendor_invoice_inbox SET is_statement = true
WHERE id IN (9752,9821,17193,17237) AND is_statement = false;
DO $$
DECLARE n int; g numeric;
BEGIN
  SELECT count(*), sum(gross_amount) INTO n, g FROM vendor_invoice_inbox
  WHERE id IN (9752,9821,17193,17237) AND is_statement;
  IF n <> 4 OR g <> 106483.42 THEN RAISE EXCEPTION 'cap_on_tap: n=% g=%', n, g; END IF;
END $$;
COMMIT;

-- NatWest bank/loan statements (Statement_600001_* / Statement--600001-* /
-- personal-loan 'statements.pdf' / 521047 Estates acct). Verified by PDF text:
-- 'Statement / Account number / Sort code / Previous Balance'. Truth =
-- public.bank_transactions; these rows were pure double-count.
BEGIN;
UPDATE vendor_invoice_inbox SET is_statement = true
WHERE id IN (9796,9814,9815,9858,9872,9883,9884,9885,9894,10171,10176,10177,10360,10446,10733)
  AND is_statement = false;
DO $$
DECLARE n int; g numeric;
BEGIN
  SELECT count(*), sum(gross_amount) INTO n, g FROM vendor_invoice_inbox
  WHERE id IN (9796,9814,9815,9858,9872,9883,9884,9885,9894,10171,10176,10177,10360,10446,10733)
    AND is_statement;
  IF n <> 15 OR g <> 1214760.89 THEN RAISE EXCEPTION 'natwest: n=% g=%', n, g; END IF;
END $$;
COMMIT;

-- Sale completion statement, 113 Egloshayle Road (03/09/2018): Jo is the
-- seller; 375,000 = sale proceeds. A statement document, never a cost.
BEGIN;
UPDATE vendor_invoice_inbox SET is_statement = true
WHERE id = 10806 AND is_statement = false;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vendor_invoice_inbox WHERE id = 10806 AND is_statement) THEN
    RAISE EXCEPTION 'completion: id 10806 not flagged';
  END IF;
END $$;
COMMIT;

-- Accountant statements of account (ATC Advisors / Hodgsons: SAN031,
-- ATL002/003/004 layouts, 'STATEMENT OF ACCOUNT' + Debit/Credit/Balance).
-- 16640/16697/16748/17197/17241 = the SAME 15/04/2026 ATL002 statement
-- (1,392.00) forwarded five times.
BEGIN;
UPDATE vendor_invoice_inbox SET is_statement = true
WHERE id IN (10496,10148,9994,9912,9838,10781,16640,16697,16748,17197,17241)
  AND is_statement = false;
DO $$
DECLARE n int; g numeric;
BEGIN
  SELECT count(*), sum(gross_amount) INTO n, g FROM vendor_invoice_inbox
  WHERE id IN (10496,10148,9994,9912,9838,10781,16640,16697,16748,17197,17241)
    AND is_statement;
  IF n <> 11 OR g <> 10725.20 THEN RAISE EXCEPTION 'accountants: n=% g=%', n, g; END IF;
END $$;
COMMIT;

-- Booking.com 'Statement of Accounts' (commission summaries, brought-forward
-- balance). 6 rows already status='ignored' (metadata-only fix); 17106/17107
-- (needs_review) were live double-counts.
BEGIN;
UPDATE vendor_invoice_inbox SET is_statement = true
WHERE id IN (17106,17107,10811,10812,10831,10832,10878,10879)
  AND is_statement = false;
DO $$
DECLARE n int; g numeric;
BEGIN
  SELECT count(*), sum(gross_amount) INTO n, g FROM vendor_invoice_inbox
  WHERE id IN (17106,17107,10811,10812,10831,10832,10878,10879) AND is_statement;
  IF n <> 8 OR g <> 12929.78 THEN RAISE EXCEPTION 'booking: n=% g=%', n, g; END IF;
END $$;
COMMIT;

-- Tintagel Brewery Ltd / Tintagel Brewing Company statements ('STATEMENT NO.
-- x, TOTAL DUE £y' + open-invoice list). 14608/16032/16033 = statement 8237
-- (5,049.36) x3 rows.
BEGIN;
UPDATE vendor_invoice_inbox SET is_statement = true
WHERE id IN (10718,14608,16032,16033,1706,1600,5324,1150) AND is_statement = false;
DO $$
DECLARE n int; g numeric;
BEGIN
  SELECT count(*), sum(gross_amount) INTO n, g FROM vendor_invoice_inbox
  WHERE id IN (10718,14608,16032,16033,1706,1600,5324,1150) AND is_statement;
  IF n <> 8 OR g <> 35759.66 THEN RAISE EXCEPTION 'tintagel_brewery: n=% g=%', n, g; END IF;
END $$;
COMMIT;

-- G Climo & Sons / Tintagel Skip Hire statements (transactions + Balance +
-- Amount Due layout). 10800=10801 dup; 10703 re-send of the 408.00 statement.
BEGIN;
UPDATE vendor_invoice_inbox SET is_statement = true
WHERE id IN (8633,10701,10703,10800,10801,15277,15342) AND is_statement = false;
DO $$
DECLARE n int; g numeric;
BEGIN
  SELECT count(*), sum(gross_amount) INTO n, g FROM vendor_invoice_inbox
  WHERE id IN (8633,10701,10703,10800,10801,15277,15342) AND is_statement;
  IF n <> 7 OR g <> 8076.76 THEN RAISE EXCEPTION 'gclimo: n=% g=%', n, g; END IF;
END $$;
COMMIT;

-- CP Nitro statements. 10027=14663 dup pair.
BEGIN;
UPDATE vendor_invoice_inbox SET is_statement = true
WHERE id IN (15664,10027,14663,13034,13003) AND is_statement = false;
DO $$
DECLARE n int; g numeric;
BEGIN
  SELECT count(*), sum(gross_amount) INTO n, g FROM vendor_invoice_inbox
  WHERE id IN (15664,10027,14663,13034,13003) AND is_statement;
  IF n <> 5 OR g <> 1109.55 THEN RAISE EXCEPTION 'cpnitro: n=% g=%', n, g; END IF;
END $$;
COMMIT;

-- Forest Produce sales-ledger statements (A/c MALTHOUS, 'STATEMENT' + aged
-- balances).
BEGIN;
UPDATE vendor_invoice_inbox SET is_statement = true
WHERE id IN (9010,9006,8816,5305) AND is_statement = false;
DO $$
DECLARE n int; g numeric;
BEGIN
  SELECT count(*), sum(gross_amount) INTO n, g FROM vendor_invoice_inbox
  WHERE id IN (9010,9006,8816,5305) AND is_statement;
  IF n <> 4 OR g <> 21239.24 THEN RAISE EXCEPTION 'forest: n=% g=%', n, g; END IF;
END $$;
COMMIT;

-- St Austell Brewery customer statements (acct 439165), Jan 2026 x2.
BEGIN;
UPDATE vendor_invoice_inbox SET is_statement = true
WHERE id IN (5301,5290) AND is_statement = false;
DO $$
DECLARE n int; g numeric;
BEGIN
  SELECT count(*), sum(gross_amount) INTO n, g FROM vendor_invoice_inbox
  WHERE id IN (5301,5290) AND is_statement;
  IF n <> 2 OR g <> 6007.80 THEN RAISE EXCEPTION 'staustell: n=% g=%', n, g; END IF;
END $$;
COMMIT;

-- Brewer & Bunney 'ACCOUNT STATEMENT' 28/03/2023.
BEGIN;
UPDATE vendor_invoice_inbox SET is_statement = true
WHERE id = 16026 AND is_statement = false;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vendor_invoice_inbox WHERE id = 16026 AND is_statement) THEN
    RAISE EXCEPTION 'brewer_bunney: id 16026 not flagged';
  END IF;
END $$;
COMMIT;

-- Misc single-vendor statements: Western Office Equipment (17086), Jo Wood
-- Xero statement (17088), Hop Oils (17117), Debonair/Gems Hygiene (17158),
-- Tamar Koffi (16785). All show statement layouts with balance/aged totals.
BEGIN;
UPDATE vendor_invoice_inbox SET is_statement = true
WHERE id IN (17086,17088,17117,17158,16785) AND is_statement = false;
DO $$
DECLARE n int; g numeric;
BEGIN
  SELECT count(*), sum(gross_amount) INTO n, g FROM vendor_invoice_inbox
  WHERE id IN (17086,17088,17117,17158,16785) AND is_statement;
  IF n <> 5 OR g <> 1662.75 THEN RAISE EXCEPTION 'misc: n=% g=%', n, g; END IF;
END $$;
COMMIT;

-- ========================================================================
-- Final cross-foot: all 71 flagged, total matches the backup.
-- ========================================================================
DO $$
DECLARE n int; g numeric;
BEGIN
  SELECT count(*), sum(v.gross_amount) INTO n, g
  FROM vendor_invoice_inbox v
  JOIN _backup_stmt_sweep_20260705 b ON b.id = v.id
  WHERE v.is_statement;
  IF n <> 71 OR g <> 1793959.05 THEN
    RAISE EXCEPTION 'final cross-foot failed: n=% gross=% (expected 71 / 1793959.05)', n, g;
  END IF;
  RAISE NOTICE 'stmt-sweep-20260705 complete: 71 rows flagged, gross 1793959.05';
END $$;

-- Rollback (if ever needed):
--   UPDATE vendor_invoice_inbox v SET is_statement = b.is_statement
--   FROM _backup_stmt_sweep_20260705 b WHERE v.id = b.id;
