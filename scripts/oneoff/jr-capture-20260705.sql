-- jr-capture-20260705.sql
-- J&R Foodservice invoice-capture closure (2026-07-05).
-- Run: docker exec -i homeai-postgres psql -U postgres -d homeai
-- Always: SET app.current_entity='all'; SET app.current_realm='owner'; first.
--
-- Step 4: match the 71 unlinked 2026 xero_bills (contact_name J&R) against
-- vendor_invoice_inbox on (a) invoice number parsed from the "jrf: <ACCT> INV/CRD <num>"
-- subject line, or (b) date +/-3d AND amount +/-0.02. Sets xero_bill_id on matches.
-- No deletes. Backup + cross-foot counts printed before/after.

SET app.current_entity='all';
SET app.current_realm='owner';

-- ---- backup (unlinked xero_bills rows touched by this step) ----
DROP TABLE IF EXISTS _backup_jr_xero_link;
CREATE TABLE _backup_jr_xero_link AS
SELECT xb.* FROM xero_bills xb
WHERE xb.id NOT IN (SELECT xero_bill_id FROM vendor_invoice_inbox WHERE xero_bill_id IS NOT NULL)
  AND (xb.contact_name ILIKE '%J%R%Food%' OR xb.contact_name ILIKE '%jrf%');

SELECT 'backed_up' AS step, count(*) FROM _backup_jr_xero_link;

-- ---- cross-foot before ----
SELECT 'before_unlinked' AS step, count(*), sum(total)
FROM xero_bills xb
WHERE xb.id IN (SELECT id FROM _backup_jr_xero_link) AND xb.id NOT IN (
  SELECT xero_bill_id FROM vendor_invoice_inbox WHERE xero_bill_id IS NOT NULL
);

-- ---- candidate match set: build normalized invoice-number keys on the inbox side ----
DROP TABLE IF EXISTS _jr_inbox_keyed;
CREATE TEMP TABLE _jr_inbox_keyed AS
SELECT id, invoice_date, gross_amount, xero_bill_id,
       regexp_replace(subject, '.*(INV|CRD)\s+(\d+).*', '\2') AS inv_num
FROM vendor_invoice_inbox
WHERE vendor_domain = 'jrf.lls.com';

-- (a) exact invoice-number match (only against inbox rows not already linked)
DROP TABLE IF EXISTS _jr_match_by_number;
CREATE TEMP TABLE _jr_match_by_number AS
SELECT DISTINCT ON (xb.id) xb.id AS xero_bill_id, k.id AS inbox_id
FROM xero_bills xb
JOIN _jr_inbox_keyed k ON k.inv_num = xb.invoice_number AND k.xero_bill_id IS NULL
WHERE xb.id IN (SELECT id FROM _backup_jr_xero_link)
ORDER BY xb.id, k.id;

SELECT 'matched_by_number' AS step, count(*) FROM _jr_match_by_number;

-- (b) date +/-3d AND amount +/-0.02, only for xero_bills not matched in (a),
-- against inbox rows not already linked and not already claimed by (a) in this run
DROP TABLE IF EXISTS _jr_match_by_date_amount;
CREATE TEMP TABLE _jr_match_by_date_amount AS
SELECT DISTINCT ON (xb.id) xb.id AS xero_bill_id, k.id AS inbox_id
FROM xero_bills xb
JOIN _jr_inbox_keyed k
  ON k.xero_bill_id IS NULL
 AND k.id NOT IN (SELECT inbox_id FROM _jr_match_by_number)
 AND k.gross_amount IS NOT NULL
 AND abs(k.gross_amount - xb.total) <= 0.02
 AND k.invoice_date IS NOT NULL
 AND abs(k.invoice_date - xb.invoice_date) <= 3
WHERE xb.id IN (SELECT id FROM _backup_jr_xero_link)
  AND xb.id NOT IN (SELECT xero_bill_id FROM _jr_match_by_number)
ORDER BY xb.id, k.id;

SELECT 'matched_by_date_amount' AS step, count(*) FROM _jr_match_by_date_amount;

-- ---- apply: set xero_bill_id on the matched inbox rows ----
UPDATE vendor_invoice_inbox v
SET xero_bill_id = m.xero_bill_id
FROM _jr_match_by_number m
WHERE v.id = m.inbox_id AND v.xero_bill_id IS NULL;

UPDATE vendor_invoice_inbox v
SET xero_bill_id = m.xero_bill_id
FROM _jr_match_by_date_amount m
WHERE v.id = m.inbox_id AND v.xero_bill_id IS NULL;

-- ---- cross-foot after ----
SELECT 'after_unlinked' AS step, count(*), sum(total)
FROM xero_bills xb
WHERE xb.id IN (SELECT id FROM _backup_jr_xero_link) AND xb.id NOT IN (
  SELECT xero_bill_id FROM vendor_invoice_inbox WHERE xero_bill_id IS NOT NULL
);

-- ---- the true missing-invoice list: xero bills with NO inbox match at all after both passes ----
SELECT xb.invoice_number, xb.invoice_date, xb.total, xb.contact_name
FROM xero_bills xb
WHERE xb.id IN (SELECT id FROM _backup_jr_xero_link)
  AND xb.id NOT IN (SELECT xero_bill_id FROM vendor_invoice_inbox WHERE xero_bill_id IS NOT NULL)
ORDER BY xb.invoice_date;
