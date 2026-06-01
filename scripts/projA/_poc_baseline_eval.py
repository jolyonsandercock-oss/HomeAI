#!/usr/bin/env python3
"""PoC baseline: prompted qwen2.5:7b (production extract_local path) vs stored
Haiku-quality labels, on real invoices. Measures field accuracy + gate-pass.
Runs in homeai-bot-responder. NO fine-tuning — this is the baseline arm only."""
import os, sys, json, time, base64, urllib.request, asyncio, re
import asyncpg

GF = "http://homeai-google-fetch:8011"
PDF_PL = "http://homeai-pdfplumber:8003"
OLLAMA = "http://homeai-ollama:11434"
LOCAL_MODEL = "qwen2.5:7b"
PG = os.environ["PG_DSN"]
_SCHEMA = json.load(open("/app/invoice_extract.schema.json"))["input_schema"]
_SYS = ("Extract structured fields from the OCR text of a UK supplier invoice. "
        "Be conservative; null for anything not clearly present; never guess. "
        "is_invoice=false for statements/receipts/order-confirmations/payment-notifications.")


def fetch_pdf_bytes(acct, mid):
    try:
        a = json.load(urllib.request.urlopen(f"{GF}/attachments/{acct}/{mid}", timeout=40))
        a = a if isinstance(a, list) else a.get("attachments", a)
        pdf = next((x for x in a if (x.get("filename") or "").lower().endswith(".pdf")), None)
        if not pdf:
            return None
        o = json.load(urllib.request.urlopen(f"{GF}/attachment/{acct}/{mid}/{pdf['attachment_id']}", timeout=60))
        return base64.urlsafe_b64decode(o["data_b64url"] + "=" * (-len(o["data_b64url"]) % 4))
    except Exception as e:
        sys.stderr.write(f"fetch err {mid}: {str(e)[:80]}\n"); return None


def pdf_to_text(raw):
    b = "---b"
    body = (f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"x.pdf\"\r\n"
            f"Content-Type: application/pdf\r\n\r\n").encode() + raw + f"\r\n--{b}--\r\n".encode()
    req = urllib.request.Request(f"{PDF_PL}/extract-pdf", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={b}"}, method="POST")
    try:
        return json.load(urllib.request.urlopen(req, timeout=60)).get("text") or ""
    except Exception:
        return ""


def extract_local(text):
    payload = json.dumps({
        "model": LOCAL_MODEL, "stream": False, "format": _SCHEMA, "options": {"temperature": 0},
        "messages": [{"role": "system", "content": _SYS},
                     {"role": "user", "content": f"Invoice text:\n\n{text[:8000]}"}]}).encode()
    try:
        r = urllib.request.urlopen(urllib.request.Request(f"{OLLAMA}/api/chat", data=payload,
            headers={"Content-Type": "application/json"}), timeout=120)
        return json.loads(json.load(r)["message"]["content"])
    except Exception as e:
        sys.stderr.write(f"local err: {str(e)[:120]}\n"); return None


def _num(v):
    try: return float(v) if v not in (None, "") else None
    except Exception: return None

def norm_vendor(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower().replace("limited", "").replace("ltd", ""))

def gate(d):
    if d.get("is_invoice") is not True: return False
    for f in ("vendor_name", "invoice_date", "gross"):
        if d.get(f) in (None, ""): return False
    net, vat, gross = _num(d.get("net")), _num(d.get("vat")), _num(d.get("gross"))
    if None not in (net, vat, gross) and abs((net + vat) - gross) > 0.02: return False
    return True


async def main():
    conn = await asyncpg.connect(PG)
    rows = await conn.fetch("""
        SELECT id, account, source_ref, vendor_name, gross_amount, invoice_date::text d
        FROM purchases WHERE is_invoice AND gate_passed AND source_ref ~ '^[0-9a-f]+$'
          AND extraction_tier IN ('haiku','sonnet')
        ORDER BY random() LIMIT 10""")
    await conn.close()
    n = vok = gok = dok = gate_ok = allok = noinput = 0
    print(f"PoC baseline — prompted {LOCAL_MODEL} vs Haiku labels, {len(rows)} invoices\n", flush=True)
    for r in rows:
        raw = fetch_pdf_bytes(r["account"], r["source_ref"])
        text = pdf_to_text(raw) if raw else ""
        if len(text) < 30:
            noinput += 1; print(f"  #{r['id']} {r['vendor_name'][:22]:22} — no text (image-only PDF)", flush=True); continue
        n += 1
        d = extract_local(text) or {}
        v = norm_vendor(d.get("vendor_name")) and norm_vendor(d.get("vendor_name")) in norm_vendor(r["vendor_name"]) or norm_vendor(r["vendor_name"]) in (norm_vendor(d.get("vendor_name")) or "_")
        g = _num(d.get("gross")) is not None and abs(_num(d.get("gross")) - float(r["gross_amount"])) <= 0.02
        dt = (d.get("invoice_date") or "") == r["d"]
        gt = gate(d)
        vok += v; gok += g; dok += dt; gate_ok += gt; allok += (v and g and dt)
        print(f"  #{r['id']} {(r['vendor_name'] or '')[:22]:22} vendor={'Y' if v else 'n'} gross={'Y' if g else 'n'}({d.get('gross')} vs {r['gross_amount']}) date={'Y' if dt else 'n'} gate={'Y' if gt else 'n'}", flush=True)
    print(f"\n=== BASELINE (prompted 7B) on {n} text-PDF invoices ===", flush=True)
    if n:
        print(f"  vendor correct:  {vok}/{n} ({100*vok//n}%)", flush=True)
        print(f"  gross correct:   {gok}/{n} ({100*gok//n}%)", flush=True)
        print(f"  date correct:    {dok}/{n} ({100*dok//n}%)", flush=True)
        print(f"  all-3 correct:   {allok}/{n} ({100*allok//n}%)", flush=True)
        print(f"  GATE PASS:       {gate_ok}/{n} ({100*gate_ok//n}%)", flush=True)
    print(f"  ({noinput} image-only PDFs skipped — those need the vision tier regardless)", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
