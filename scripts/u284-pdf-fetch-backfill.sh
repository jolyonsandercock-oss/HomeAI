#!/bin/bash
# u284-pdf-fetch-backfill.sh — fetch Gmail PDF attachments for stuck invoices
# (pdf_low_conf, no text, NO local pdf — 1,198 rows at build time) and persist
# them to storage/invoices/fetched/ so the u281 vision drain can process them.
#
# Per row: google-fetch /message/{acct}/{msgid} → first application/pdf part →
# /attachment/... → base64 → host file → UPDATE pdf_local_path/pdf_fetched_at.
# google-fetch is on ai-internal (host can't reach), so the HTTP happens inside
# bot-responder and bytes stream out over docker exec stdout.
# Idempotent: only rows with pdf_local_path IS NULL are selected. Gentle pace.
set -uo pipefail
OUT=/home_ai/storage/invoices/fetched
mkdir -p "$OUT"
LIMIT="${1:-1200}"

mapfile -t ROWS < <(docker exec -i homeai-postgres psql -d homeai -U postgres -tA -F'|' -c "
SET app.current_entity='all';
SELECT id, account, source_email_id FROM vendor_invoice_inbox
 WHERE extraction_method='pdf_low_conf'
   AND (pdf_text_extracted IS NULL OR pdf_text_extracted='')
   AND pdf_local_path IS NULL
   AND source_email_id ~ '^[0-9a-f]{12,}$'
   AND coalesce(pdf_fetch_error,'') NOT LIKE 'u284:%'
 ORDER BY received_at DESC LIMIT $LIMIT;" 2>/dev/null | grep -E '^[0-9]+\|')

total=${#ROWS[@]}
echo "$(date -Is) [u284] start: $total to fetch"
i=0; ok=0; fail=0
for row in "${ROWS[@]}"; do
  i=$((i+1))
  IFS='|' read -r ID ACCT MSGID <<< "$row"
  B64=$(docker exec -i -e ACCT="$ACCT" -e MSGID="$MSGID" homeai-bot-responder python3 - <<'PY' 2>/dev/null
import os, json, urllib.request, sys
a, m = os.environ["ACCT"], os.environ["MSGID"]
try:
    msg = json.loads(urllib.request.urlopen(f"http://google-fetch:8011/message/{a}/{m}", timeout=20).read())
    def walk(p):
        # Many senders ship PDFs as application/octet-stream — match by
        # mimeType OR a .pdf filename (2026-06-11 smoke-test finding).
        is_pdf = (p.get("mimeType") == "application/pdf"
                  or (p.get("filename") or "").lower().endswith(".pdf"))
        if is_pdf and p.get("body", {}).get("attachmentId"):
            return p["body"]["attachmentId"]
        for c in p.get("parts", []) or []:
            r = walk(c)
            if r: return r
    att = walk(msg.get("payload", msg))
    if not att:
        print("NOPDF"); sys.exit(0)
    data = json.loads(urllib.request.urlopen(f"http://google-fetch:8011/attachment/{a}/{m}/{att}", timeout=60).read())
    print(data.get("data_b64url") or "NODATA")
except Exception as e:
    print("ERR:" + str(e)[:80])
PY
)
  case "$B64" in
    NOPDF|NODATA|ERR:*|"")
      fail=$((fail+1))
      docker exec -i homeai-postgres psql -d homeai -U postgres -q -c "SET app.current_entity='all';
        UPDATE vendor_invoice_inbox SET pdf_fetch_error='u284: ${B64:-empty}' WHERE id=$ID;" 2>/dev/null
      echo "$(date -Is) [u284] [$i/$total] #$ID FAIL ${B64:-empty}"
      ;;
    *)
      F="$OUT/${ID}.pdf"
      # gmail uses base64url
      if printf '%s' "$B64" | python3 -c "import sys,base64;sys.stdout.buffer.write(base64.urlsafe_b64decode(sys.stdin.read().strip()+'=='))" > "$F" 2>/dev/null && [ -s "$F" ]; then
        docker exec -i homeai-postgres psql -d homeai -U postgres -q -c "SET app.current_entity='all';
          UPDATE vendor_invoice_inbox SET pdf_local_path='$F', pdf_fetched_at=now(), pdf_fetch_error=NULL WHERE id=$ID;" 2>/dev/null
        ok=$((ok+1))
        echo "$(date -Is) [u284] [$i/$total] #$ID ok ($(stat -c%s "$F")b)"
      else
        rm -f "$F"; fail=$((fail+1))
        docker exec -i homeai-postgres psql -d homeai -U postgres -q -c "SET app.current_entity='all';
          UPDATE vendor_invoice_inbox SET pdf_fetch_error='u284: b64-decode-fail' WHERE id=$ID;" 2>/dev/null
        echo "$(date -Is) [u284] [$i/$total] #$ID decode FAIL"
      fi
      ;;
  esac
  sleep 0.4
done
echo "$(date -Is) [u284] done: ok=$ok fail=$fail of $total"
