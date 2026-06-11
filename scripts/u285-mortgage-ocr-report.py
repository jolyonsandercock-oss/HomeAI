#!/usr/bin/env python3
"""u285-mortgage-ocr-report.py — vision-OCR the image-only Principality
mortgage statements (Tesseract got only the CamScanner watermark) and EMAIL
a field-extraction report to Jo. REPORT-ONLY: no mortgage-table writes —
statement data lands in mortgage_statement_periods only after Jo verifies.

Flow: copy originals out of Paperless (ids 12-18) → render each page via
pdfplumber-service → qwen2.5vl field extraction per page → consolidated email.
Run on host. GPU contention with u281 is fine (ollama serialises).
"""
import base64
import json
import os
import subprocess
import urllib.request
from datetime import datetime

VISION_MODEL = os.environ.get("VISION_MODEL", "qwen2.5vl:7b")
RENDER_URL = "http://localhost:8003/render-page1-png?width=1500"
OLLAMA_URL = "http://localhost:11434/api/generate"
OUTDIR = "/home_ai/storage/mortgage-scans"
DOC_IDS = [12, 13, 14, 15, 16, 17, 18]

PROMPT = (
    "This is a page from a UK mortgage statement (Principality Building Society). "
    "Read it carefully and return ONLY JSON:\n"
    '{"account_number": "<ref like 123456-01 or null>", "statement_period": "<text or null>", '
    '"opening_balance": <number or null>, "closing_balance": <number or null>, '
    '"interest_charged": <number or null>, "payments_received": <number or null>, '
    '"property_or_name": "<text or null>"}\n'
    "Balances are typically large negative-amortising loan amounts. Use null when not on this page."
)


def render(pdf_path, page):
    with open(pdf_path, "rb") as f:
        body = f.read()
    b = "----u285"
    payload = (f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"d.pdf\"\r\n"
               f"Content-Type: application/pdf\r\n\r\n").encode() + body + f"\r\n--{b}--\r\n".encode()
    req = urllib.request.Request(f"{RENDER_URL}&page={page}", data=payload, method="POST",
        headers={"Content-Type": f"multipart/form-data; boundary={b}"})
    r = urllib.request.urlopen(req, timeout=90)
    return r.read(), int(r.headers.get("X-Page-Count", "1"))


def extract(png):
    req = urllib.request.Request(OLLAMA_URL, method="POST",
        data=json.dumps({"model": VISION_MODEL, "prompt": PROMPT,
                         "images": [base64.b64encode(png).decode()], "stream": False,
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


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    rows_html = []
    for did in DOC_IDS:
        # paperless originals live at documents/originals/<archive_serial>; use the
        # DB to resolve the stored filename, then docker cp out.
        fn = subprocess.run(
            ["docker", "exec", "homeai-postgres", "psql", "-d", "paperless", "-U", "paperless",
             "-tA", "-c", f"SELECT filename FROM documents_document WHERE id={did};"],
            capture_output=True, text=True, timeout=20).stdout.strip()
        if not fn:
            rows_html.append(f"<tr><td>{did}</td><td colspan=7>no filename in paperless DB</td></tr>")
            continue
        local = f"{OUTDIR}/{did}.pdf"
        subprocess.run(["docker", "cp", f"homeai-paperless:/usr/src/paperless/media/documents/originals/{fn}", local],
                       capture_output=True, timeout=60)
        if not os.path.exists(local):
            rows_html.append(f"<tr><td>{did}</td><td colspan=7>could not copy {fn}</td></tr>")
            continue
        try:
            _, n_pages = render(local, 0)
        except Exception as e:
            rows_html.append(f"<tr><td>{did}</td><td colspan=7>render failed: {str(e)[:60]}</td></tr>")
            continue
        for p in range(min(n_pages, 6)):
            try:
                png, _ = render(local, p)
                f = extract(png)
                if not any(v not in (None, "") for v in f.values()):
                    continue
                rows_html.append(
                    f"<tr><td>{did} p{p+1}</td>"
                    f"<td>{f.get('account_number') or '—'}</td>"
                    f"<td>{f.get('statement_period') or '—'}</td>"
                    f"<td align=right>{f.get('opening_balance') or '—'}</td>"
                    f"<td align=right>{f.get('closing_balance') or '—'}</td>"
                    f"<td align=right>{f.get('interest_charged') or '—'}</td>"
                    f"<td align=right>{f.get('payments_received') or '—'}</td>"
                    f"<td>{(f.get('property_or_name') or '—')[:30]}</td></tr>")
                print(f"{datetime.now().isoformat()} doc {did} p{p+1}: {json.dumps(f)[:120]}")
            except Exception as e:
                print(f"doc {did} p{p+1} ERROR {str(e)[:80]}")
    body = ("<div style='font-family:Segoe UI,Arial,sans-serif;font-size:14px'>"
            "<p><b>Mortgage statement vision-OCR — extraction report (NOTHING written to DB)</b><br>"
            "Image-only Principality scans (Paperless 12-18) read by the local vision model. "
            "Verify the figures against the paper statements; on your OK these load into "
            "mortgage_statement_periods.</p>"
            "<table border=0 cellpadding=4 style='border-collapse:collapse;font-size:12px' >"
            "<tr><th>Doc/page</th><th>Account</th><th>Period</th><th>Opening</th><th>Closing</th>"
            "<th>Interest</th><th>Payments</th><th>Name/property</th></tr>"
            + "".join(rows_html) + "</table></div>")
    # send via bot (inside bot-responder network) — pipe through docker
    payload = json.dumps({"to": "jolyon.sandercock@gmail.com",
                          "subject": "[Home AI] Mortgage statements — vision-OCR extraction for your verification",
                          "body_html": body, "body_text": "HTML email."})
    p = subprocess.run(["docker", "exec", "-i", "homeai-bot-responder", "python3", "-c",
        "import sys,urllib.request;u=urllib.request.Request('http://google-fetch:8011/send/bot',"
        "data=sys.stdin.buffer.read(),headers={'Content-Type':'application/json'},method='POST');"
        "print(urllib.request.urlopen(u,timeout=20).status)"],
        input=payload, capture_output=True, text=True, timeout=60)
    print("email send:", p.stdout.strip() or p.stderr[:100])


if __name__ == "__main__":
    main()
