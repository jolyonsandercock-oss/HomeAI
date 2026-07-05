#!/usr/bin/env python3
"""jr-capture-20260705-step2b-extract.py — one-off re-extraction of the 19 J&R
Foodservice (accounts@jrf.lls.com) needs_review invoices that have NO amount at
all (gross_amount IS NULL), part of the 2026-07-05 J&R capture-closure task.

TEXT path only (no vision): pdf_local_path already exists on disk for all 19
(so no Gmail/google-fetch round-trip needed); use cached pdf_text_extracted
where present, else pdfplumber :8003 /extract-pdf on the local file bytes.
gemma4-doc:latest, temperature 0, think:false (REQUIRED — gemma4 is a
thinking model and returns empty output without it, per project convention
in scripts/invoice-line-extract.py).

Gate: |net + vat - gross| <= 0.02. Write net/vat/gross + status='extracted'
ONLY on gate pass; otherwise leave untouched (still needs_review) and print
the reason. Idempotent: only touches rows still missing gross_amount.

Run:
  python3 scripts/oneoff/jr-capture-20260705-step2b-extract.py           # dry
  python3 scripts/oneoff/jr-capture-20260705-step2b-extract.py apply    # write
"""
import json
import re
import subprocess
import sys
import urllib.request

PDFPLUMBER = "http://localhost:8003/extract-pdf"
OLLAMA = "http://localhost:11434/api/generate"
MODEL = "gemma4-doc:latest"

IDS = [5274, 5266, 5248, 5249, 5236, 5234, 5235, 5210, 5211, 5212, 5213,
       5204, 5201, 5202, 5195, 5176, 5164, 9552, 16353]

MODE = sys.argv[1] if len(sys.argv) > 1 else "dry"


def psql(sql: str) -> list[list[str]]:
    out = subprocess.run(
        ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai",
         "-tA", "-F", "\t", "-c", f"SET app.current_entity='all'; SET app.current_realm='owner'; {sql}"],
        capture_output=True, text=True, timeout=60).stdout
    return [l.split("\t") for l in out.splitlines() if l.strip() and l != "SET"]


def psql_exec(sql: str) -> bool:
    r = subprocess.run(
        ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai",
         "-v", "ON_ERROR_STOP=1", "-tA", "-c",
         f"SET app.current_entity='all'; SET app.current_realm='owner'; {sql}"],
        capture_output=True, text=True, timeout=60)
    return r.returncode == 0


def pdfplumber_extract(pdf_path: str):
    with open(pdf_path, "rb") as f:
        raw = f.read()
    boundary = "----jrstep2b"
    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="doc.pdf"\r\n'
            f'Content-Type: application/pdf\r\n\r\n').encode() + raw + f'\r\n--{boundary}--\r\n'.encode()
    req = urllib.request.Request(PDFPLUMBER, data=body, method="POST",
                                  headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    return json.loads(urllib.request.urlopen(req, timeout=60).read()).get("text", "")


PROMPT = (
    "You are extracting the HEADER TOTALS from a UK supplier invoice (J&R Foodservice). "
    "Return ONLY a JSON object, no prose: "
    '{"net": <number or null>, "vat": <number or null>, "gross": <number or null>, '
    '"invoice_date": "<YYYY-MM-DD or null>"}. '
    "net = the Ex VAT / goods total. vat = the VAT amount. gross = the total amount payable "
    "including VAT (net+vat). Numbers plain, no currency symbols or commas."
)


def ollama_extract(text: str):
    body = json.dumps({
        "model": MODEL, "prompt": PROMPT + "\n\n---\n" + text[:6000],
        "stream": False, "think": False, "format": "json",
        "options": {"temperature": 0},
    }).encode()
    for host in ("http://localhost:11434", "http://homeai-ollama:11434"):
        try:
            req = urllib.request.Request(host + "/api/generate", data=body,
                                          headers={"Content-Type": "application/json"})
            raw = json.loads(urllib.request.urlopen(req, timeout=180).read()).get("response", "")
            return json.loads(raw)
        except Exception:
            continue
    return {}


def gate(res: dict):
    def num(x):
        try:
            return round(float(str(x).replace(",", "").replace("£", "").strip()), 2)
        except Exception:
            return None
    g, n, v = num(res.get("gross")), num(res.get("net")), num(res.get("vat"))
    if g is None or not (0 < g < 50000):
        return None
    if n is not None and v is not None and abs((n + v) - g) <= 0.02:
        return n, v, g
    if n is not None and (v in (0, None)) and abs(n - g) <= 0.02:
        return n, 0.0, g
    return None


def parse_date(s):
    if not s or not isinstance(s, str):
        return None
    m = re.match(r"^(\d{4})-(\d{2})-(\d{2})$", s.strip())
    return s.strip() if m else None


def main():
    # NOTE: pdf_text_extracted is multi-line free text -- fetching it via the tab/newline
    # -tA psql pipe corrupts row-splitting (each embedded newline becomes a phantom row).
    # Fetch id+path only here; always re-render text fresh via pdfplumber on the local file.
    rows = psql(f"""SELECT id, pdf_local_path
                     FROM vendor_invoice_inbox WHERE id IN ({','.join(map(str, IDS))})
                     AND coalesce(gross_amount,0)=0 ORDER BY id;""")
    print(f"== step2b MODE={MODE} candidates={len(rows)} ==")
    acc = rej = err = 0
    for r in rows:
        inv_id, path = r[0], r[1]
        try:
            text = pdfplumber_extract(path)
        except Exception as e:
            err += 1
            print(f"#{inv_id} ERROR pdfplumber:{str(e)[:100]}")
            continue
        if not text or not text.strip():
            err += 1
            print(f"#{inv_id} ERROR empty-text")
            continue
        try:
            res = ollama_extract(text)
        except Exception as e:
            err += 1
            print(f"#{inv_id} ERROR ollama:{str(e)[:100]}")
            continue
        ok = gate(res)
        if not ok:
            rej += 1
            print(f"#{inv_id} REJECT {json.dumps({k: res.get(k) for k in ('net', 'vat', 'gross')})}")
            continue
        n, v, g = ok
        dt = parse_date(res.get("invoice_date"))
        acc += 1
        print(f"#{inv_id} ACCEPT net={n} vat={v} gross={g} date={dt}")
        if MODE == "apply":
            date_sql = f"COALESCE(invoice_date, DATE '{dt}')" if dt else "invoice_date"
            ok_write = psql_exec(f"""
                UPDATE vendor_invoice_inbox
                   SET net_amount={n}, vat_amount={v}, gross_amount={g},
                       invoice_date={date_sql},
                       extraction_method='pdf_text_gemma4doc', extraction_confidence=0.90,
                       extracted_at=now(), pipeline_version='jr-capture-20260705',
                       status='extracted',
                       notes = left(coalesce(notes,'')||' [jr-capture-20260705:text-path-reextract]', 500)
                 WHERE id={int(inv_id)} AND coalesce(gross_amount,0)=0;""")
            if not ok_write:
                print(f"#{inv_id} WRITE-FAIL")
    print(f"\naccepted={acc} rejected={rej} errors={err} of {len(rows)}"
          + ("  (DRY - no writes)" if MODE != "apply" else "  (APPLIED)"))


if __name__ == "__main__":
    main()
