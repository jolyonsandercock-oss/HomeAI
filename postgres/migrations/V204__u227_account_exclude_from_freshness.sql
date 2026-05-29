-- V204 / U227 T5 — exclude_from_freshness flag on bank_accounts and
-- mortgage_accounts. Lets us mark dormant/predecessor accounts as
-- "don't nag me about this" without deleting historical rows.
--
-- Replaces the name-substring heuristic ("dormant" / "predecessor")
-- currently used in u35-manual-data-freshness.sh + u35-upload-tasks-email.py.

BEGIN;

ALTER TABLE bank_accounts
  ADD COLUMN IF NOT EXISTS exclude_from_freshness boolean NOT NULL DEFAULT false;

ALTER TABLE mortgage_accounts
  ADD COLUMN IF NOT EXISTS exclude_from_freshness boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN bank_accounts.exclude_from_freshness IS
  'When true, this account is hidden from u35-manual-data-freshness reports. '
  'Use for dormant accounts, statement archives, or accounts intentionally not reconciled.';

COMMENT ON COLUMN mortgage_accounts.exclude_from_freshness IS
  'When true, this mortgage is hidden from u35-manual-data-freshness reports. '
  'closed_date already covers most cases; this is for "still open but I do not import statements".';

-- Initial flag-set: replace the name-substring filter so behaviour stays
-- identical to today, plus a few explicitly low-activity ones surfaced
-- by the 2026-05-29 audit.
UPDATE bank_accounts SET exclude_from_freshness = true
 WHERE account_name ILIKE '%dormant%'
    OR account_name ILIKE '%predecessor%';

-- Tax Reserve has been silent 5+ years and is intentionally low-activity.
UPDATE bank_accounts SET exclude_from_freshness = true
 WHERE account_name ILIKE '%Tax Reserve%';

COMMIT;
