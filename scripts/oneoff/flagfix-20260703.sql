-- flagfix-20260703.sql
-- Surgical repair of three cost-view defects in vendor_invoice_inbox.
-- Run as: docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f - < this file
--
-- Defect 1: 12 Capital on Tap monthly statements (11 Fwd-chained forwards of the
--   Mar/Apr 2026 statements + 1 direct Jun 2026 statement) sitting with
--   is_statement=false, gross total 394,161.40. Card spend already arrives via
--   card_statements/bank pipelines, so these double-count costs in
--   v_daily_cost_vs_sales. Fix: is_statement=true.
--   (Brief said ~56 rows; actual verified population is 12 gross-bearing rows,
--   but the pound total matches the brief's ~392k. PDFs verified as
--   Statement_<period>.pdf period summaries.)
--
-- Defect 2: extraction junk outliers.
--   id 10302: 10,000,000.00 = Employers Liability indemnity limit from
--     POL22_PLCoverConfirmationTP.pdf (Reg Hambly insurance broker letter, not an
--     invoice). Verified by re-fetching the source PDF from Gmail.
--   id 1967: 275,000.00 = property sale price from Engrossed_contract_14.02.24.pdf
--     (sale of 1 Salutations; Jo is the SELLER). Not an invoice.
--   Fix: status='ignored' + notes tag (established junk convention, cf.
--   'bulk-triaged-noise-20260615'; the cost view excludes status ignored/duplicate).
--   Rows NOT deleted; gross_amount left intact as evidence.
--
-- Defect 3: vendor_category_rules id 13 (domain 'caterbook') = 'Bookings', and
--   vendor_category_canonical('Bookings') -> 'income'. Caterbook is the
--   room-booking SaaS we PAY for; its real invoices (via post.xero.com) are
--   already 'Software'. Fix rule -> 'Software' and re-categorise the 5 affected
--   inbox rows (all NULL gross; support emails + one GoCardless DD notice).
--   category_canonical is STORED GENERATED from vendor_category — we only touch
--   the source column; the generated column follows.

SET app.current_entity = 'all';
SET app.current_realm = 'owner';

-- =========================================================================
-- Defect 1: Capital on Tap statements -> is_statement=true
-- =========================================================================
BEGIN;

CREATE TABLE _backup_flagfix_20260703_1 AS
SELECT * FROM vendor_invoice_inbox
WHERE id IN (16572,16637,16644,16701,16752,16851,16898,16935,16977,17038,17090,17154);

DO $$
DECLARE n int; g numeric;
BEGIN
  SELECT count(*), sum(gross_amount) INTO n, g FROM _backup_flagfix_20260703_1;
  IF n <> 12 OR g <> 394161.40 THEN
    RAISE EXCEPTION 'Defect 1 pre-check failed: n=% gross=% (expected 12 / 394161.40)', n, g;
  END IF;
  IF EXISTS (SELECT 1 FROM _backup_flagfix_20260703_1 WHERE is_statement) THEN
    RAISE EXCEPTION 'Defect 1 pre-check failed: some rows already is_statement=true';
  END IF;
END $$;

UPDATE vendor_invoice_inbox
SET is_statement = true
WHERE id IN (16572,16637,16644,16701,16752,16851,16898,16935,16977,17038,17090,17154)
  AND is_statement = false;

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM vendor_invoice_inbox
  WHERE id IN (16572,16637,16644,16701,16752,16851,16898,16935,16977,17038,17090,17154)
    AND is_statement = true;
  IF n <> 12 THEN RAISE EXCEPTION 'Defect 1 post-check failed: % of 12 flagged', n; END IF;
END $$;

COMMIT;

-- =========================================================================
-- Defect 2: junk outliers 10302 (10,000,000) and 1967 (275,000) -> ignored
-- =========================================================================
BEGIN;

CREATE TABLE _backup_flagfix_20260703_2 AS
SELECT * FROM vendor_invoice_inbox WHERE id IN (10302, 1967);

DO $$
DECLARE n int; g numeric;
BEGIN
  SELECT count(*), sum(gross_amount) INTO n, g FROM _backup_flagfix_20260703_2;
  IF n <> 2 OR g <> 10275000.00 THEN
    RAISE EXCEPTION 'Defect 2 pre-check failed: n=% gross=% (expected 2 / 10275000.00)', n, g;
  END IF;
  IF EXISTS (SELECT 1 FROM _backup_flagfix_20260703_2 WHERE status <> 'needs_review') THEN
    RAISE EXCEPTION 'Defect 2 pre-check failed: unexpected status';
  END IF;
END $$;

UPDATE vendor_invoice_inbox
SET status = 'ignored',
    notes  = 'junk-outlier-flagfix-20260703: gross=10,000,000 is the Employers Liability indemnity limit from POL22_PLCoverConfirmationTP.pdf (insurance cover confirmation, not an invoice)'
WHERE id = 10302 AND status = 'needs_review';

UPDATE vendor_invoice_inbox
SET status = 'ignored',
    notes  = 'junk-outlier-flagfix-20260703: gross=275,000 is the property sale price from Engrossed_contract_14.02.24.pdf (sale of 1 Salutations; we are the seller, not an invoice)'
WHERE id = 1967 AND status = 'needs_review';

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM vendor_invoice_inbox
  WHERE id IN (10302, 1967) AND status = 'ignored';
  IF n <> 2 THEN RAISE EXCEPTION 'Defect 2 post-check failed: % of 2 ignored', n; END IF;
END $$;

COMMIT;

-- =========================================================================
-- Defect 3: Caterbook rule Bookings->income mis-categorisation
-- =========================================================================
BEGIN;

CREATE TABLE _backup_flagfix_20260703_3_rule AS
SELECT * FROM vendor_category_rules WHERE id = 13;

CREATE TABLE _backup_flagfix_20260703_3 AS
SELECT * FROM vendor_invoice_inbox
WHERE id IN (14916, 14910, 13941, 13931, 17124);

DO $$
DECLARE n int; g numeric;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM _backup_flagfix_20260703_3_rule
                 WHERE domain_pattern = 'caterbook' AND category = 'Bookings') THEN
    RAISE EXCEPTION 'Defect 3 pre-check failed: rule 13 is not caterbook/Bookings';
  END IF;
  SELECT count(*), sum(gross_amount) INTO n, g FROM _backup_flagfix_20260703_3;
  IF n <> 5 OR g IS NOT NULL THEN
    RAISE EXCEPTION 'Defect 3 pre-check failed: n=% gross=% (expected 5 / NULL)', n, g;
  END IF;
  IF EXISTS (SELECT 1 FROM _backup_flagfix_20260703_3 WHERE vendor_category <> 'Bookings') THEN
    RAISE EXCEPTION 'Defect 3 pre-check failed: unexpected vendor_category';
  END IF;
END $$;

UPDATE vendor_category_rules
SET category = 'Software',
    notes = COALESCE(notes || ' | ', '') ||
            'flagfix-20260703: was Bookings (canonical income); Caterbook is a SaaS we pay for, matches its post.xero.com invoice rows'
WHERE id = 13 AND category = 'Bookings';

-- vendor_category is the SOURCE column; category_canonical is STORED GENERATED
-- and recomputes on this UPDATE. Never set category_canonical directly.
UPDATE vendor_invoice_inbox
SET vendor_category = 'Software'
WHERE id IN (14916, 14910, 13941, 13931, 17124)
  AND vendor_category = 'Bookings';

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM vendor_invoice_inbox
  WHERE id IN (14916, 14910, 13941, 13931, 17124)
    AND vendor_category = 'Software' AND category_canonical = 'software';
  IF n <> 5 THEN RAISE EXCEPTION 'Defect 3 post-check failed: % of 5 recategorised', n; END IF;
  IF (SELECT category FROM vendor_category_rules WHERE id = 13) <> 'Software' THEN
    RAISE EXCEPTION 'Defect 3 post-check failed: rule 13 not Software';
  END IF;
END $$;

COMMIT;

-- =========================================================================
-- Rollback recipe (reversible via backup tables):
--   UPDATE vendor_invoice_inbox v SET is_statement=b.is_statement
--     FROM _backup_flagfix_20260703_1 b WHERE v.id=b.id;
--   UPDATE vendor_invoice_inbox v SET status=b.status, notes=b.notes
--     FROM _backup_flagfix_20260703_2 b WHERE v.id=b.id;
--   UPDATE vendor_invoice_inbox v SET vendor_category=b.vendor_category
--     FROM _backup_flagfix_20260703_3 b WHERE v.id=b.id;
--   UPDATE vendor_category_rules r SET category=b.category, notes=b.notes
--     FROM _backup_flagfix_20260703_3_rule b WHERE r.id=b.id;
-- =========================================================================
