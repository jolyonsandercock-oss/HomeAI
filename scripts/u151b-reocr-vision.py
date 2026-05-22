#!/usr/bin/env python3
"""
U151b — Vision-OCR mortgage statement PDFs that Tesseract failed on.

The 7 Principality docs in Paperless (paperless_ids 12-18) are
CamScanner-produced image-only PDFs. Paperless's Tesseract pipeline
extracts only the "CamScanner" watermark, leaving statement data invisible
to the U80 mortgage parser. Result: 21 quarters listed as missing in
v_mortgage_coverage even though doc 33 (2026-05) contains the latest
2026 statement.

This script:
  1. Walks PDFs at /home_ai/data/mortgage-vision-ocr/paperless-<id>.pdf
  2. Converts each page to PNG via pdftoppm
  3. Sends each page to Haiku-vision with a Principality-statement
     extraction prompt
  4. Inserts extracted periods into mortgage_statement_periods

Usage:
  ANTHROPIC_API_KEY=<key> PG_DSN=postgresql://... python3 u151b-reocr-vision.py
"""
import asyncio
import asyncpg
import base64
import datetime
import decimal
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import urllib.request


def _to_date(v):
    if v is None or v == "": return None
    if isinstance(v, datetime.date): return v
    try: return datetime.date.fromisoformat(str(v)[:10])
    except: return None


def _to_dec(v):
    if v is None or v == "": return None
    try: return decimal.Decimal(str(v).replace(",", "").replace("£", "").strip())
    except: return None

ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY")
PG_DSN            = os.environ["PG_DSN"]
PDF_DIR           = Path("/home_ai/data/mortgage-vision-ocr")
MODEL             = "claude-haiku-4-5-20251001"

# Maps Principality account_ref to mortgage_accounts.id
ACCOUNT_REF_TO_ID = {}

SYSTEM = """You read scanned UK mortgage statements from Principality Building Society.

For each statement page you see, extract:
- account_ref     (text, e.g. "295905-02", "967002-01", looks like 6-digit/2-digit)
- period_start    (date, ISO YYYY-MM-DD)
- period_end      (date, ISO YYYY-MM-DD)
- balance_opening (decimal, GBP, no commas)
- balance_closing (decimal, GBP, no commas)
- interest_rate   (decimal percent, e.g. 4.85)
- monthly_payment (decimal, GBP)
- statement_type  (one of: 'quarterly','annual','interest_summary','other')

Return ONE JSON object per statement period detected on the page.
If the page is not a statement (cover letter, blank, summary), return
{"skip": true, "reason": "<short>"}.

If multiple statements on one page, return a JSON array.

Be conservative: if any field is unclear, set it to null. Don't guess.
"""


def pdf_to_pages(pdf_path: Path) -> list[bytes]:
    """Convert PDF pages → PNG bytes via pdftoppm."""
    out_dir = pdf_path.parent / f"_pages_{pdf_path.stem}"
    out_dir.mkdir(exist_ok=True)
    out_prefix = out_dir / "page"

    # 200dpi gives readable text without overwhelming token budget
    subprocess.run([
        "pdftoppm", "-png", "-r", "200",
        str(pdf_path), str(out_prefix)
    ], check=True)

    pages = sorted(out_dir.glob("page-*.png"))
    return [p.read_bytes() for p in pages]


def call_haiku_vision(image_bytes: bytes, page_no: int, source: str) -> dict:
    """Send one image to Haiku with the statement-extraction prompt."""
    if not ANTHROPIC_API_KEY:
        raise RuntimeError("ANTHROPIC_API_KEY not set")
    b64 = base64.standard_b64encode(image_bytes).decode("ascii")
    payload = {
        "model":      MODEL,
        "max_tokens": 1024,
        "system":     SYSTEM,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "image",
                 "source": {"type": "base64",
                            "media_type": "image/png",
                            "data": b64}},
                {"type": "text",
                 "text": f"Page {page_no} of {source}. Extract the statement(s)."}
            ]
        }]
    }
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(payload).encode(),
        headers={
            "x-api-key":         ANTHROPIC_API_KEY,
            "anthropic-version": "2023-06-01",
            "content-type":      "application/json",
        }
    )
    # U216 hardening: retry on 529 (overloaded), 503 (unavailable), 502 (bad gateway).
    import time
    last_err = None
    for attempt in range(6):
        try:
            r = urllib.request.urlopen(req, timeout=60)
            resp = json.loads(r.read())
            break
        except urllib.error.HTTPError as e:
            last_err = e
            if e.code in (529, 503, 502, 504, 429):
                backoff = min(60, 2 ** attempt * 5)  # 5, 10, 20, 40, 60, 60s
                print(f"    [HTTP {e.code}] attempt {attempt+1}/6 — backing off {backoff}s")
                time.sleep(backoff)
                continue
            raise
    else:
        raise last_err  # exhausted retries

    text = (resp.get("content") or [{}])[0].get("text", "")
    # Extract JSON from response
    m = re.search(r"\{[\s\S]*\}|\[[\s\S]*\]", text)
    if not m:
        return {"skip": True, "reason": "no JSON in response", "raw": text[:200]}
    try:
        return json.loads(m.group(0))
    except json.JSONDecodeError as e:
        return {"skip": True, "reason": f"JSON parse: {e}", "raw": text[:200]}


async def load_account_map(conn):
    rows = await conn.fetch(
        "SELECT id, account_ref FROM mortgage_accounts ORDER BY id"
    )
    return {r["account_ref"]: r["id"] for r in rows}


async def insert_period(conn, document_id: int, page_no: int, p: dict, account_map: dict):
    if p.get("skip"):
        return ("skip", p.get("reason", ""))

    if isinstance(p, list):
        # Recursive
        out = []
        for item in p:
            out.append(await insert_period(conn, document_id, page_no, item, account_map))
        return ("list", out)

    ref = (p.get("account_ref") or "").strip()
    if not ref or ref not in account_map:
        return ("unmapped", ref or "<missing>")

    mortgage_account_id = account_map[ref]
    period_start = _to_date(p.get("period_start"))
    if not period_start:
        return ("no_period_start", ref)

    # Real unique constraint is (mortgage_account_id, period_start).
    existing = await conn.fetchval(
        """SELECT id FROM mortgage_statement_periods
           WHERE mortgage_account_id=$1 AND period_start=$2""",
        mortgage_account_id, period_start
    )
    if existing:
        return ("dup", existing)

    new_id = await conn.fetchval(
        """INSERT INTO mortgage_statement_periods
             (mortgage_account_id, document_id, page_in_letter,
              period_start, period_end, balance_opening, balance_closing,
              interest_rate, monthly_payment, notes, realm)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'personal')
           ON CONFLICT (mortgage_account_id, period_start) DO NOTHING
           RETURNING id""",
        mortgage_account_id, document_id, page_no,
        period_start, _to_date(p.get("period_end")),
        _to_dec(p.get("balance_opening")), _to_dec(p.get("balance_closing")),
        _to_dec(p.get("interest_rate")), _to_dec(p.get("monthly_payment")),
        f"vision-ocr u151b {p.get('statement_type','')}"
    )
    if new_id is None:
        return ("dup_race", None)
    return ("inserted", new_id)


async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_realm = 'owner'")
    await conn.execute("SET app.realm_override_active = '1'")

    account_map = await load_account_map(conn)
    print(f"-- {len(account_map)} mortgage accounts mapped")
    for ref, mid in account_map.items():
        print(f"     {ref:15s} → id={mid}")

    pdfs = sorted(PDF_DIR.glob("paperless-*.pdf"))
    print(f"-- {len(pdfs)} PDFs to process")

    summary = {"inserted": 0, "dup": 0, "skip": 0, "unmapped": 0, "errors": 0}

    for pdf in pdfs:
        m = re.search(r"paperless-(\d+)\.pdf", pdf.name)
        if not m:
            continue
        paperless_id = int(m.group(1))
        document_id = await conn.fetchval(
            "SELECT id FROM documents WHERE paperless_id=$1", paperless_id
        )
        if document_id is None:
            print(f"  ✗ {pdf.name} — no document row for paperless_id={paperless_id}")
            summary["errors"] += 1
            continue
        print(f"\n── {pdf.name}  (document_id={document_id})")

        try:
            pages = pdf_to_pages(pdf)
        except Exception as e:
            print(f"  pdftoppm failed: {e}")
            summary["errors"] += 1
            continue
        print(f"  {len(pages)} pages")

        for i, img in enumerate(pages, 1):
            try:
                result = call_haiku_vision(img, i, pdf.name)
            except Exception as e:
                print(f"    page {i}: vision call failed: {e}")
                summary["errors"] += 1
                continue

            outcome = await insert_period(conn, document_id, i, result, account_map)
            kind = outcome[0]
            summary[kind] = summary.get(kind, 0) + 1
            print(f"    page {i}: {kind} {outcome[1]}")

    print()
    print(f"== summary: {summary}")
    await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
