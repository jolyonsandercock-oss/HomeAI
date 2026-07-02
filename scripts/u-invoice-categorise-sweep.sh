#!/usr/bin/env bash
# u-invoice-categorise-sweep.sh — Phase 3.1 forward categorisation.
# Applies vendor_category_rules (domain match, highest priority) to any invoice with
# NULL category_canonical, so v_daily_cost_vs_sales stays populated as new invoices
# arrive. Unmatched invoices are LEFT NULL and surfaced (count logged) for rule-adding
# — never guessed. J&R site=cafe -> cafe_stock. Off the n8n event path.
#
# KNOWN LIMITATION (follow-up): invoices forwarded THROUGH accounting platforms
# (intuit/xero/sage) carry the platform domain, so the platform's rule can mis-match
# (e.g. RCC Roofing via notification.intuit.com -> software). The rule system needs to
# distinguish platform-forwarded from platform-subscription invoices. Big mis-matches
# are caught by the >£1k review check below.
set -euo pipefail
LOGDIR=/home_ai/logs; mkdir -p "$LOGDIR"; LOG="$LOGDIR/invoice-categorise-sweep.log"
VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PG_PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/postgres 2>/dev/null)
{
echo "=== $(date -Is) invoice categorise sweep ==="
# Capture the real exit code via && / || on the heredoc's own command line —
# under set -e, a plain heredoc invocation here would abort the brace group
# before the "done" line (or the exit below) ever ran.
docker exec -i -e PGPASSWORD="$PG_PW" homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 <<'SQL' && rc=0 || rc=$?
UPDATE vendor_invoice_inbox v
SET vendor_category = (
  SELECT r.category FROM vendor_category_rules r
  WHERE CASE WHEN v.vendor_domain ~* '(intuit|xero|sage|quickbooks)' THEN v.vendor_name ~* r.domain_pattern ELSE (v.vendor_domain ~* r.domain_pattern OR v.vendor_name ~* r.domain_pattern) END
  ORDER BY r.priority ASC, length(r.domain_pattern) DESC LIMIT 1)
WHERE v.category_canonical IS NULL AND v.is_statement=false AND v.status NOT IN ('duplicate','ignored')
  AND EXISTS (SELECT 1 FROM vendor_category_rules r WHERE CASE WHEN v.vendor_domain ~* '(intuit|xero|sage|quickbooks)' THEN v.vendor_name ~* r.domain_pattern ELSE (v.vendor_domain ~* r.domain_pattern OR v.vendor_name ~* r.domain_pattern) END);
-- J&R cafe split
UPDATE vendor_invoice_inbox SET vendor_category='cafe_stock'
WHERE category_canonical='dry_purchase' AND site='cafe' AND vendor_name ~* 'j ?& ?r|jr food';
-- surface anything still uncategorised over £1k (needs a rule / review)
\echo 'Uncategorised >£1k (add a rule):'
SELECT regexp_replace(split_part(vendor_name,'<',1),'\s+$','') vendor, count(*), round(sum(COALESCE(net_amount,gross_amount,0))::numeric,0) net
FROM vendor_invoice_inbox WHERE category_canonical IS NULL AND is_statement=false AND status NOT IN ('duplicate','ignored')
  AND (invoice_date>=current_date-120 OR received_at>=current_date-120)
GROUP BY 1 HAVING sum(COALESCE(net_amount,gross_amount,0))>1000 ORDER BY 3 DESC LIMIT 10;
SQL
echo "=== $(date -Is) done (rc=$rc) ==="
} >> "$LOG" 2>&1
exit $rc
