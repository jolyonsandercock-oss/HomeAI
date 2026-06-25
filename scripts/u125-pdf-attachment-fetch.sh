#!/bin/bash
# u125-pdf-attachment-fetch.sh — fetch PDF attachments for invoice emails.
#
# For every 'new' vendor_invoice_inbox row missing a local PDF:
#   1. Call google-fetch /attachments/{account}/{message_id}
#   2. For each PDF: GET /attachment/{account}/{message_id}/{att_id}, base64-decode
#   3. Save to /home_ai/data/invoice-pdfs/{inv_id}.pdf
#   4. Update vendor_invoice_inbox: has_pdf=true, pdf_local_path=...
#   5. Insert email_attachments row
#
# Rate-limiting: 0.5s between API calls, fresh attempt per cron run.
#
# Going forward: cron at :05 every hour (15 min before u61 at :20) drains
# any new rows. Combine with the invoice-pipeline ingest, which will
# call this on new rows as they appear.

set -uo pipefail

VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
mkdir -p /home_ai/data/invoice-pdfs

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e BATCH="${BATCH:-100}" homeai-playwright python3 -u <<'PYEOF'
import os, json, asyncio, base64, urllib.request, urllib.error
import asyncpg

TOK = os.environ["VAULT_TOKEN"]
BATCH = int(os.environ.get("BATCH", "100"))
PDF_DIR = "/home_ai/data/invoice-pdfs"


def vault(p):
    r = urllib.request.urlopen(urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{p}",
        headers={"X-Vault-Token": TOK}), timeout=5)
    return json.loads(r.read())["data"]["data"]


async def list_attachments(account, message_id):
    """Returns list of {filename, mime_type, attachment_id, size} or [] on err."""
    try:
        r = urllib.request.urlopen(
            f"http://google-fetch:8011/attachments/{account}/{message_id}",
            timeout=15)
        return json.loads(r.read()).get("attachments", [])
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None   # message deleted
        return []
    except Exception:
        return []


async def fetch_attachment(account, message_id, attachment_id):
    """Returns the decoded bytes or None on error."""
    try:
        r = urllib.request.urlopen(
            f"http://google-fetch:8011/attachment/{account}/{message_id}/{attachment_id}",
            timeout=30)
        body = json.loads(r.read())
        # google-fetch returns URL-safe base64 in 'data_b64url' (NOT 'data' — the old
        # key broke every fetch silently from ~2026-06-11 when the endpoint changed).
        b = body["data_b64url"]
        return base64.urlsafe_b64decode(b + "=" * (-len(b) % 4))
    except Exception as e:
        print(f"  fetch_attachment error: {type(e).__name__} {str(e)[:80]}")
        return None


async def main():
    pg = vault("postgres")["password"]
    conn = await asyncpg.connect(f"postgresql://postgres:{pg}@homeai-postgres:5432/homeai")
    await conn.execute("SELECT home_ai.set_realm('owner')")

    rows = await conn.fetch("""
        SELECT id, source_email_id, account, vendor_domain
          FROM vendor_invoice_inbox
         WHERE status = 'new'
           AND (NOT has_pdf OR pdf_local_path IS NULL)
           AND COALESCE(extraction_method,'') NOT IN
               ('no-pdf-attached','non-pdf-attached','message-deleted-on-gmail')  -- skip already-classed-unfetchable
           AND pdf_fetch_error IS NULL        -- skip rows that already errored (revisit separately)
           AND source_email_id IS NOT NULL
           AND account IS NOT NULL
           AND account IN ('jo','bot','pounana','admin','info')
         ORDER BY id DESC
         LIMIT $1
    """, BATCH)
    print(f"to process: {len(rows)} rows")

    stats = {"pdf_saved": 0, "no_attachments": 0, "message_404": 0,
             "non_pdf_only": 0, "fetch_failed": 0, "ratelimit_skip": 0}

    for i, r in enumerate(rows):
        inv_id = r["id"]
        msg_id = r["source_email_id"]
        acct = r["account"]
        attachments = await list_attachments(acct, msg_id)
        if attachments is None:
            stats["message_404"] += 1
            await conn.execute(
                "UPDATE vendor_invoice_inbox SET status='ignored', "
                "extraction_method='message-deleted-on-gmail' WHERE id=$1", inv_id)
            await asyncio.sleep(0.3)
            continue
        if not attachments:
            stats["no_attachments"] += 1
            # Mark so we don't retry this row forever
            await conn.execute(
                "UPDATE vendor_invoice_inbox SET extraction_method='no-pdf-attached' WHERE id=$1",
                inv_id)
            await asyncio.sleep(0.3)
            continue
        pdfs = [a for a in attachments if "pdf" in (a.get("mime_type") or "").lower()]
        if not pdfs:
            stats["non_pdf_only"] += 1
            await conn.execute(
                "UPDATE vendor_invoice_inbox SET extraction_method='non-pdf-attached' WHERE id=$1",
                inv_id)
            await asyncio.sleep(0.3)
            continue
        # Take the first/largest PDF
        pdf = max(pdfs, key=lambda a: a.get("size", 0))
        body = await fetch_attachment(acct, msg_id, pdf["attachment_id"])
        if not body:
            stats["fetch_failed"] += 1
            await conn.execute(
                "UPDATE vendor_invoice_inbox SET pdf_fetch_error='attachment-fetch-empty' WHERE id=$1",
                inv_id)
            await asyncio.sleep(0.5)
            continue
        pdf_path = f"{PDF_DIR}/{inv_id}.pdf"
        with open(pdf_path, "wb") as f:
            f.write(body)
        await conn.execute("""
            UPDATE vendor_invoice_inbox
               SET has_pdf=true, pdf_local_path=$2
             WHERE id=$1
        """, inv_id, pdf_path)
        # (removed a broken email_attachments INSERT here: it bound the gmail message-id
        #  string into the integer email_id column — pre-existing bug. The has_pdf flag
        #  already prevents re-fetch via the candidate query, so the row was redundant.)
        stats["pdf_saved"] += 1
        if (i + 1) % 25 == 0:
            print(f"  progress: {i+1}/{len(rows)}  saved={stats['pdf_saved']}  "
                  f"no_att={stats['no_attachments']}  404={stats['message_404']}")
        await asyncio.sleep(0.4)   # rate-limit

    print()
    print("=== summary ===")
    for k, v in stats.items():
        print(f"  {k:18s} = {v}")
    await conn.close()


asyncio.run(main())
PYEOF
