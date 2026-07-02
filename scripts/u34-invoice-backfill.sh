#!/bin/bash
# /home_ai/scripts/u34-invoice-backfill.sh
#
# Backfill vendor_invoice_inbox from Gmail (invoices@malthousetintagel.com
# and accounts@malthousetintagel.com aliases on the homeai-google-fetch
# sidecar) over the last DAYS_BACK days (default 100).
#
# Statement-vs-invoice classification, vendor categorisation, and PDF
# extraction are handled in separate steps (run after this backfill):
#   - u34-invoice-classify.sh  (statement/invoice + category)
#   - u34-invoice-pdf-extract.sh (net/vat/gross/lines)
#
# Idempotent — ON CONFLICT on idempotency_key.

set -euo pipefail
DAYS_BACK="${1:-100}"

VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e DAYS_BACK="$DAYS_BACK" homeai-playwright python << 'PYEOF'
import os, json, urllib.request, asyncio, asyncpg, hashlib
from datetime import datetime, timezone, timedelta

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN      = os.environ["PG_DSN"]
DAYS_BACK   = int(os.environ.get("DAYS_BACK", "100"))

GF_BASE = "http://google-fetch:8011"

def gf_get(path, **params):
    qs = "&".join(f"{k}={urllib.parse.quote(str(v))}" for k,v in params.items())
    url = f"{GF_BASE}{path}" + (f"?{qs}" if qs else "")
    r = urllib.request.urlopen(url, timeout=30)
    return json.loads(r.read())

def normalise_sender(from_user):
    if not from_user: return None
    import re
    m = re.search(r"<([^>]+@[^>]+)>", from_user)
    if m: return m.group(1).strip().lower()
    if "@" in from_user: return from_user.strip().lower()
    return None

def vendor_domain(sender):
    if not sender or "@" not in sender: return ""
    return sender.split("@", 1)[1].lower()

def has_pdf(payload):
    def walk(p):
        for part in p.get("parts", []) or []:
            mime = (part.get("mimeType") or "").lower()
            fn = (part.get("filename") or "").lower()
            if mime == "application/pdf" or fn.endswith(".pdf"):
                return True
            if walk(part):
                return True
        return False
    return walk(payload or {})

def likely_invoice_subject(subj):
    s = (subj or "").lower()
    return any(k in s for k in [
      "invoice", "statement", "credit note", "remittance",
      "delivery note", "purchase order", "receipt"
    ])

async def main():
    cutoff = datetime.now(timezone.utc) - timedelta(days=DAYS_BACK)
    # Per [[project_u9_google_identity]], invoices@/accounts@malthousetintagel.com
    # are aliases of admin@malthousetintagel.com (sendAs aliases, no per-alias mailbox).
    # So we search both admin and info mailboxes — invoices land in whichever
    # is the inbox receiving the alias forward.
    accounts = ["admin", "info"]
    seen = ingested = skipped = 0

    conn = await asyncpg.connect(PG_DSN)
    for acct in accounts:
        # google-fetch doesn't paginate (no next_page_token). We walk back
        # in date windows: fetch up to 100 messages between `after_cur` and
        # `before_cur`, then move `before_cur` to the oldest result and
        # repeat until we cross the cutoff or get fewer than 100 rows.
        after_str = cutoff.strftime("%Y/%m/%d")
        before_cur = datetime.now(timezone.utc) + timedelta(days=1)
        collected = []
        for _hop in range(20):  # safety cap — 20 × 100 = 2000 messages max
            before_str = before_cur.strftime("%Y/%m/%d")
            q = f"after:{after_str} before:{before_str} (has:attachment OR subject:invoice OR subject:statement OR subject:receipt)"
            try:
                resp = gf_get("/messages", account=acct, q=q, max_results=100)
            except Exception as e:
                print(f"[{acct}] list failed at before={before_str}: {e}")
                break
            msgs = resp.get("messages", [])
            if not msgs:
                break
            collected.extend(msgs)
            # Slide the before cursor back to the oldest message's date - 1d
            oldest_ms = min(int(m.get("internal_date") or 0) for m in msgs)
            if oldest_ms == 0: break
            new_before = datetime.fromtimestamp(oldest_ms/1000, tz=timezone.utc)
            if new_before <= cutoff: break
            if len(msgs) < 100: break
            before_cur = new_before
        print(f"[{acct}] {len(collected)} message stubs since {after_str}")

        for m in collected:
            seen += 1
            mid = m.get("id")
            if not mid: continue
            subj = (m.get("subject") or "")[:300]
            from_user = m.get("from") or ""
            sender = normalise_sender(from_user) or ""
            domain = vendor_domain(sender)
            internal_date = int(m.get("internal_date") or 0)
            received = (datetime.fromtimestamp(internal_date/1000, tz=timezone.utc)
                        if internal_date else datetime.now(timezone.utc))
            if received < cutoff:
                continue
            pdf = bool(m.get("has_attachment"))
            if not pdf and not likely_invoice_subject(subj):
                continue

            idem = hashlib.sha256(f"vii:{acct}:{mid}".encode()).hexdigest()[:48]
            try:
                async with conn.transaction():
                    await conn.execute("SET LOCAL app.current_entity = '1'")
                    await conn.execute("""
                      INSERT INTO vendor_invoice_inbox
                        (idempotency_key, source_email_id, account, entity_id,
                         vendor_domain, vendor_name, subject, received_at,
                         attachment_count, has_pdf, status)
                      VALUES ($1,$2,$3,1,$4,$5,$6,$7,$8,$9,'new')
                      ON CONFLICT (idempotency_key) DO NOTHING
                    """, idem, mid, acct, domain, from_user[:200], subj, received,
                         1 if pdf else 0, pdf)
                ingested += 1
            except Exception as e:
                skipped += 1
                # Don't print every failure; just count

    await conn.close()
    print(f"backfill complete: seen={seen} ingested={ingested} skipped={skipped}")

asyncio.run(main())
PYEOF
