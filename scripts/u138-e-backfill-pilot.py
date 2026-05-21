#!/usr/bin/env python3
"""
u138-e-backfill-pilot.py — extract gross/net/vat/date/vendor from un-extracted
vendor_invoice_inbox rows. Pilot mode runs --limit rows then stops.

Run inside any container with anthropic SDK + asyncpg + httpx (e.g. homeai-bot-responder):

  docker cp scripts/u138-e-backfill-pilot.py homeai-bot-responder:/tmp/p.py
  docker exec -e PG_DSN=postgresql://postgres:PW@homeai-postgres:5432/homeai \\
              homeai-bot-responder python /tmp/p.py --limit 50 [--dry-run]
"""
import argparse
import asyncio
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.request


def _parse_date(s):
    if not s:
        return None
    if isinstance(s, dt.date):
        return s
    try:
        return dt.date.fromisoformat(str(s)[:10])
    except Exception:
        return None

import anthropic
import asyncpg
import httpx

MODEL = "claude-haiku-4-5-20251001"
PDFPLUMBER_URL = os.environ.get("PDFPLUMBER_URL", "http://homeai-pdfplumber:8003")

SYSTEM_PROMPT = """You are an invoice-extraction assistant. Given the raw text of an invoice PDF, return a strict JSON object with these keys (use null when unsure):

  vendor_name   — string (legal name, no email address)
  invoice_date  — ISO YYYY-MM-DD
  due_date      — ISO YYYY-MM-DD or null
  gross_amount  — number (total including VAT) GBP
  net_amount    — number (subtotal before VAT) GBP
  vat_amount    — number (VAT total) GBP
  vat_rate      — number percent (e.g. 20)
  is_statement  — boolean (true if statement of account, not invoice)
  confidence    — number 0..1

Reply with ONLY the JSON object. No commentary."""


def load_anthropic_key() -> str:
    fpath = "/run/secrets/anthropic-api-key"
    if os.path.exists(fpath):
        with open(fpath) as f:
            k = f.read().strip()
            if k:
                return k
    token = os.environ.get("VAULT_TOKEN", "")
    addr = os.environ.get("VAULT_ADDR", "http://vault:8200")
    if token:
        req = urllib.request.Request(f"{addr}/v1/secret/data/anthropic",
                                     headers={"X-Vault-Token": token})
        return json.loads(urllib.request.urlopen(req).read())["data"]["data"]["api_key"]
    return ""


async def extract_pdf_text(http: httpx.AsyncClient, pdf_path: str) -> str:
    try:
        with open(pdf_path, "rb") as f:
            files = {"file": (os.path.basename(pdf_path), f, "application/pdf")}
            r = await http.post(f"{PDFPLUMBER_URL}/extract-pdf", files=files, timeout=60)
            r.raise_for_status()
            data = r.json()
            return data.get("text") or data.get("content") or ""
    except FileNotFoundError:
        return ""


def haiku_extract(client: anthropic.Anthropic, pdf_text: str) -> dict:
    msg = client.messages.create(
        model=MODEL,
        max_tokens=512,
        system=[{"type": "text", "text": SYSTEM_PROMPT,
                 "cache_control": {"type": "ephemeral"}}],
        messages=[{"role": "user", "content": pdf_text[:8000]}],
    )
    text = msg.content[0].text.strip()
    text = re.sub(r"^```(?:json)?\s*", "", text)
    text = re.sub(r"\s*```$", "", text)
    try:
        parsed = json.loads(text)
    except Exception:
        parsed = {"_parse_error": text[:200]}
    parsed["_usage"] = {
        "input_tokens": msg.usage.input_tokens,
        "output_tokens": msg.usage.output_tokens,
        "cache_creation": getattr(msg.usage, "cache_creation_input_tokens", 0) or 0,
        "cache_read": getattr(msg.usage, "cache_read_input_tokens", 0) or 0,
    }
    return parsed


def cost_gbp(u: dict) -> float:
    rate = 0.79
    usd = (u["input_tokens"] * 0.80 + u["output_tokens"] * 4.00 +
           u["cache_creation"] * 1.00 + u["cache_read"] * 0.08) / 1_000_000
    return usd * rate


async def amain():
    p = argparse.ArgumentParser()
    p.add_argument("--limit", type=int, default=50)
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    dsn = os.environ.get("PG_DSN")
    if not dsn:
        print("FAIL: PG_DSN required", file=sys.stderr)
        return 1

    key = load_anthropic_key()
    if not key:
        print("FAIL: no anthropic key", file=sys.stderr)
        return 1
    client = anthropic.Anthropic(api_key=key)
    http = httpx.AsyncClient()

    conn = await asyncpg.connect(dsn)
    try:
        await conn.execute("SELECT home_ai.set_realm('owner')")
        rows = await conn.fetch("""
            SELECT id, vendor_name, pdf_local_path
              FROM vendor_invoice_inbox
             WHERE pdf_local_path IS NOT NULL
               AND gross_amount IS NULL
               AND status NOT IN ('duplicate','ignored','linked')
             ORDER BY received_at DESC
             LIMIT $1
        """, args.limit)
        print(f"selected {len(rows)} rows")

        ok = 0
        total_cost = 0.0
        for i, r in enumerate(rows, 1):
            t0 = time.time()
            pdf_text = await extract_pdf_text(http, r["pdf_local_path"])
            if not pdf_text:
                print(f"[{i:02d}/{len(rows)}] id={r['id']:>5} SKIP (pdf empty/missing)")
                continue
            try:
                parsed = haiku_extract(client, pdf_text)
            except Exception as e:
                print(f"[{i:02d}/{len(rows)}] id={r['id']:>5} FAIL haiku: {e}")
                continue
            c = cost_gbp(parsed["_usage"])
            total_cost += c
            dur = int((time.time() - t0) * 1000)
            print(f"[{i:02d}/{len(rows)}] id={r['id']:>5} "
                  f"v={(parsed.get('vendor_name') or '?')[:22]:<22} "
                  f"gross={parsed.get('gross_amount')} date={parsed.get('invoice_date')} "
                  f"£{c:.4f} {dur}ms")
            if not args.dry_run and parsed.get("gross_amount") is not None:
                await conn.execute("""
                    UPDATE vendor_invoice_inbox SET
                      vendor_name      = COALESCE($2, vendor_name),
                      invoice_date     = COALESCE($3::date, invoice_date),
                      due_date         = COALESCE($4::date, due_date),
                      gross_amount     = $5,
                      net_amount       = $6,
                      vat_amount       = $7,
                      vat_rate         = $8,
                      is_statement     = COALESCE($9, FALSE),
                      extraction_confidence = $10,
                      extraction_method = 'haiku-u138e',
                      extracted_at     = NOW(),
                      status           = 'extracted'
                     WHERE id = $1
                """, r["id"], parsed.get("vendor_name"),
                   _parse_date(parsed.get("invoice_date")),
                   _parse_date(parsed.get("due_date")),
                   parsed.get("gross_amount"), parsed.get("net_amount"),
                   parsed.get("vat_amount"), parsed.get("vat_rate"),
                   parsed.get("is_statement"), parsed.get("confidence"))
            ok += 1
        print()
        print(f"PILOT DONE: {ok}/{len(rows)} extracted, total £{total_cost:.4f}")
    finally:
        await conn.close()
        await http.aclose()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(amain()))
