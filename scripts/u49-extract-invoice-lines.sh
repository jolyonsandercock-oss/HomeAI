#!/bin/bash
# /home_ai/scripts/u49-extract-invoice-lines.sh
#
# Line-item extraction for one invoice (or all). Haiku tool-use → JSON →
# vendor_invoice_lines. Sonnet escalation if Haiku sum-of-lines is more than
# 5% off the invoice net total.
#
# Usage:
#   u49-extract-invoice-lines.sh             # all candidates, no limit
#   u49-extract-invoice-lines.sh 50          # cap at 50 invoices
#   u49-extract-invoice-lines.sh 1 123       # just invoice 123

set -uo pipefail
LIMIT="${1:-200}"
ONLY_ID="${2:-}"

VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e LIMIT="$LIMIT" -e ONLY_ID="$ONLY_ID" \
  homeai-playwright python <<'PYEOF'
import os, json, time, asyncio, asyncpg, urllib.request
import pdfplumber, anthropic

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN      = os.environ["PG_DSN"]
LIMIT       = int(os.environ.get("LIMIT", "200"))
ONLY_ID     = os.environ.get("ONLY_ID") or None

HAIKU       = "claude-haiku-4-5-20251001"
SONNET      = "claude-sonnet-4-6"
SCHEMA_VERSION = "line-extractor@U49"

def vault_get(p):
    r = urllib.request.Request(f"http://vault:8200/v1/secret/data/{p}",
                                headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(r, timeout=5).read())["data"]["data"]

CLIENT = anthropic.Anthropic(api_key=vault_get("anthropic")["api_key"], max_retries=8, timeout=120)

SYSTEM = [{
  "type": "text",
  "text": (
    "You extract line items from a UK supplier invoice. Return one entry per "
    "goods/service line. Ignore subtotals, VAT, totals, delivery charges "
    "(unless they're the entire invoice purpose), discounts, payment terms, "
    "address blocks, bank details, and signatures.\n\n"
    "For each line return:\n"
    "  description — verbatim from invoice (clean trailing whitespace)\n"
    "  qty         — numeric quantity\n"
    "  unit        — L, kg, g, ml, each, case, bottle, dozen, pack, ...\n"
    "  unit_price  — £ per unit, ex-VAT\n"
    "  line_total  — £ for the line, ex-VAT\n"
    "  suggested_family — one of: milk, wine, beer, spirits, soft_drink, "
    "coffee, tea, meat, fish, cheese, dairy_other, veg, fruit, bakery, "
    "condiment, packaging, utility, software, service, sundry\n\n"
    "If unit/qty is ambiguous (e.g. 'pack of 12'), put the descriptor in "
    "unit and 1 in qty. Empty array if no clear line items."
  ),
  "cache_control": {"type": "ephemeral"},
}]

TOOL = {
  "name": "extract_invoice_lines",
  "description": "Structured line items from one supplier invoice.",
  "input_schema": {
    "type": "object",
    "properties": {
      "lines": {
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "description":       {"type": "string"},
            "qty":               {"type": ["number","null"]},
            "unit":              {"type": ["string","null"]},
            "unit_price":        {"type": ["number","null"]},
            "line_total":        {"type": ["number","null"]},
            "suggested_family":  {"type": ["string","null"]},
          },
          "required": ["description"],
        },
      },
    },
    "required": ["lines"],
  },
}


def extract_with(model, text):
    t0 = time.time()
    resp = CLIENT.messages.create(
      model=model, max_tokens=4096,
      system=SYSTEM, tools=[TOOL],
      tool_choice={"type": "tool", "name": "extract_invoice_lines"},
      messages=[{"role": "user", "content": f"INVOICE TEXT:\n{text}"}],
    )
    block = next((b for b in resp.content if getattr(b, "type", "") == "tool_use"), None)
    return {
      "lines": (block.input or {}).get("lines", []) if block else [],
      "duration_s":    round(time.time() - t0, 1),
      "input_tokens":  resp.usage.input_tokens,
      "output_tokens": resp.usage.output_tokens,
      "model":         model,
    }


def pdf_text(path):
    try:
        with pdfplumber.open(path) as pdf:
            return '\n'.join(p.extract_text() or '' for p in pdf.pages)[:15000]
    except Exception as e:
        return None


def sum_lines(lines):
    return sum((l.get("line_total") or 0) for l in lines)


async def process_one(conn, r):
    text = pdf_text(r["pdf_local_path"])
    if not text:
        print(f"  inv {r['id']}: pdf read failed")
        return None
    target = float(r["net_amount"]) if r["net_amount"] else 0.0

    result = extract_with(HAIKU, text)
    lines = result["lines"]
    summed = sum_lines(lines)
    used = "haiku"
    confidence = 0.95
    # Escalate to Sonnet if sum-validation fails
    if target > 0 and lines and abs(summed - target) / target > 0.05:
        sonnet_result = extract_with(SONNET, text)
        sonnet_sum = sum_lines(sonnet_result["lines"])
        if abs(sonnet_sum - target) < abs(summed - target):
            result = sonnet_result
            lines = result["lines"]
            summed = sonnet_sum
            used = "sonnet"
            confidence = 0.97
    if target > 0:
        delta = abs(summed - target) / target if summed else 1.0
        confidence = max(0.5, min(0.98, 1.0 - delta))

    # Idempotent insert: clear existing lines for this invoice first
    await conn.execute(
      "DELETE FROM vendor_invoice_lines WHERE invoice_id = $1", r["id"]
    )
    for i, l in enumerate(lines, 1):
        await conn.execute("""
          INSERT INTO vendor_invoice_lines
            (invoice_id, line_no, description, qty, unit, unit_price,
             line_net, suggested_family, extracted_by, extraction_confidence,
             raw_payload)
          VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11::jsonb)
        """, r["id"], i, (l.get("description") or "")[:1000],
             l.get("qty"), l.get("unit"), l.get("unit_price"),
             l.get("line_total"), l.get("suggested_family"),
             used, confidence,
             json.dumps({"schema": SCHEMA_VERSION, "model": result["model"],
                         "in_tok": result["input_tokens"],
                         "out_tok": result["output_tokens"]}))
    return {
      "invoice_id": r["id"], "lines": len(lines), "sum": summed,
      "target": target, "used": used, "confidence": confidence,
    }


async def main():
    conn = await asyncpg.connect(PG_DSN)
    if ONLY_ID:
        where = f"WHERE id = {int(ONLY_ID)}"
        limit_clause = ""
    else:
        where = ("WHERE is_statement = false "
                 "AND status NOT IN ('duplicate','ignored') "
                 "AND pdf_local_path IS NOT NULL "
                 "AND id NOT IN (SELECT DISTINCT invoice_id FROM vendor_invoice_lines)")
        limit_clause = f"LIMIT {LIMIT}"
    rows = await conn.fetch(f"""
      SELECT id, vendor_name, net_amount, pdf_local_path
        FROM vendor_invoice_inbox
       {where}
       ORDER BY received_at DESC
       {limit_clause}
    """)
    print(f"candidates: {len(rows)}")
    ok, fail, haiku_n, sonnet_n = 0, 0, 0, 0
    for i, r in enumerate(rows, 1):
        try:
            result = await process_one(conn, r)
            if result:
                ok += 1
                if result["used"] == "haiku":  haiku_n += 1
                if result["used"] == "sonnet": sonnet_n += 1
                if i <= 5 or i % 20 == 0:
                    print(f"  [{i}/{len(rows)}] inv {result['invoice_id']:3} "
                          f"{result['used']:6} {result['lines']:2} lines "
                          f"sum=£{result['sum']:7.2f} (target £{result['target']:7.2f}) "
                          f"conf={result['confidence']:.2f}")
            else:
                fail += 1
        except Exception as e:
            fail += 1
            print(f"  [{i}/{len(rows)}] inv {r['id']}: ERR {e}")
            await asyncio.sleep(2)  # backoff
    print(f"\nok={ok} fail={fail}  haiku={haiku_n} sonnet={sonnet_n}")
    await conn.close()

asyncio.run(main())
PYEOF
