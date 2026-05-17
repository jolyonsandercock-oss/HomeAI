#!/usr/bin/env bash
# u128-email-vs-xero-diff.sh — surface vendor_invoice_inbox rows that have NO
# matching xero_bills entry. These are the "orphans" — bills we received via
# email but Jo hasn't entered into Xero. Aged orphans (>7d) get auto-forwarded
# to Dext by u128-forward-orphans.sh.
#
# Usage:
#   u128-email-vs-xero-diff.sh                # last 100 days, summary only
#   u128-email-vs-xero-diff.sh --days 365     # widen window
#   u128-email-vs-xero-diff.sh --detail       # full row list

set -uo pipefail

DAYS=100
DETAIL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --detail) DETAIL=1; shift ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

docker exec -i homeai-postgres psql -U postgres -d homeai <<SQL
SELECT home_ai.set_realm('owner');
SET app.current_entity='all';

\echo '== ORPHAN SUMMARY (last $DAYS days) =='

WITH window AS (
  SELECT *
    FROM v_xero_orphan_inbox
   WHERE invoice_date >= CURRENT_DATE - $DAYS
)
SELECT
  COUNT(*)                                                    AS orphans,
  COUNT(*) FILTER (WHERE age_days > 7  AND forwarded_to_dext_at IS NULL) AS overdue_to_forward,
  COUNT(*) FILTER (WHERE forwarded_to_dext_at IS NOT NULL)    AS already_forwarded,
  SUM(COALESCE(gross_amount, amount_seen, 0))                 AS gbp_exposure
  FROM window;

\echo ''
\echo '── Top orphan vendors (£ exposure):'
SELECT vendor_name,
       COUNT(*) AS n,
       SUM(COALESCE(gross_amount, amount_seen, 0)) AS gbp,
       MIN(invoice_date) || ' → ' || MAX(invoice_date) AS span
  FROM v_xero_orphan_inbox
 WHERE invoice_date >= CURRENT_DATE - $DAYS
 GROUP BY 1
 ORDER BY 3 DESC NULLS LAST
 LIMIT 10;

\echo ''
\echo '── Orphans ready to forward (>7d, not yet forwarded):'
SELECT vendor_name, invoice_date, age_days,
       COALESCE(gross_amount, amount_seen)::text AS gbp,
       first_attachment_path IS NOT NULL AS has_pdf
  FROM v_xero_orphan_inbox
 WHERE needs_forward
   AND invoice_date >= CURRENT_DATE - $DAYS
 ORDER BY age_days DESC
 LIMIT 20;

$([ "$DETAIL" = "1" ] && echo "
\echo ''
\echo '== DETAIL — every orphan in window =='
SELECT inbox_id, vendor_name, invoice_date, age_days,
       COALESCE(gross_amount, amount_seen) AS gbp,
       account, source_email_id, forwarded_to_dext_at
  FROM v_xero_orphan_inbox
 WHERE invoice_date >= CURRENT_DATE - $DAYS
 ORDER BY age_days DESC;")
SQL
