#!/bin/bash
# /home_ai/scripts/u32-invoice-pdf-extract.sh
#
# Walks vendor_invoice_inbox rows with has_pdf=true AND amount_seen IS NULL,
# fetches the PDF via google-fetch, runs through pdfplumber, regex-extracts:
#   amount  — first "Total" or "£N.NN" near "Amount Due"/"Total Due"
#   due     — date pattern near "Due Date"/"Payment Due"
#   inv_no  — common patterns
# Writes amount/due_date back to the row.

set -euo pipefail
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, urllib.request, urllib.parse, urllib.error, re, base64
from datetime import date as _date
import asyncpg

PG_DSN = os.environ["PG_DSN"]

# Money: capture pound-prefixed or label-suffixed numbers
MONEY_RE = re.compile(r"£\s*([\d,]+\.\d{2})")
AMOUNT_LABELS = re.compile(r"(?:amount\s+due|total\s+due|total\s+to\s+pay|invoice\s+total|grand\s+total|balance\s+due|total)\s*[:\-]?\s*£?\s*([\d,]+\.\d{2})", re.I)
DUE_RE = re.compile(r"(?:due\s+date|payment\s+due|due\s+on)\s*[:\-]?\s*(\d{1,2}[\-/\.\s][A-Za-z]{3,}[\-/\.\s]\d{2,4}|\d{1,2}[/\-\.]\d{1,2}[/\-\.]\d{2,4})", re.I)
INV_NO_RE = re.compile(r"(?:invoice\s*(?:no|number|#|num)|inv\s*#?|ref(?:erence)?\s*(?:no|number|#)?)\s*[:\-]?\s*([A-Z0-9\-/]{3,20})", re.I)


def parse_date(s):
    """Best-effort date parser."""
    s = s.strip()
    # DD/MM/YYYY
    m = re.match(r"^(\d{1,2})[/\-\.](\d{1,2})[/\-\.](\d{2,4})$", s)
    if m:
        d, mo, y = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if y < 100: y += 2000
        try: return _date(y, mo, d)
        except: pass
    # DD Mon YYYY
    months = {m.lower(): i for i, m in enumerate(
        ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"], start=1)}
    m = re.match(r"^(\d{1,2})[\-/\.\s]+([A-Za-z]{3,})[\-/\.\s]+(\d{2,4})$", s)
    if m:
        d = int(m.group(1)); mn = m.group(2)[:3].lower(); y = int(m.group(3))
        if y < 100: y += 2000
        if mn in months:
            try: return _date(y, months[mn], d)
            except: pass
    return None


async def find_pdf_attachment(account, message_id):
    """Return (filename, attachment_id) or None."""
    r = urllib.request.urlopen(f"http://google-fetch:8011/message/{account}/{message_id}", timeout=15)
    msg = json.loads(r.read())
    def walk(part):
        mt = part.get("mimeType", "")
        body = part.get("body") or {}
        if mt == "application/pdf" and body.get("attachmentId"):
            return part.get("filename", "attachment.pdf"), body["attachmentId"]
        for sub in part.get("parts", []) or []:
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


async def extract_via_pdfplumber(pdf_bytes):
    """POST to pdfplumber service."""
    boundary = "----homeai" + os.urandom(8).hex()
    headers_part = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="invoice.pdf"\r\n'
        f"Content-Type: application/pdf\r\n\r\n"
    ).encode()
    body = headers_part + pdf_bytes + f"\r\n--{boundary}--\r\n".encode()
    r = urllib.request.Request(
        "http://homeai-pdfplumber:8003/extract-pdf",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    resp = urllib.request.urlopen(r, timeout=60)
    return json.loads(resp.read()).get("text", "")


def extract_fields(text):
    out = {"amount": None, "due_date": None, "invoice_no": None}
    if not text: return out
    # Try labeled amount first; fall back to last £-amount in text
    m = AMOUNT_LABELS.search(text)
    if m:
        try: out["amount"] = float(m.group(1).replace(",", ""))
        except: pass
    else:
        money = MONEY_RE.findall(text)
        if money:
            try: out["amount"] = float(money[-1].replace(",", ""))
            except: pass
    m = DUE_RE.search(text)
    if m: out["due_date"] = parse_date(m.group(1))
    m = INV_NO_RE.search(text)
    if m: out["invoice_no"] = m.group(1)[:50]
    return out


async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity = 'all'")
    todo = await conn.fetch("""
      SELECT id, source_email_id, account, vendor_domain, subject
        FROM vendor_invoice_inbox
       WHERE amount_seen IS NULL
       ORDER BY received_at DESC LIMIT 50
    """)
    print(f"{len(todo)} rows to enrich")
    extracted = 0
    for r in todo:
        info = await find_pdf_attachment(r["account"], r["source_email_id"])
        if info is None: continue
        try:
            pdf = await fetch_pdf(r["account"], r["source_email_id"], info[1])
            text = await extract_via_pdfplumber(pdf)
            fields = extract_fields(text)
        except Exception as e:
            print(f"  {r['id']}: extract failed: {e}")
            continue
        async with conn.transaction():
            await conn.execute("SET LOCAL app.current_entity = '1'")
            await conn.execute("""
              UPDATE vendor_invoice_inbox
                 SET amount_seen = COALESCE($2, amount_seen),
                     due_date    = COALESCE($3, due_date),
                     status      = CASE WHEN $2 IS NOT NULL THEN 'extracted' ELSE status END
               WHERE id = $1
            """, r["id"], fields["amount"], fields["due_date"])
        if fields["amount"]:
            extracted += 1
            print(f"  {r['id']}  {r['vendor_domain']:30}  £{fields['amount']:.2f}  due={fields['due_date']}")
    await conn.close()
    print(f"extracted {extracted}/{len(todo)} amounts")

asyncio.run(main())
PYEOF
