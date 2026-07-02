#!/usr/bin/env bash
# u128-forward-orphans.sh — auto-forward aged orphan invoice emails to Dext.
#
# An "orphan" is a vendor_invoice_inbox row that has no matching xero_bills
# entry (xero_bill_id IS NULL). After 7 days un-entered in Xero, Dext is the
# second-string capture path: forward the original email (with attachments
# preserved) to malthousepub@dext.cc, then Dext extracts on its side.
#
# Uses the new /forward endpoint on google-fetch that re-uses raw RFC822,
# preserving every attachment.
#
# Cron: 30 7 * * *  (07:30 daily, after u128-xero-parse at 07:00)
#
# Args:
#   --dry-run     show what would be forwarded, don't send
#   --limit N     cap forwards per run (default 50)
#   --days N      window of orphans to consider (default 90)

set -euo pipefail

DRY=0
LIMIT=50
DAYS=90
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --limit)   LIMIT="$2"; shift 2 ;;
    --days)    DAYS="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

DEXT_ADDR="malthousepub@dext.cc"

echo "== u128-forward-orphans  (dry_run=$DRY  limit=$LIMIT  window=${DAYS}d → $DEXT_ADDR)"

# Pull eligible orphans inside the postgres container, format as TSV.
EXEC_LINES=$(docker exec -i homeai-postgres psql -U postgres -d homeai -tAF $'\t' <<SQL
SELECT inbox_id, COALESCE(account,''), source_email_id, vendor_name, invoice_date, age_days,
       COALESCE(gross_amount, amount_seen)::numeric(10,2)
  FROM v_xero_orphan_inbox
 WHERE needs_forward
   AND invoice_date >= CURRENT_DATE - $DAYS
   AND source_email_id IS NOT NULL
   AND account IN ('info','admin','jo','bot','pounana')
 ORDER BY age_days DESC, COALESCE(gross_amount, amount_seen) DESC NULLS LAST
 LIMIT $LIMIT;
SQL
)

if [[ -z "${EXEC_LINES// /}" ]]; then
  echo "  nothing to forward"
  exit 0
fi

COUNT=$(echo "$EXEC_LINES" | wc -l)
echo "  candidates: $COUNT"

OK=0; FAIL=0; SKIP=0
while IFS=$'\t' read -r INBOX_ID ACCOUNT MSG_ID VENDOR INV_DATE AGE GBP; do
  [[ -z "$MSG_ID" ]] && { SKIP=$((SKIP+1)); continue; }
  LBL="$(printf '%-30.30s' "$VENDOR") £${GBP}  ${AGE}d  ${INV_DATE}  [$ACCOUNT/$MSG_ID]"
  if [[ "$DRY" = "1" ]]; then
    echo "  DRY  → $LBL"
    OK=$((OK+1))
    continue
  fi
  # Call /forward via critical-listener (on the internal network).
  # Use python3 -c with positional args — bash heredocs eat the source
  # when piped through `docker exec -i` in this environment.
  RESP=$(docker exec homeai-critical-listener python3 -c '
import sys, urllib.request, urllib.parse
account, mid, dext = sys.argv[1:4]
url = f"http://google-fetch:8011/forward/{account}/{mid}?to={urllib.parse.quote(dext)}&prepend_subject=Fwd:%20"
try:
    r = urllib.request.urlopen(urllib.request.Request(url, method="POST"), timeout=30)
    print("OK", r.status, r.read()[:200].decode())
except urllib.error.HTTPError as e:
    print("ERR", e.code, e.read()[:300].decode())
except Exception as e:
    print("ERR -1", type(e).__name__, str(e)[:200])
' "$ACCOUNT" "$MSG_ID" "$DEXT_ADDR" 2>&1)
  if echo "$RESP" | grep -q '^OK 200'; then
    echo "  OK   → $LBL"
    docker exec homeai-postgres psql -U postgres -d homeai -tAc \
      "UPDATE vendor_invoice_inbox SET forwarded_to_dext_at = now() WHERE id = $INBOX_ID" >/dev/null \
      || echo "  WARN: forwarded_to_dext_at update failed for inbox_id=$INBOX_ID (email WAS forwarded — may re-forward next run)"
    OK=$((OK+1))
  else
    echo "  FAIL → $LBL  :: ${RESP:0:160}"
    FAIL=$((FAIL+1))
  fi
done <<< "$EXEC_LINES"

echo ""
echo "== Summary  forwarded=$OK  failed=$FAIL  skipped=$SKIP"

if [[ "$DRY" != "1" && $OK -gt 0 ]]; then
  bash /home_ai/.claude/scripts/notify-telegram.sh \
    "📤 Forwarded $OK orphan invoice email(s) to Dext (no Xero match >7d)" \
    "xero" >/dev/null 2>&1 || true
fi
