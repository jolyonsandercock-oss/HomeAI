#!/bin/bash
# /home_ai/scripts/u50-due-date-haiku.sh
#
# T3 of U50. Iterates vendor_invoice_inbox rows where has_pdf=true AND
# due_date IS NULL, fetches PDF via google-fetch, extracts text via the
# pdfplumber service (port 8003, /extract-pdf), then asks Claude Haiku
# for the due date. Writes due_date back if confidence ≥ 0.85. Every
# attempt logged to due_date_extractions.
#
# Usage:
#   ./scripts/u50-due-date-haiku.sh           # default cap 50
#   ./scripts/u50-due-date-haiku.sh 200       # process up to N

set -euo pipefail
LIMIT="${1:-50}"
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e LIMIT="$LIMIT" -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, time, base64, urllib.request, urllib.parse, urllib.error
from datetime import date as _date
import asyncpg

LIMIT = int(os.environ["LIMIT"])
VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]

SYSTEM = (
  "You extract the payment due date from a UK supplier invoice. "
  "Return ONLY this JSON, no prose: "
  '{"due_date": "YYYY-MM-DD" | null, '
  '"confidence": 0.0-1.0, '
  '"source": "stated" | "computed" | "absent", '
  '"reason": "<8 words max>"}\n\n'
  "Rules:\n"
  "- 'stated' if a due date is explicitly printed (e.g. 'Due Date: 12/05/2026', 'Pay by 28th May 2026').\n"
  "- 'computed' if invoice date + payment terms can derive it (e.g. invoice 01/05/2026 + 'Net 30' → 2026-05-31).\n"
  "- 'absent' if neither is present. Set due_date=null in that case.\n"
  "- Dates are UK format (DD/MM/YYYY) unless ISO. Year defaults to current if absent.\n"
  "- Confidence ≥0.9 if the date is unambiguous; ≤0.7 if you're guessing.\n"
)


def vault_get(path, key):
    req = urllib.request.Request(f"http://vault:8200/v1/secret/data/{path}",
        headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())["data"]["data"][key]


async def find_pdf(account, message_id):
    r = urllib.request.urlopen(f"http://google-fetch:8011/message/{account}/{message_id}", timeout=15)
    msg = json.loads(r.read())
    def walk(p):
        body = p.get("body") or {}
        if p.get("mimeType") == "application/pdf" and body.get("attachmentId"):
            return body["attachmentId"]
        for sub in p.get("parts") or []:
            r = walk(sub)
            if r: return r
        return None
    return walk(msg.get("payload", {}))


async def fetch_pdf(account, message_id, attachment_id):
    r = urllib.request.urlopen(
        f"http://google-fetch:8011/attachment/{account}/{message_id}/{attachment_id}", timeout=60)
    o = json.loads(r.read())
    b = o["data_b64url"]; pad = "=" * (-len(b) % 4)
    return base64.urlsafe_b64decode(b + pad)


async def pdf_text(pdf_bytes):
    boundary = "----homeai" + os.urandom(8).hex()
    body = (f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="invoice.pdf"\r\n'
            f"Content-Type: application/pdf\r\n\r\n").encode() + pdf_bytes + f"\r\n--{boundary}--\r\n".encode()
    r = urllib.request.Request("http://homeai-pdfplumber:8003/extract-pdf",
        data=body, headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    return json.loads(urllib.request.urlopen(r, timeout=60).read()).get("text", "")


def haiku(api_key, text):
    user = (text or "")[:1500]
    body = {"model": "claude-haiku-4-5-20251001", "max_tokens": 200,
            "system": SYSTEM, "messages": [{"role": "user", "content": user}]}
    req = urllib.request.Request("https://api.anthropic.com/v1/messages",
        data=json.dumps(body).encode(),
        headers={"x-api-key": api_key, "anthropic-version": "2023-06-01",
                 "Content-Type": "application/json"})
    out = json.loads(urllib.request.urlopen(req, timeout=30).read())
    raw = out["content"][0]["text"].strip()
    if raw.startswith("```"):
        raw = raw.split("\n", 1)[1] if "\n" in raw else raw
        if raw.endswith("```"): raw = raw.rsplit("```", 1)[0]
    s = raw.find("{"); e = raw.rfind("}")
    if s >= 0 and e > s: raw = raw[s:e+1]
    return json.loads(raw)


def parse_iso(v):
    if not v: return None
    try: return _date.fromisoformat(v[:10])
    except Exception: return None


async def main():
    api_key = vault_get("anthropic", "api_key")
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity = 'all'")
    # R6: invoice due-date extraction is WORK realm (vendor_invoice_inbox).
    await conn.execute("SET app.current_realm = 'work'")

    todo = await conn.fetch(f"""
      SELECT id, source_email_id, account, vendor_domain
        FROM vendor_invoice_inbox
       WHERE has_pdf=true AND due_date IS NULL
         AND status NOT IN ('duplicate','ignored')
       ORDER BY received_at DESC LIMIT {LIMIT}
    """)
    print(f"{len(todo)} invoices to enrich")

    stated = computed = absent = errored = applied = 0

    for r in todo:
        try:
            att = await find_pdf(r["account"], r["source_email_id"])
            if not att:
                print(f"  [{r['id']:>4}] no PDF attachment found, skip")
                continue
            pdf = await fetch_pdf(r["account"], r["source_email_id"], att)
            text = await pdf_text(pdf)
            if not text or len(text) < 80:
                print(f"  [{r['id']:>4}] pdfplumber returned <80 chars, skip")
                continue
            res = haiku(api_key, text)
        except urllib.error.HTTPError as e:
            print(f"  [{r['id']:>4}] HTTP {e.code}: {e.read().decode()[:120]}")
            errored += 1
            await conn.execute("""
              INSERT INTO due_date_extractions (invoice_id, source, raw_response)
              VALUES ($1, 'error', $2::jsonb)
            """, r["id"], json.dumps({"http": e.code}))
            continue
        except Exception as e:
            print(f"  [{r['id']:>4}] error: {e}")
            errored += 1
            continue

        src = res.get("source") or "absent"
        conf = float(res.get("confidence") or 0)
        d = parse_iso(res.get("due_date"))
        snippet = (text or "")[:800]

        async with conn.transaction():
            await conn.execute("SET LOCAL app.current_entity = '1'")
            await conn.execute("""
              INSERT INTO due_date_extractions
                (invoice_id, source, due_date, confidence, text_snippet, raw_response)
              VALUES ($1,$2,$3,$4,$5,$6::jsonb)
            """, r["id"], src if src in ('stated','computed','absent') else 'absent',
                 d, conf, snippet, json.dumps(res))
            if d and conf >= 0.85 and src in ('stated','computed'):
                await conn.execute("""
                  UPDATE vendor_invoice_inbox SET due_date=$2 WHERE id=$1
                """, r["id"], d)
                applied += 1

        if src == 'stated':   stated += 1
        elif src == 'computed': computed += 1
        else: absent += 1

        print(f"  [{r['id']:>4}] {r['vendor_domain']:30} {src:8} conf={conf:.2f} due={d} {'APPLIED' if (d and conf>=0.85 and src in ('stated','computed')) else ''}")
        time.sleep(0.15)

    await conn.close()
    print()
    print(f"── summary ──")
    print(f"  stated   : {stated}")
    print(f"  computed : {computed}")
    print(f"  absent   : {absent}")
    print(f"  errored  : {errored}")
    print(f"  APPLIED  : {applied}/{len(todo)}")


asyncio.run(main())
PYEOF
