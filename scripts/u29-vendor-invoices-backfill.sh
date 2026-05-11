#!/bin/bash
# /home_ai/scripts/u29-vendor-invoices-backfill.sh
#
# Bulk-ingest the last N days of likely-invoice emails from info@malthousetintagel.com
# into vendor_invoice_inbox. Lightweight metadata only — full Haiku extraction
# is Pipeline 2 territory (triggered downstream off these rows when ready).
#
# Filter: emails to info@ with subject containing invoice / receipt / statement
# / remittance / bill — minus known booking-noise senders.
#
# Usage:
#   ./scripts/u29-vendor-invoices-backfill.sh           # last 30 days
#   ./scripts/u29-vendor-invoices-backfill.sh 90        # last 90 days

set -uo pipefail
DAYS="${1:-30}"

# Noise senders we explicitly skip (booking platforms — not real invoices)
NOISE_DOMAINS=("booking.com" "guest.booking.com" "trip.com"
               "partners.collinsbookings.com" "caterbook.net"
               "post.xero.com")

VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e DAYS="$DAYS" -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, urllib.request, urllib.parse, re
from datetime import datetime
import asyncpg

DAYS = int(os.environ["DAYS"])
PG_DSN = os.environ["PG_DSN"]
NOISE = {"booking.com", "guest.booking.com", "trip.com",
         "partners.collinsbookings.com", "caterbook.net",
         "post.xero.com", ""}

# Crude amount regex — first occurrence of £NN.NN in subject
AMOUNT_RE = re.compile(r"£\s*([\d,]+\.\d{2})")


def extract_domain(from_field: str) -> str:
    if not from_field: return ""
    if "<" in from_field and ">" in from_field:
        addr = from_field[from_field.find("<")+1:from_field.find(">")]
    else:
        addr = from_field
    return addr.split("@")[-1].lower() if "@" in addr else ""


async def main():
    # Search Gmail for invoice-shaped subjects
    q = f"newer_than:{DAYS}d to:info@malthousetintagel.com (subject:invoice OR subject:receipt OR subject:statement OR subject:remittance OR subject:bill)"
    url = "http://google-fetch:8011/messages?account=info&max_results=500&q=" + urllib.parse.quote(q)
    o = json.loads(urllib.request.urlopen(url, timeout=60).read())
    msgs = o.get("messages", [])
    print(f"── {len(msgs)} invoice-shaped emails in last {DAYS}d ──")

    conn = await asyncpg.connect(PG_DSN)
    ins = skipped = noise = 0

    async with conn.transaction():
        await conn.execute("SET LOCAL app.current_entity = '1'")
        for m in msgs:
            from_f  = m.get("from", "")
            domain  = extract_domain(from_f)
            if domain in NOISE:
                noise += 1
                continue
            subj    = (m.get("subject") or "")[:500]
            mid     = m.get("id")
            has_att = m.get("has_attachment", False)
            internal_date = int(m.get("internal_date") or 0)
            received = datetime.fromtimestamp(internal_date / 1000) if internal_date else datetime.utcnow()

            amt_match = AMOUNT_RE.search(subj)
            amount = float(amt_match.group(1).replace(",", "")) if amt_match else None

            n = await conn.fetchval("""
              INSERT INTO vendor_invoice_inbox
                (idempotency_key, source_email_id, account, vendor_domain,
                 subject, received_at, amount_seen, attachment_count, has_pdf)
              VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
              ON CONFLICT (source_email_id) DO NOTHING
              RETURNING 1
            """,
              f"vi_{mid}", mid, "info", domain, subj, received, amount,
              1 if has_att else 0, has_att)
            if n: ins += 1
            else: skipped += 1

    await conn.close()
    print(f"── done: inserted={ins} skipped={skipped} (already loaded) noise_filtered={noise} ──")


asyncio.run(main())
PYEOF
