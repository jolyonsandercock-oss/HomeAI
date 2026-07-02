#!/bin/bash
# /home_ai/scripts/u49-fetch-invoice-pdfs.sh
#
# Fetch the PDF attachment for every invoice in vendor_invoice_inbox that
# doesn't already have one persisted. Uses google-fetch sidecar's existing
# OAuth tokens (no auth required from us).
#
# Storage:  /home_ai/data/invoice-pdfs/{invoice_id}.pdf
# Idempotent: skip if pdf_local_path is set and file exists.

set -euo pipefail
LIMIT="${1:-200}"

docker exec -i -e LIMIT="$LIMIT" homeai-playwright python <<'PYEOF'
import os, json, base64, asyncio, asyncpg, httpx, pathlib

PG_DSN = os.environ["PG_DSN"]
LIMIT  = int(os.environ.get("LIMIT", "200"))
GF_URL = "http://homeai-google-fetch:8011"
DEST   = pathlib.Path("/home_ai/data/invoice-pdfs")

async def fetch_one(client, account, message_id, invoice_id, conn):
    # 1. List attachments
    r = await client.get(f"{GF_URL}/attachments/{account}/{message_id}", timeout=15)
    if r.status_code != 200:
        return (False, f"list {r.status_code}: {r.text[:120]}")
    atts = (r.json() or {}).get("attachments", [])
    pdfs = [a for a in atts if (a.get("mime_type") or "").endswith("pdf")
            or (a.get("filename") or "").lower().endswith(".pdf")]
    if not pdfs:
        return (False, "no pdf attachment")
    # 2. Take the first PDF (most invoices have one)
    att = pdfs[0]
    r2 = await client.get(
      f"{GF_URL}/attachment/{account}/{message_id}/{att['attachment_id']}",
      timeout=30,
    )
    if r2.status_code != 200:
        return (False, f"get {r2.status_code}: {r2.text[:120]}")
    data_b64 = (r2.json() or {}).get("data_b64url", "")
    # Gmail returns URL-safe base64, no padding
    pad = '=' * (-len(data_b64) % 4)
    raw = base64.urlsafe_b64decode((data_b64 + pad).encode())
    out = DEST / f"{invoice_id}.pdf"
    out.write_bytes(raw)
    await conn.execute("""
      UPDATE vendor_invoice_inbox
         SET pdf_local_path = $1,
             pdf_fetched_at = now(),
             pdf_fetch_error = NULL,
             has_pdf = true
       WHERE id = $2
    """, str(out), invoice_id)
    return (True, f"{len(raw)//1024}KB")


async def main():
    conn = await asyncpg.connect(PG_DSN)
    rows = await conn.fetch(f"""
      SELECT id, account, source_email_id
        FROM vendor_invoice_inbox
       WHERE is_statement = false
         AND status NOT IN ('duplicate','ignored')
         AND pdf_local_path IS NULL
         AND (pdf_fetch_error IS NULL OR pdf_fetched_at < now() - INTERVAL '1 day')
       ORDER BY received_at DESC
       LIMIT {LIMIT}
    """)
    print(f"candidates: {len(rows)}")
    ok = 0
    fail = 0
    async with httpx.AsyncClient() as client:
        for i, r in enumerate(rows, 1):
            success, msg = await fetch_one(client, r["account"], r["source_email_id"], r["id"], conn)
            if success:
                ok += 1
                if i <= 10 or i % 20 == 0:
                    print(f"  [{i}/{len(rows)}] inv {r['id']} {r['account']} → {msg}")
            else:
                fail += 1
                await conn.execute("""
                  UPDATE vendor_invoice_inbox
                     SET pdf_fetched_at = now(), pdf_fetch_error = $1
                   WHERE id = $2
                """, msg[:300], r["id"])
                if fail <= 5:
                    print(f"  [{i}/{len(rows)}] inv {r['id']} {r['account']} FAIL: {msg}")
    print(f"\nfetched: {ok}  failed: {fail}")
    await conn.close()

asyncio.run(main())
PYEOF
