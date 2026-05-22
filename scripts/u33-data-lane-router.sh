#!/bin/bash
# /home_ai/scripts/u33-data-lane-router.sh
#
# Picks up bot_instructions rows with lane='data' AND status='pending' and
# routes attachments based on STRICT sender match:
#
#   NatWest sender   → save CSV to /home_ai/data/natwest-inbox/ + flag needs_session
#                      (no CSV→bank_transactions parser yet; bank_accounts is empty)
#   Known vendor     → register in vendor_invoice_inbox (matches vendor_category_rules)
#   Unknown sender   → register in documents with entity_id=NULL for triage
#
# Cron: every 5 minutes. Idempotent — vendor_invoice_inbox has UNIQUE on
# idempotency_key; saved files use the Gmail message_id.

set -uo pipefail
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

# Attachments are written under /home_ai/data — must be bind-mounted in the
# homeai-playwright container. The router will mkdir its subdirs on first run.
docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, urllib.request, urllib.parse, urllib.error, base64, re, hashlib, pathlib
from datetime import datetime, timezone
import asyncpg

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]

NATWEST_DOMAINS = {"natwest.com", "nwolb.com", "natwestbankline.com",
                   "smtp.natwest.com", "alerts.natwest.com"}
PDF_MIMES = {"application/pdf"}
CSV_MIMES = {"text/csv", "application/csv", "application/vnd.ms-excel"}

DATA_DIR = pathlib.Path("/home_ai/data")  # bind-mounted in homeai-playwright
NATWEST_DIR = DATA_DIR / "natwest-inbox"
DOJO_DIR    = DATA_DIR / "dojo-inbox"
UNKNOWN_DIR = DATA_DIR / "unknown-attachments"
for p in (NATWEST_DIR, DOJO_DIR, UNKNOWN_DIR):
    p.mkdir(parents=True, exist_ok=True)

# U-A1 (2026-05-22): Jo confirmed Dojo CSVs go to the pub trading company.
# When a trusted sender forwards a Dojo-shaped CSV, route to dojo-inbox
# where u135-dojo-inbox-sweep picks it up automatically.
DOJO_FILENAME_RE = re.compile(r"transactions[_-].*all[_-]locations.*\.csv$", re.I)
TRUSTED_SENDERS = {"jolyon.sandercock@gmail.com"}


def vault_get(path):
    req = urllib.request.Request(f"http://vault:8200/v1/secret/data/{path}",
                                  headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())["data"]["data"]


def tg_send(text):
    try:
        d = vault_get("telegram")
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{d['bot_token']}/sendMessage",
            data=urllib.parse.urlencode({"chat_id": d["chat_id"], "text": text}).encode())
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print("tg err:", e)


def gmail_message(account, message_id):
    url = f"http://google-fetch:8011/message/{account}/{message_id}"
    return json.loads(urllib.request.urlopen(url, timeout=15).read())


def gmail_attachment(account, message_id, attachment_id):
    url = f"http://google-fetch:8011/attachment/{account}/{message_id}/{attachment_id}"
    o = json.loads(urllib.request.urlopen(url, timeout=30).read())
    b = o.get("data_b64url", "")
    pad = "=" * (-len(b) % 4)
    return base64.urlsafe_b64decode(b + pad), int(o.get("size") or 0)


def domain_of(sender):
    if not sender:
        return ""
    s = sender.lower().strip()
    return s.split("@", 1)[1] if "@" in s else s


def iter_attachments(payload):
    """Yield (filename, mime, attachment_id) for each attachment part."""
    def walk(part):
        body = part.get("body", {}) or {}
        if body.get("attachmentId"):
            yield (part.get("filename") or "attachment", (part.get("mimeType") or "").lower(),
                   body["attachmentId"])
        for sub in part.get("parts", []) or []:
            yield from walk(sub)
    yield from walk(payload or {})


async def fetch_vendor_rules(conn):
    rows = await conn.fetch("SELECT domain_pattern, category, vendor_display FROM vendor_category_rules")
    out = []
    for r in rows:
        try:
            out.append((re.compile(r["domain_pattern"], re.I), r["category"], r["vendor_display"]))
        except re.error:
            continue
    return out


def vendor_match(domain, rules):
    for pat, category, display in rules:
        if pat.search(domain):
            return (category, display)
    return None


async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity = 'all'")

    rows = await conn.fetch("""
      SELECT id, source_id, sender_email, from_user, raw_subject, received_at, entity_id
        FROM bot_instructions
       WHERE lane='data' AND status='pending'
       ORDER BY received_at ASC
       LIMIT 50
    """)
    if not rows:
        await conn.close()
        return

    vendor_rules = await fetch_vendor_rules(conn)
    processed = 0
    for row in rows:
        bi_id = row["id"]
        mid = row["source_id"]
        sender = row["sender_email"] or ""
        domain = domain_of(sender)
        subject = row["raw_subject"] or ""
        received = row["received_at"]

        try:
            msg = gmail_message("bot", mid)
        except urllib.error.HTTPError as e:
            # 4xx from google-fetch usually means the message_id isn't in the
            # 'bot' inbox (Gmail-API 400/404). Mark as 'rejected' so the cron
            # loop doesn't keep failing on it (status_check disallows 'failed').
            await conn.execute("""
              UPDATE bot_instructions
                 SET status='rejected', resolution=$2, resolved_at=now(), picked_up_by='u33-data-lane-router'
               WHERE id=$1
            """, bi_id, f"gmail fetch HTTP {e.code}: message_id not retrievable")
            print(f"  bi#{bi_id} marked rejected: gmail HTTP {e.code} on mid={mid}")
            continue
        payload = msg.get("payload", {})
        attachments = list(iter_attachments(payload))
        if not attachments:
            await conn.execute("""
              UPDATE bot_instructions
                 SET status='triaged', resolution=$2, resolved_at=now(), picked_up_by='u33-data-lane-router'
               WHERE id=$1
            """, bi_id, "lane=data but no attachments found — manual review")
            tg_send(f"⚠️  data-lane row #{bi_id} ({domain}) had no attachments — triaged for manual review.")
            continue

        # ── Route ───────────────────────────────────────────
        is_natwest = any(domain.endswith(d) for d in NATWEST_DOMAINS) or "natwest" in domain
        vendor_hit = None if is_natwest else vendor_match(domain, vendor_rules)

        actions = []
        for fname, mime, att_id in attachments:
            try:
                blob, _ = gmail_attachment("bot", mid, att_id)
            except Exception as e:
                actions.append(f"FETCH FAIL ({fname}): {e}")
                continue

            if is_natwest and (mime in CSV_MIMES or fname.lower().endswith(".csv")):
                out = NATWEST_DIR / f"{mid}__{fname}"
                out.write_bytes(blob)
                actions.append(f"natwest-csv saved → {out}")
                continue

            # Dojo CSV forwarded by a trusted sender (Jo) → dojo-inbox.
            # u135 sweep imports on its next run.
            sender_lc = (sender or "").lower().strip()
            sender_email = sender_lc.split("<")[-1].rstrip(">").strip() if "<" in sender_lc else sender_lc
            if (sender_email in TRUSTED_SENDERS
                    and (mime in CSV_MIMES or fname.lower().endswith(".csv"))
                    and DOJO_FILENAME_RE.search(fname)):
                out = DOJO_DIR / f"{mid}__{fname}"
                out.write_bytes(blob)
                actions.append(f"dojo-csv saved → {out}")
                continue

            if vendor_hit and (mime in PDF_MIMES or fname.lower().endswith(".pdf")):
                cat, display = vendor_hit
                vendor_name = display or domain
                idem = hashlib.sha256(f"vii|{mid}|{att_id}|{fname}".encode()).hexdigest()[:32]
                async with conn.transaction():
                    await conn.execute("SET LOCAL app.current_entity = '1'")
                    await conn.execute("""
                      INSERT INTO vendor_invoice_inbox
                        (idempotency_key, source_email_id, account, vendor_domain, vendor_name,
                         subject, received_at, attachment_count, has_pdf, vendor_category, status)
                      VALUES ($1,$2,'bot',$3,$4,$5,$6,1,true,$7,'new')
                      ON CONFLICT (idempotency_key) DO NOTHING
                    """, idem, mid, domain, vendor_name, subject, received, cat)
                actions.append(f"vendor-invoice registered ({vendor_name}, {cat})")
                continue

            # Unknown → save to disk + register in documents with entity_id=NULL
            out = UNKNOWN_DIR / f"{mid}__{fname}"
            out.write_bytes(blob)
            async with conn.transaction():
                await conn.execute("SET LOCAL app.current_entity = 'all'")
                await conn.execute("""
                  INSERT INTO documents (entity_id, category, title, status, owner, drive_url)
                  VALUES (NULL, 'inbound_email_attachment', $1, 'draft', $2, $3)
                """, f"{subject[:120]} — {fname}", sender or "unknown",
                     f"file://{out}")
            actions.append(f"documents registered (unknown sender, entity_id=NULL) → {out}")

        resolution = " | ".join(actions)[:1000]
        async with conn.transaction():
            await conn.execute("SET LOCAL app.current_entity = '3'")
            await conn.execute("""
              UPDATE bot_instructions
                 SET status='done', resolution=$2, resolved_at=now(),
                     picked_up_by='u33-data-lane-router',
                     needs_session = $3
               WHERE id=$1
            """, bi_id, resolution, is_natwest)  # NatWest still needs human until parser exists
        processed += 1
        if is_natwest:
            tg_send(f"🏦 NatWest CSV received from {sender} — saved, awaiting parser. bi#{bi_id}")

    await conn.close()
    if processed:
        print(f"data-lane processed: {processed}")

asyncio.run(main())
PYEOF
