#!/usr/bin/env python3
"""u281-vision-ocr-drain.py — gated vision-OCR drain of stuck invoices.

Targets: extraction_method='pdf_low_conf', no extracted text, local PDF
present, no amount yet. Renders pages back-to-front (totals live on the last
page), extracts with the local vision model, and ACCEPTS ONLY when the
arithmetic self-validates: |net + vat − gross| ≤ 0.02 and 0 < gross < 50000.
That gate caught every failure mode in the u276 benchmark (None, sign flips,
misreads). Rejects are left untouched for the W7800 32B re-pass.

Writes: net/vat/gross (+invoice_date when it parses), extraction_method=
'vision_ocr', extraction_confidence=0.70, pipeline_version='u281-v1'.
Idempotent: only rows still missing a gross are selected.

Run on host (needs localhost:8003 render + localhost:11434 ollama):
  nohup python3 scripts/u281-vision-ocr-drain.py > logs/u281-drain.log 2>&1 &
"""
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from datetime import datetime

VISION_MODEL = os.environ.get("VISION_MODEL", "qwen2.5vl:7b")
RENDER_URL = "http://localhost:8003/render-page1-png?width=1400"
OLLAMA_URL = "http://localhost:11434/api/generate"
LIMIT = int(sys.argv[1]) if len(sys.argv) > 1 else 200

PROMPT = (
    "This is an invoice. Read it carefully and return ONLY a JSON object, no other text:\n"
    '{"vendor": "<supplier name>", "invoice_number": "<number or null>", '
    '"invoice_date": "<YYYY-MM-DD or null>", "net": <number or null>, '
    '"vat": <number or null>, "gross": <number or null>}\n'
    "gross is the total amount payable including VAT. Use null for anything not visible."
)


def psql(sql: str) -> list[list[str]]:
    out = subprocess.run(
        ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres",
         "-d", "homeai", "-tA", "-F", "\t", "-c", f"SET app.current_entity='all'; {sql}"],
        capture_output=True, text=True, timeout=60).stdout
    return [l.split("\t") for l in out.splitlines() if l.strip() and l != "SET"]


def psql_exec(sql: str, ok_tag: str) -> bool:
    r = subprocess.run(
        ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres",
         "-d", "homeai", "-v", "ON_ERROR_STOP=1", "-tA", "-c",
         f"SET app.current_entity='all'; {sql}"],
        capture_output=True, text=True, timeout=60)
    return r.returncode == 0 and ok_tag in r.stdout


def render_png(pdf_path: str, page: int = 0) -> tuple[bytes, int]:
    with open(pdf_path, "rb") as f:
        body = f.read()
    boundary = "----u281drain"
    payload = (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
        f"filename=\"doc.pdf\"\r\nContent-Type: application/pdf\r\n\r\n"
    ).encode() + body + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(f"{RENDER_URL}&page={page}", data=payload, method="POST",
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    resp = urllib.request.urlopen(req, timeout=90)
    return resp.read(), int(resp.headers.get("X-Page-Count", "1"))


def vision_extract(png: bytes) -> dict:
    req = urllib.request.Request(OLLAMA_URL, method="POST",
        data=json.dumps({"model": VISION_MODEL, "prompt": PROMPT,
                         "images": [base64.b64encode(png).decode()],
                         "stream": False,
                         "options": {"temperature": 0, "num_predict": 300}}).encode(),
        headers={"Content-Type": "application/json"})
    raw = json.loads(urllib.request.urlopen(req, timeout=300).read()).get("response", "").strip()
    if raw.startswith("```"):
        raw = raw.strip("`")
        raw = raw[4:] if raw.lower().startswith("json") else raw
    try:
        return json.loads(raw[raw.index("{"):raw.rindex("}") + 1])
    except Exception:
        return {}


def extract_document(pdf_path: str, max_pages: int = 3) -> dict:
    png0, n_pages = render_png(pdf_path, 0)
    order = list(range(n_pages - 1, -1, -1))[:max_pages]
    if 0 not in order:
        order.append(0)
    first = {}
    for p in order:
        png = png0 if p == 0 else render_png(pdf_path, p)[0]
        res = vision_extract(png)
        if not first:
            first = res
        if isinstance(res.get("gross"), (int, float)):
            return res
    return first


def gate(res: dict):
    """Returns (net, vat, gross) if arithmetic validates, else None."""
    g, n, v = res.get("gross"), res.get("net"), res.get("vat")
    if not isinstance(g, (int, float)) or not (0 < float(g) < 50000):
        return None
    if isinstance(n, (int, float)) and isinstance(v, (int, float)):
        if abs((float(n) + float(v)) - float(g)) <= 0.02:
            return round(float(n), 2), round(float(v), 2), round(float(g), 2)
        return None
    # net==gross with no VAT line (zero-rated) is acceptable when explicit
    if isinstance(n, (int, float)) and v in (0, None) and abs(float(n) - float(g)) <= 0.02:
        return round(float(n), 2), 0.0, round(float(g), 2)
    return None


def parse_date(s):
    if not s or not isinstance(s, str):
        return None
    m = re.match(r"^(\d{4})-(\d{2})-(\d{2})$", s.strip())
    if m:
        return s.strip()
    m = re.match(r"^(\d{1,2})/(\d{1,2})/(\d{2,4})$", s.strip())  # d/m/y UK
    if m:
        d_, mo, y = m.groups()
        y = ("20" + y) if len(y) == 2 else y
        try:
            return datetime(int(y), int(mo), int(d_)).date().isoformat()
        except ValueError:
            return None
    return None


def main():
    rows = psql(f"""
      SELECT id, pdf_local_path FROM vendor_invoice_inbox
       WHERE extraction_method='pdf_low_conf'
         AND (pdf_text_extracted IS NULL OR pdf_text_extracted='')
         AND pdf_local_path IS NOT NULL
         AND coalesce(gross_amount,0)=0
         AND coalesce(is_statement,false)=false
       ORDER BY received_at DESC LIMIT {LIMIT};""")
    print(f"{datetime.now().isoformat()} u281 drain start: {len(rows)} candidates, model={VISION_MODEL}")
    acc = rej = err = 0
    for inv_id, path in rows:
        if not os.path.exists(path):
            print(f"#{inv_id} SKIP missing pdf")
            continue
        try:
            res = extract_document(path)
            ok = gate(res)
            if ok:
                n, v, g = ok
                dt = parse_date(res.get("invoice_date"))
                date_sql = f"'{dt}'" if dt else "invoice_date"
                done = psql_exec(f"""
                    UPDATE vendor_invoice_inbox
                       SET net_amount={n}, vat_amount={v}, gross_amount={g},
                           invoice_date=COALESCE(invoice_date, {('DATE ' + chr(39) + dt + chr(39)) if dt else 'NULL'}),
                           extraction_method='vision_ocr', extraction_confidence=0.70,
                           extracted_at=now(), pipeline_version='u281-v1'
                     WHERE id={int(inv_id)} AND coalesce(gross_amount,0)=0
                     RETURNING 'OK';""", "OK")
                if done:
                    acc += 1
                    print(f"#{inv_id} ACCEPT net={n} vat={v} gross={g} date={dt}")
                else:
                    err += 1
                    print(f"#{inv_id} WRITE-FAIL (gate passed)")
            else:
                rej += 1
                print(f"#{inv_id} REJECT {json.dumps({k: res.get(k) for k in ('net','vat','gross')})}")
        except Exception as e:
            err += 1
            print(f"#{inv_id} ERROR {str(e)[:100]}")
        time.sleep(1)  # be gentle to the card
    print(f"{datetime.now().isoformat()} u281 done: accepted={acc} rejected={rej} errors={err} of {len(rows)}")


if __name__ == "__main__":
    main()
