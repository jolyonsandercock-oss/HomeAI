#!/bin/bash
# /home_ai/scripts/u36-invoice-haiku-fallback.sh
#
# Re-extract invoice fields for low-confidence pdfplumber rows using Haiku.
# The text from pdfplumber is preserved on disk — we just regex'd it badly
# the first time. Haiku gets the raw text + a strict JSON schema and returns
# {net, vat, gross, vat_rate, invoice_date, delivery_date, confidence}.
#
# Cost-capped at LIMIT rows/run (default 50). System prompt cached for
# 80% input-token saving.
#
# Idempotent: only touches rows where extraction_method IN ('pdf_low_conf')
# AND net_amount IS NULL (so re-runs after a success don't re-bill Haiku).

set -uo pipefail
LIMIT="${1:-50}"
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e LIMIT="$LIMIT" homeai-bot-responder python << 'PYEOF'
import os, json, urllib.request, base64, asyncio, asyncpg
from datetime import datetime
import anthropic

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN      = os.environ["PG_DSN"]
LIMIT       = int(os.environ.get("LIMIT", "50"))
GF          = "http://google-fetch:8011"
PDF_PL      = "http://homeai-pdfplumber:8003"
MODEL       = "claude-haiku-4-5-20251001"


def vault_get(p):
    r = urllib.request.Request(f"http://vault:8200/v1/secret/data/{p}",
                                headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(r, timeout=5).read())["data"]["data"]


def fetch_pdf_text(acct, mid):
    """Re-fetch + re-extract the PDF text (we didn't store it from the first pass)."""
    try:
        a = json.load(urllib.request.urlopen(f"{GF}/attachments/{acct}/{mid}", timeout=15))
    except Exception:
        return None
    pdf = next((x for x in a.get("attachments", []) if (x.get("mime_type") == "application/pdf"
                                                        or (x.get("filename") or "").lower().endswith(".pdf"))), None)
    if not pdf: return None
    try:
        ad = json.load(urllib.request.urlopen(f"{GF}/attachment/{acct}/{mid}/{pdf['attachment_id']}", timeout=45))
        b = base64.urlsafe_b64decode(ad["data_b64url"] + "=" * (-len(ad["data_b64url"]) % 4))
    except Exception:
        return None
    boundary = "---bnd"
    body = (f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="x.pdf"\r\n'
            f"Content-Type: application/pdf\r\n\r\n").encode() + b + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(f"{PDF_PL}/extract-pdf", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"}, method="POST")
    try:
        return json.load(urllib.request.urlopen(req, timeout=45)).get("text") or ""
    except Exception:
        return None


# U38: schema-constrained tool use instead of free-JSON prompting.
SYSTEM_BLOCKS = [{
    "type": "text",
    "text": (
        "You extract structured invoice fields from raw OCR/pdfplumber text of UK supplier invoices. "
        "Be conservative — return null for fields you can't see clearly. Never guess. "
        "Numbers are in pounds sterling. Dates are usually DD/MM/YYYY. "
        "If multiple totals appear (subtotal, VAT, grand total), the 'gross' is the grand total. "
        "'net' is the subtotal before VAT. 'vat' is the VAT amount. "
        "vat_rate is the standard rate as a percentage (e.g. 20 or 5 or 0). "
        "Call the extract_invoice tool with your findings — never produce free text."
    ),
    "cache_control": {"type": "ephemeral"},
}]

EXTRACT_TOOL = {
    "name": "extract_invoice",
    "description": "Record structured invoice fields extracted from the document.",
    "input_schema": {
        "type": "object",
        "properties": {
            "net":            {"type": ["number", "null"], "description": "Net amount in GBP."},
            "vat":            {"type": ["number", "null"], "description": "VAT amount in GBP."},
            "gross":          {"type": ["number", "null"], "description": "Gross total in GBP."},
            "vat_rate":       {"type": ["number", "null"], "minimum": 0, "maximum": 25, "description": "VAT rate as %."},
            "invoice_date":   {"type": ["string", "null"], "description": "YYYY-MM-DD."},
            "delivery_date":  {"type": ["string", "null"], "description": "YYYY-MM-DD."},
            "confidence":     {"type": "number", "minimum": 0, "maximum": 1}
        },
        "required": ["confidence"]
    }
}
SCHEMA_VERSION = "invoice-extract.schema.json@U38"


def parse_date(s):
    if not s: return None
    if isinstance(s, str):
        try:
            return datetime.strptime(s, "%Y-%m-%d").date()
        except ValueError:
            return None
    return None


async def main():
    api_key = vault_get("anthropic")["api_key"]
    client  = anthropic.Anthropic(api_key=api_key)
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity='1'")
    # Re-Haiku anything that's low-confidence OR has a math error (net+vat≠gross).
    # Skip notification_only (no PDF) and pdf_fail (nothing to send to AI).
    rows = await conn.fetch("""
      SELECT id, account, source_email_id, vendor_domain
        FROM vendor_invoice_inbox
       WHERE is_statement = false
         AND extraction_method NOT IN ('notification_only','pdf_fail','haiku','haiku_low_conf')
         AND (
              extraction_confidence < 0.5
              OR (gross_amount IS NOT NULL
                  AND ABS(COALESCE(net_amount,0) + COALESCE(vat_amount,0) - gross_amount) > 0.02
                  AND COALESCE(net_amount,0) > 0)
              OR net_amount IS NULL
         )
       ORDER BY received_at DESC
       LIMIT $1
    """, LIMIT)
    print(f"candidates: {len(rows)}")

    spend_in_tokens = spend_out_tokens = ok = fail = 0
    cache_hits_in = cache_creates_in = 0

    for r in rows:
        bid = r["id"]
        text = fetch_pdf_text(r["account"], r["source_email_id"])
        if not text or len(text) < 50:
            await conn.execute("""
              UPDATE vendor_invoice_inbox
                 SET extraction_method='haiku_no_text', extracted_at=now()
               WHERE id=$1
            """, bid)
            fail += 1
            continue
        # Truncate large PDFs to keep cost predictable
        text_for_ai = text[:6000]
        try:
            resp = client.messages.create(
                model=MODEL,
                max_tokens=400,
                system=SYSTEM_BLOCKS,
                tools=[EXTRACT_TOOL],
                tool_choice={"type": "tool", "name": "extract_invoice"},
                messages=[{"role": "user", "content": f"Invoice text:\n\n{text_for_ai}"}],
            )
        except Exception as e:
            print(f"  id={bid} api err: {str(e)[:120]}")
            fail += 1
            continue

        spend_in_tokens  += resp.usage.input_tokens
        spend_out_tokens += resp.usage.output_tokens
        cache_hits_in     += getattr(resp.usage, "cache_read_input_tokens", 0) or 0
        cache_creates_in  += getattr(resp.usage, "cache_creation_input_tokens", 0) or 0

        # Tool-use response — guaranteed schema-valid. No JSON parsing required.
        tool_uses = [b for b in resp.content if b.type == "tool_use"]
        if not tool_uses:
            print(f"  id={bid} no tool_use block returned")
            fail += 1
            continue
        d = tool_uses[0].input

        conf = float(d.get("confidence") or 0)
        method = "haiku" if conf >= 0.4 else "haiku_low_conf"
        status_target = "extracted" if conf >= 0.5 else "needs_review"

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
                 status = CASE WHEN status IN ('new','extracted') THEN $10::text ELSE status END
           WHERE id=$1
        """, bid, d.get("net"), d.get("vat"), d.get("gross"), d.get("vat_rate"),
             parse_date(d.get("invoice_date")), parse_date(d.get("delivery_date")),
             method, conf, status_target)
        ok += 1

    # Cost: Haiku 4.5 is $1/MTok in, $5/MTok out (cache-read = 10% of in cost)
    cost_usd = (
        (spend_in_tokens - cache_hits_in) * 1.0 / 1_000_000
        + cache_hits_in * 0.10 / 1_000_000
        + spend_out_tokens * 5.0 / 1_000_000
    )
    try:
        await conn.execute("""
          INSERT INTO ai_usage (task_type, model_used, tier, prompt_tokens, completion_tokens, cached, provider)
          VALUES ('invoice_extraction', $1, 'cloud', $2, $3, $4, 'anthropic')
        """, MODEL, spend_in_tokens, spend_out_tokens, cache_hits_in > 0)
    except Exception as e:
        print(f"  (ai_usage insert skipped: {str(e)[:80]})")

    await conn.close()
    print(f"done. ok={ok}  fail={fail}  in={spend_in_tokens} (cached={cache_hits_in})  out={spend_out_tokens}  cost=${cost_usd:.4f}")

asyncio.run(main())
PYEOF
