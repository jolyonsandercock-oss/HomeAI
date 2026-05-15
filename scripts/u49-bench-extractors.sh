#!/bin/bash
# /home_ai/scripts/u49-bench-extractors.sh
#
# A/B/C line-item extraction on 5 sample invoices.
# Models: qwen2.5:7b (local), Haiku 4.5, Sonnet 4.6.
# Output: /home_ai/logs/u49-bench-results.json + .md

set -uo pipefail

# Sample invoices spanning vendor types
SAMPLES="${1:-14,15,1,198,221}"
mkdir -p /home_ai/logs

VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e SAMPLES="$SAMPLES" \
  homeai-playwright python <<'PYEOF'
import os, json, time, asyncio, asyncpg, urllib.request, urllib.parse, pathlib
import anthropic

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN      = os.environ["PG_DSN"]
SAMPLES     = [int(x) for x in os.environ["SAMPLES"].split(",")]
PDFPLUMBER  = "http://homeai-pdfplumber:8003"
OLLAMA      = "http://homeai-ollama:11434"
LOG_DIR     = pathlib.Path("/home_ai/logs")

def vault_get(p):
    r = urllib.request.Request(f"http://vault:8200/v1/secret/data/{p}",
                                headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(r, timeout=5).read())["data"]["data"]

# JSON Schema (shared across all three models)
LINE_SCHEMA = {
  "type": "object",
  "properties": {
    "lines": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "line_no":     {"type": ["integer","null"]},
          "description": {"type": "string"},
          "qty":         {"type": ["number","null"]},
          "unit":        {"type": ["string","null"]},
          "unit_price":  {"type": ["number","null"]},
          "line_total":  {"type": ["number","null"]},
        },
        "required": ["description"],
      },
    },
  },
  "required": ["lines"],
}

PROMPT = """You are extracting line items from a supplier invoice.

For each goods line, return: description (verbatim from invoice), qty, unit
(L, kg, each, case, bottle, etc.), unit_price (£ per unit), line_total (£).

IGNORE: subtotal/VAT/total rows, delivery charges (note them separately if
relevant), discount lines, payment terms text, address blocks, bank details.

Return ONLY JSON matching the schema. Empty array if no clear line items."""

async def extract_pdfplumber_text(invoice_id, pdf_path):
    """Extract PDF text directly (the pdfplumber service truncates at 8K)."""
    import pdfplumber
    try:
        with pdfplumber.open(pdf_path) as pdf:
            text = '\n'.join(p.extract_text() or '' for p in pdf.pages)
        return text[:15000]
    except Exception as e:
        print(f"  pdf extract err: {e}")
        return None

async def run_qwen(text):
    """qwen2.5:7b with format=schema (structured outputs)."""
    import httpx
    t0 = time.time()
    payload = {
      "model": "qwen2.5:7b",
      "messages": [
        {"role": "system", "content": PROMPT},
        {"role": "user", "content": f"INVOICE TEXT:\n{text}"},
      ],
      "format": LINE_SCHEMA,
      "stream": False,
      "options": {"temperature": 0.1, "num_predict": 2048},
    }
    async with httpx.AsyncClient(timeout=120) as c:
        r = await c.post(f"{OLLAMA}/api/chat", json=payload)
    dur = round(time.time() - t0, 1)
    if r.status_code != 200:
        return {"error": r.text[:200], "duration_s": dur}
    out = r.json().get("message", {}).get("content", "")
    try:
        parsed = json.loads(out)
        return {"lines": parsed.get("lines", []), "duration_s": dur,
                "raw_len": len(out)}
    except Exception as e:
        return {"error": str(e), "raw": out[:300], "duration_s": dur}

def run_anthropic(model, text):
    client = anthropic.Anthropic(api_key=vault_get("anthropic")["api_key"])
    t0 = time.time()
    tool = {
      "name": "extract_lines",
      "description": "Extract invoice line items.",
      "input_schema": LINE_SCHEMA,
    }
    resp = client.messages.create(
      model=model, max_tokens=4096,
      system=PROMPT,
      tools=[tool],
      tool_choice={"type": "tool", "name": "extract_lines"},
      messages=[{"role": "user", "content": f"INVOICE TEXT:\n{text}"}],
    )
    dur = round(time.time() - t0, 1)
    block = next((b for b in resp.content if getattr(b, "type", "") == "tool_use"), None)
    lines = (block.input or {}).get("lines", []) if block else []
    return {
      "lines": lines,
      "duration_s": dur,
      "input_tokens":  resp.usage.input_tokens,
      "output_tokens": resp.usage.output_tokens,
    }

async def main():
    conn = await asyncpg.connect(PG_DSN)
    rows = await conn.fetch(
      f"SELECT id, vendor_name, net_amount, pdf_local_path "
      f"FROM vendor_invoice_inbox WHERE id = ANY($1::int[])",
      SAMPLES,
    )
    all_results = []
    for r in rows:
        invoice_id = r["id"]
        print(f"\n=== invoice {invoice_id} ({r['vendor_name'][:40]}, £{r['net_amount']}) ===")
        text = await extract_pdfplumber_text(invoice_id, r["pdf_local_path"])
        if not text:
            print(f"  pdfplumber failed")
            continue
        print(f"  pdf text length: {len(text)} chars")

        results = {"invoice_id": invoice_id,
                   "vendor": r["vendor_name"],
                   "net_amount": float(r["net_amount"]),
                   "text_chars": len(text),
                   "models": {}}

        # qwen
        print("  qwen2.5:7b ...", end=" ", flush=True)
        qwen = await run_qwen(text)
        results["models"]["qwen"] = qwen
        print(f"{qwen.get('duration_s')}s  lines={len(qwen.get('lines', []))}"
              + (f"  ERR:{qwen.get('error','')[:60]}" if qwen.get('error') else ""))

        # Haiku
        print("  haiku-4-5  ...", end=" ", flush=True)
        haiku = run_anthropic("claude-haiku-4-5-20251001", text)
        results["models"]["haiku"] = haiku
        print(f"{haiku['duration_s']}s  lines={len(haiku.get('lines', []))}  "
              f"in={haiku['input_tokens']} out={haiku['output_tokens']}")

        # Sonnet
        print("  sonnet-4-6 ...", end=" ", flush=True)
        sonnet = run_anthropic("claude-sonnet-4-6", text)
        results["models"]["sonnet"] = sonnet
        print(f"{sonnet['duration_s']}s  lines={len(sonnet.get('lines', []))}  "
              f"in={sonnet['input_tokens']} out={sonnet['output_tokens']}")

        all_results.append(results)

    LOG_DIR.mkdir(exist_ok=True)
    (LOG_DIR / "u49-bench-results.json").write_text(json.dumps(all_results, indent=2, default=str))
    print(f"\nresults → {LOG_DIR/'u49-bench-results.json'}")
    await conn.close()

asyncio.run(main())
PYEOF
