#!/usr/bin/env bash
#
# u61-line-item-bench.sh — A/B/C bench for invoice line-item extraction.
#
# Runs qwen2.5:7b (local), Haiku 4.5, Sonnet 4.6 on the same 5 sample
# invoices. Scores each model's output against /home_ai/logs/u61-bench/
# truth.json. Writes /home_ai/logs/u61-bench-results.md.
#
# Output schema target (same across all 3 models):
#   {"lines":[{"description":"…","qty":<num>,"unit_price":<num>,
#              "line_net":<num>,"vat_rate":<num 0..1>}]}

set -euo pipefail

LOG_DIR=/home_ai/logs/u61-bench
SAMPLES=(142 152 166 168 220)

VT=$(docker inspect homeai-bot-responder --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
ANTH_KEY=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=api_key secret/anthropic)
unset VT

# Push raw texts + truth + scorer into bot-responder.
docker exec homeai-bot-responder mkdir -p /tmp/u61-bench
docker cp "$LOG_DIR/truth.json" homeai-bot-responder:/tmp/u61-bench/truth.json
for id in "${SAMPLES[@]}"; do
  docker cp "$LOG_DIR/raw-${id}.txt" homeai-bot-responder:/tmp/u61-bench/raw-${id}.txt
done

docker exec -i -e ANTHROPIC_API_KEY="$ANTH_KEY" homeai-bot-responder python /dev/stdin <<'PYEOF'
import os, json, asyncio, time, re
import httpx

DIR = "/tmp/u61-bench"
SAMPLES = [142, 152, 166, 168, 220]
ANTH_KEY = os.environ["ANTHROPIC_API_KEY"]

with open(f"{DIR}/truth.json") as f:
    TRUTH = json.load(f)

# Strip the documentation key.
TRUTH = {k: v for k, v in TRUTH.items() if not k.startswith("_")}

SYSTEM_PROMPT = (
    "You are an invoice line-item extractor for a UK pub/restaurant business. "
    "Given the raw OCR/pdfplumber text of a single invoice, extract every "
    "PURCHASED LINE ITEM. Do NOT include header rows, totals, VAT summary "
    "rows, payment-instruction text, or signature blocks. For each line "
    "return: description (clean text — keep product name + size/units), "
    "qty (numeric), unit_price (numeric, GBP, the per-unit net price), "
    "line_net (numeric, GBP, the line subtotal before VAT), and vat_rate "
    "(0.0 / 0.05 / 0.20)."
)

TOOL_SCHEMA = {
    "type": "object",
    "properties": {
        "lines": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "description": {"type": "string"},
                    "qty":         {"type": "number"},
                    "unit_price":  {"type": "number"},
                    "line_net":    {"type": "number"},
                    "vat_rate":    {"type": "number"}
                },
                "required": ["description", "qty", "line_net"]
            }
        }
    },
    "required": ["lines"]
}

async def call_anthropic(model, text):
    payload = {
        "model": model,
        "max_tokens": 2048,
        "system": SYSTEM_PROMPT,
        "tools": [{
            "name": "record_line_items",
            "description": "Record every line item extracted from the invoice.",
            "input_schema": TOOL_SCHEMA,
        }],
        "tool_choice": {"type": "tool", "name": "record_line_items"},
        "messages": [{"role": "user", "content": f"Invoice text:\n\n{text}"}],
    }
    t0 = time.time()
    async with httpx.AsyncClient(timeout=120) as c:
        r = await c.post("https://api.anthropic.com/v1/messages",
                         headers={
                             "x-api-key": ANTH_KEY,
                             "anthropic-version": "2023-06-01",
                             "content-type": "application/json",
                         },
                         json=payload)
    dt = time.time() - t0
    if r.status_code != 200:
        return None, dt, r.text[:300], None
    j = r.json()
    usage = j.get("usage", {})
    for b in j.get("content") or []:
        if b.get("type") == "tool_use":
            return b.get("input"), dt, None, usage
    return None, dt, "no tool_use block", usage

async def call_qwen(text):
    payload = {
        "model": "qwen2.5:7b",
        "stream": False,
        "format": TOOL_SCHEMA,
        "options": {"temperature": 0.05, "top_p": 0.9, "num_predict": 2048},
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content":
                "Return ONLY a JSON object matching the schema. "
                "Do not add any commentary.\n\nInvoice text:\n\n" + text},
        ],
    }
    t0 = time.time()
    async with httpx.AsyncClient(timeout=300) as c:
        r = await c.post("http://homeai-ollama:11434/api/chat", json=payload)
    dt = time.time() - t0
    if r.status_code != 200:
        return None, dt, r.text[:300]
    j = r.json()
    raw = (j.get("message") or {}).get("content", "")
    try:
        return json.loads(raw), dt, None
    except json.JSONDecodeError as e:
        # try to fish out the JSON object
        m = re.search(r"\{.*\}", raw, re.S)
        if m:
            try:
                return json.loads(m.group(0)), dt, None
            except Exception:
                pass
        return None, dt, f"json parse: {e}"

def _norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())

def score_lines(predicted, truth_lines):
    """For each truth line, find a predicted line that matches by
    description-contains substring set AND line_net within 5p. Return
    (matched, total_truth, predicted_count, total_money_correct)."""
    if not predicted or "lines" not in predicted:
        return 0, len(truth_lines), 0, 0
    pred = list(predicted["lines"])
    used = set()
    matched = 0
    money_ok = 0
    for tl in truth_lines:
        substrs = [_norm(s) for s in tl["description_contains"]]
        target_net = float(tl["line_net"])
        best_i = -1
        for i, p in enumerate(pred):
            if i in used: continue
            desc_norm = _norm(p.get("description", ""))
            if not all(s in desc_norm for s in substrs): continue
            try:
                p_net = float(p.get("line_net", 0))
            except Exception:
                p_net = 0
            if abs(p_net - target_net) <= 0.05:
                best_i = i
                break
        if best_i >= 0:
            used.add(best_i)
            matched += 1
            money_ok += 1
        else:
            # try desc-only match as a soft credit
            for i, p in enumerate(pred):
                if i in used: continue
                desc_norm = _norm(p.get("description", ""))
                if all(s in desc_norm for s in substrs):
                    used.add(i)
                    matched += 0  # description matched but money didn't
                    break
    return matched, len(truth_lines), len(pred), money_ok

async def main():
    results = []
    models = [
        ("qwen2.5:7b", "qwen"),
        ("claude-haiku-4-5-20251001", "anthropic"),
        ("claude-sonnet-4-6", "anthropic"),
    ]

    for inv_id in SAMPLES:
        with open(f"{DIR}/raw-{inv_id}.txt") as f:
            text = f.read()
        truth = TRUTH[str(inv_id)]
        print(f"\n=== invoice {inv_id} — {truth['vendor']} — {len(truth['lines'])} truth lines ===")

        for model, kind in models:
            if kind == "qwen":
                out, dt, err = await call_qwen(text)
                usage = None
            else:
                out, dt, err, usage = await call_anthropic(model, text)
            matched, total, pred_count, money_ok = score_lines(out, truth["lines"])
            print(f"  {model:35s} {dt:5.1f}s  matched={matched}/{total}  pred_total={pred_count}  err={err}")
            results.append({
                "invoice_id": inv_id,
                "vendor":     truth["vendor"],
                "model":      model,
                "duration_s": round(dt, 2),
                "matched":    matched,
                "total":      total,
                "predicted":  pred_count,
                "usage":      usage,
                "error":      err,
                "output":     out,
            })

    with open("/tmp/u61-bench/results.json", "w") as f:
        json.dump(results, f, indent=2, default=str)

    # Aggregate per-model.
    print("\n=== AGGREGATE ===")
    by_model = {}
    for r in results:
        m = r["model"]
        by_model.setdefault(m, {"matched": 0, "total": 0, "duration": 0,
                                "errors": 0, "in_tok": 0, "out_tok": 0})
        by_model[m]["matched"]  += r["matched"]
        by_model[m]["total"]    += r["total"]
        by_model[m]["duration"] += r["duration_s"]
        by_model[m]["errors"]   += 1 if r["error"] else 0
        if r["usage"]:
            by_model[m]["in_tok"]  += r["usage"].get("input_tokens", 0)
            by_model[m]["out_tok"] += r["usage"].get("output_tokens", 0)
    for m, agg in by_model.items():
        pct = (100 * agg["matched"] / agg["total"]) if agg["total"] else 0
        print(f"  {m:35s} {pct:5.1f}%  ({agg['matched']}/{agg['total']})  "
              f"{agg['duration']:5.1f}s total  errs={agg['errors']}  "
              f"tok={agg['in_tok']}/{agg['out_tok']}")

asyncio.run(main())
PYEOF

# Copy results back out.
docker cp homeai-bot-responder:/tmp/u61-bench/results.json "$LOG_DIR/results.json"
echo
echo "Results JSON: $LOG_DIR/results.json"
