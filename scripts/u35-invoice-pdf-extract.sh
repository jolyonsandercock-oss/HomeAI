#!/bin/bash
# /home_ai/scripts/u35-invoice-pdf-extract.sh
#
# For each vendor_invoice_inbox row not yet extracted (is_statement=false AND
# extraction_method NULL), download the first PDF attachment, send to
# pdfplumber, regex out net/vat/gross/dates, populate row + vendor_invoice_lines.
#
# Idempotent — skips rows already extracted.

set -uo pipefail
LIMIT="${1:-200}"
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e LIMIT="$LIMIT" homeai-playwright python << 'PYEOF'
import os, json, urllib.request, urllib.error, base64, re, asyncio, asyncpg
from datetime import datetime, date

PG_DSN = os.environ["PG_DSN"]
LIMIT  = int(os.environ.get("LIMIT", "200"))
GF     = "http://google-fetch:8011"
PDF_PL = "http://homeai-pdfplumber:8003"

# ── Regex extractors — LINE-ANCHORED ────────────────────────
# Patterns look for label followed by an OPTIONAL £ and a number, on the SAME
# line, with strict separators. Avoids regex-greedy "VAT … <next-number>"
# bugs where it grabs an adjacent unrelated value.
RE_TOTAL_AMOUNT = re.compile(r'(?im)^\s*(?:total(?:\s+amount)?|amount\s+due|grand\s+total|invoice\s+total|to\s+pay|balance\s+due|total\s+due)\s*[:\-]?\s*£?\s*([\d,]+\.\d{2})\s*$')
RE_NET          = re.compile(r'(?im)^\s*(?:net(?:\s+amount)?(?:\s+total)?|sub[\-\s]?total|goods)\s*[:\-]?\s*£?\s*([\d,]+\.\d{2})\s*$')
RE_VAT          = re.compile(r'(?im)^\s*(?:vat(?:\s+amount)?|vat\s+total|tax\s+amount)\s*[:\-]?\s*£?\s*([\d,]+\.\d{2})\s*$')
RE_VAT_RATE     = re.compile(r'(?i)(?:\bvat\b|\btax\b)\s*(?:rate|@)?\s*[:\-]?\s*(\d{1,2}(?:\.\d{1,2})?)\s*%')
RE_INVOICE_DATE = re.compile(r'(?i)\b(?:invoice\s*date|tax\s+invoice\s+date|date\s+of\s+invoice|invoice|date)\s*[:\-]?\s*(\d{1,2}[/\-\s]\d{1,2}[/\-\s]\d{2,4}|\d{4}-\d{2}-\d{2}|\d{1,2}\s+\w+\s+\d{2,4})')
RE_DELIVERY     = re.compile(r'(?i)\b(?:delivery|delivered|despatch|dispatch|date\s+of\s+supply)(?:\s+date)?\s*[:\-]?\s*(\d{1,2}[/\-\s]\d{1,2}[/\-\s]\d{2,4}|\d{4}-\d{2}-\d{2}|\d{1,2}\s+\w+\s+\d{2,4})')
RE_AMOUNT_FALLBACK = re.compile(r'£\s*([\d,]+\.\d{2})')


def parse_date(s: str):
    s = s.strip()
    fmts = ["%d/%m/%Y", "%d-%m-%Y", "%d/%m/%y", "%d-%m-%y",
            "%Y-%m-%d", "%Y/%m/%d", "%d %B %Y", "%d %b %Y", "%d %B %y", "%d %b %y"]
    for f in fmts:
        try: return datetime.strptime(s, f).date()
        except ValueError: pass
    return None


def to_dec(s):
    if not s: return None
    try: return float(s.replace(",", ""))
    except ValueError: return None


def extract_from_text(text: str) -> dict:
    out = {"net": None, "vat": None, "gross": None, "vat_rate": None,
           "invoice_date": None, "delivery_date": None,
           "confidence": 0.0, "fields_seen": 0}

    m = RE_TOTAL_AMOUNT.search(text)
    if m: out["gross"] = to_dec(m.group(1)); out["fields_seen"] += 1

    m = RE_NET.search(text)
    if m: out["net"] = to_dec(m.group(1)); out["fields_seen"] += 1

    m = RE_VAT.search(text)
    if m: out["vat"] = to_dec(m.group(1)); out["fields_seen"] += 1

    m = RE_VAT_RATE.search(text)
    if m:
        try: out["vat_rate"] = float(m.group(1)); out["fields_seen"] += 1
        except ValueError: pass

    m = RE_INVOICE_DATE.search(text)
    if m:
        d = parse_date(m.group(1))
        if d: out["invoice_date"] = d; out["fields_seen"] += 1

    m = RE_DELIVERY.search(text)
    if m:
        d = parse_date(m.group(1))
        if d: out["delivery_date"] = d; out["fields_seen"] += 1

    # If we got gross but not net or vat, try to derive
    if out["gross"] and not out["net"] and not out["vat"]:
        # No-VAT case: net = gross, vat = 0
        if out["vat_rate"] == 0 or "zero rated" in text.lower():
            out["net"] = out["gross"]
            out["vat"] = 0.0
            out["fields_seen"] += 2
    # If we got net + vat but not gross, sum them
    if not out["gross"] and out["net"] is not None and out["vat"] is not None:
        out["gross"] = round(out["net"] + out["vat"], 2)
        out["fields_seen"] += 1

    # Fallback: if no gross found anywhere, take the largest £ value as a guess
    if not out["gross"]:
        cands = [to_dec(m) for m in RE_AMOUNT_FALLBACK.findall(text)]
        cands = [c for c in cands if c and c > 1.0]
        if cands:
            out["gross"] = max(cands)
            out["confidence"] *= 0.5  # low confidence

    # Confidence score: max 1.0; gross + invoice_date core fields
    score = 0.0
    if out["gross"] is not None: score += 0.4
    if out["net"]   is not None: score += 0.2
    if out["vat"]   is not None: score += 0.15
    if out["invoice_date"]:      score += 0.15
    if out["delivery_date"]:     score += 0.05
    if out["vat_rate"] is not None: score += 0.05
    out["confidence"] = round(score, 3)
    return out


def fetch_attachment(acct: str, mid: str) -> bytes | None:
    """Returns raw bytes of the first PDF attachment, or None."""
    try:
        r = urllib.request.urlopen(f"{GF}/attachments/{acct}/{mid}", timeout=15)
        atts = json.load(r).get("attachments", [])
    except (urllib.error.HTTPError, urllib.error.URLError) as e:
        return None
    pdf = next((a for a in atts if (a.get("mime_type") == "application/pdf"
                                    or (a.get("filename") or "").lower().endswith(".pdf"))), None)
    if not pdf: return None
    try:
        r = urllib.request.urlopen(f"{GF}/attachment/{acct}/{mid}/{pdf['attachment_id']}", timeout=45)
        o = json.load(r)
        b64 = o.get("data_b64url") or ""
        return base64.urlsafe_b64decode(b64 + "=" * (-len(b64) % 4))
    except (urllib.error.HTTPError, urllib.error.URLError):
        return None


def extract_via_pdfplumber(pdf_bytes: bytes) -> str | None:
    boundary = "---homeai_bnd"
    body = (f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="x.pdf"\r\n'
            f'Content-Type: application/pdf\r\n\r\n').encode() + pdf_bytes + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(f"{PDF_PL}/extract-pdf", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"}, method="POST")
    try:
        r = urllib.request.urlopen(req, timeout=45)
        return json.load(r).get("text") or ""
    except (urllib.error.HTTPError, urllib.error.URLError) as e:
        return None


async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity='1'")
    rows = await conn.fetch("""
      SELECT id, account, source_email_id
        FROM vendor_invoice_inbox
       WHERE extraction_method IS NULL
         AND is_statement = false
         AND status NOT IN ('duplicate','ignored')
       ORDER BY received_at DESC
       LIMIT $1
    """, LIMIT)

    print(f"candidates: {len(rows)}")
    ok = no_pdf = pdf_fail = extracted_low = extracted_ok = 0

    for row in rows:
        bid, acct, mid = row['id'], row['account'], row['source_email_id']
        pdf = fetch_attachment(acct, mid)
        if not pdf:
            no_pdf += 1
            async with conn.transaction():
                await conn.execute("SET LOCAL app.current_entity='1'")
                await conn.execute("""
                  UPDATE vendor_invoice_inbox
                     SET extraction_method='no_pdf', extracted_at=now()
                   WHERE id=$1
                """, bid)
            continue
        text = extract_via_pdfplumber(pdf)
        if text is None:
            pdf_fail += 1
            async with conn.transaction():
                await conn.execute("SET LOCAL app.current_entity='1'")
                await conn.execute("""
                  UPDATE vendor_invoice_inbox
                     SET extraction_method='pdf_fail', extracted_at=now()
                   WHERE id=$1
                """, bid)
            continue
        ex = extract_from_text(text)
        method = "pdf" if ex["confidence"] >= 0.4 else "pdf_low_conf"
        status_target = "extracted" if ex["confidence"] >= 0.5 else "needs_review"
        if ex["confidence"] >= 0.5: extracted_ok += 1
        else: extracted_low += 1
        async with conn.transaction():
            await conn.execute("SET LOCAL app.current_entity='1'")
            await conn.execute("""
              UPDATE vendor_invoice_inbox
                 SET net_amount = $2,
                     vat_amount = $3,
                     gross_amount = $4,
                     vat_rate = $5,
                     invoice_date = COALESCE($6, invoice_date),
                     delivery_date = $7,
                     extraction_method = $8,
                     extraction_confidence = $9,
                     extracted_at = now(),
                     amount_seen = COALESCE($4, amount_seen),
                     status = CASE WHEN status='new' THEN $10::text ELSE status END
               WHERE id=$1
            """, bid, ex["net"], ex["vat"], ex["gross"], ex["vat_rate"],
                 ex["invoice_date"], ex["delivery_date"], method,
                 ex["confidence"], status_target)
        ok += 1

    await conn.close()
    print(f"done. ok={ok}  no_pdf={no_pdf}  pdf_fail={pdf_fail}  "
          f"extracted_ok={extracted_ok}  extracted_low_conf={extracted_low}")

asyncio.run(main())
PYEOF
