#!/usr/bin/env python3
"""u276-vision-ocr-bench.py — benchmark local vision OCR on real invoices.

Design: ground truth comes free — take invoices whose amounts were extracted
from the PDF TEXT layer (extraction_method='pdf'), render page 1 to PNG, and
ask the vision model to read the IMAGE. Accuracy = % whose gross matches the
known value. Then run the true stuck ones (image-only, no text layer) for a
qualitative read — they have no ground truth, so we report what was extracted.

Interim model: qwen2.5vl:7b on the RTX 3060. The pipeline is model-agnostic —
on W7800 arrival re-run with VISION_MODEL=qwen2.5vl:32b (see HOME-AI-STRETCH
§3.9 W7800 plan). Stdlib only; uses pdfplumber-service /render-page1-png and
ollama /api/generate.

Usage: python3 scripts/u276-vision-ocr-bench.py [n_truth] [n_stuck]
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.request

VISION_MODEL = os.environ.get("VISION_MODEL", "qwen2.5vl:7b")
RENDER_URL = "http://localhost:8003/render-page1-png?width=1400"
OLLAMA_URL = "http://localhost:11434/api/generate"
N_TRUTH = int(sys.argv[1]) if len(sys.argv) > 1 else 20
N_STUCK = int(sys.argv[2]) if len(sys.argv) > 2 else 10

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
        capture_output=True, text=True, timeout=30).stdout
    return [l.split("\t") for l in out.splitlines() if l.strip() and l != "SET"]


def render_png(pdf_path: str, page: int = 0) -> tuple[bytes, int]:
    """Render one page; returns (png_bytes, total_page_count)."""
    with open(pdf_path, "rb") as f:
        body = f.read()
    boundary = "----u276bench"
    payload = (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
        f"filename=\"doc.pdf\"\r\nContent-Type: application/pdf\r\n\r\n"
    ).encode() + body + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(f"{RENDER_URL}&page={page}", data=payload, method="POST",
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    resp = urllib.request.urlopen(req, timeout=60)
    return resp.read(), int(resp.headers.get("X-Page-Count", "1"))


def extract_document(pdf_path: str, max_pages: int = 3) -> tuple[dict, float, int]:
    """Multi-page extraction: invoice totals usually live on the LAST page, so
    scan back-to-front and return the first page that yields a gross. Falls
    back to the front page's result. Returns (fields, total_seconds, pages_tried)."""
    png0, n_pages = render_png(pdf_path, 0)
    total_dt = 0.0
    tried = 0
    first_result: dict = {}
    # back-to-front page order, capped; page 0 last as fallback
    order = list(range(n_pages - 1, -1, -1))[:max_pages]
    if 0 not in order:
        order.append(0)
    for p in order:
        png = png0 if p == 0 else render_png(pdf_path, p)[0]
        res, dt = vision_extract(png)
        total_dt += dt
        tried += 1
        if not first_result:
            first_result = res
        if isinstance(res.get("gross"), (int, float)):
            return res, total_dt, tried
    return first_result, total_dt, tried


def vision_extract(png: bytes) -> tuple[dict, float]:
    t0 = time.monotonic()
    req = urllib.request.Request(OLLAMA_URL, method="POST",
        data=json.dumps({
            "model": VISION_MODEL,
            "prompt": PROMPT,
            "images": [base64.b64encode(png).decode()],
            "stream": False,
            "options": {"temperature": 0, "num_predict": 300},
        }).encode(),
        headers={"Content-Type": "application/json"})
    resp = json.loads(urllib.request.urlopen(req, timeout=300).read())
    dt = time.monotonic() - t0
    raw = resp.get("response", "")
    # tolerate ```json fences
    raw = raw.strip()
    if raw.startswith("```"):
        raw = raw.strip("`")
        raw = raw[4:] if raw.lower().startswith("json") else raw
    try:
        start, end = raw.index("{"), raw.rindex("}") + 1
        return json.loads(raw[start:end]), dt
    except Exception:
        return {"_parse_error": raw[:200]}, dt


def main():
    print(f"── u276 vision OCR bench · model={VISION_MODEL} ──")

    truth = psql(f"""
      SELECT id, pdf_local_path, gross_amount, coalesce(vendor_name,'')
        FROM vendor_invoice_inbox
       WHERE extraction_method='pdf' AND coalesce(gross_amount,0)<>0
         AND pdf_local_path IS NOT NULL
         AND coalesce(is_statement,false)=false   -- statements have no single gross
       ORDER BY id DESC LIMIT {N_TRUTH};""")
    stuck = psql(f"""
      SELECT id, pdf_local_path, coalesce(vendor_name,'')
        FROM vendor_invoice_inbox
       WHERE extraction_method='pdf_low_conf'
         AND (pdf_text_extracted IS NULL OR pdf_text_extracted='')
         AND pdf_local_path IS NOT NULL
         AND coalesce(is_statement,false)=false
       ORDER BY id DESC LIMIT {N_STUCK};""")

    hits = misses = errors = 0
    times = []
    print(f"\n[A] ground-truth set ({len(truth)} invoices with known gross):")
    for inv_id, path, gross, vendor in truth:
        if not os.path.exists(path):
            print(f"  #{inv_id}  SKIP (pdf missing on host: {path})")
            continue
        try:
            res, dt, tried = extract_document(path)
            times.append(dt)
            got = res.get("gross")
            want = float(gross)
            ok = isinstance(got, (int, float)) and abs(float(got) - want) < 0.01
            hits += ok
            misses += (not ok)
            mark = "✓" if ok else "✗"
            print(f"  #{inv_id}  {mark}  want={want:.2f} got={got}  {dt:.1f}s/{tried}pg  {vendor[:40]}")
        except Exception as e:
            errors += 1
            print(f"  #{inv_id}  ERROR {str(e)[:80]}")

    print(f"\n[B] stuck set ({len(stuck)} image-only, no ground truth):")
    for inv_id, path, vendor in stuck:
        if not os.path.exists(path):
            print(f"  #{inv_id}  SKIP (pdf missing: {path})")
            continue
        try:
            res, dt, tried = extract_document(path)
            times.append(dt)
            print(f"  #{inv_id}  gross={res.get('gross')} net={res.get('net')} "
                  f"date={res.get('invoice_date')} vendor={str(res.get('vendor'))[:30]}  {dt:.1f}s/{tried}pg")
        except Exception as e:
            print(f"  #{inv_id}  ERROR {str(e)[:80]}")

    n = hits + misses
    print("\n── summary ──")
    if n:
        print(f"gross accuracy: {hits}/{n} = {100*hits/n:.0f}%  (errors: {errors})")
    if times:
        print(f"latency: avg {sum(times)/len(times):.1f}s  max {max(times):.1f}s  ({len(times)} calls)")


if __name__ == "__main__":
    main()
