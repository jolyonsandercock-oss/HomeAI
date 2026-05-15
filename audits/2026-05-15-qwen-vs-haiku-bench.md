# Qwen 2.5:7b vs Haiku 4.5 vs Sonnet 4.6 — invoice line-item bench (rerun)

Generated 2026-05-15 22:21. Re-run of the existing `u61-line-item-bench.sh`
against the same 5-sample truth set used in U61 T0 (May 2026).

## Headline

| Model | Accuracy | Speed | Cost / 100 invoices |
|---|---|---|---|
| **Haiku 4.5** | **96.9%** (31/32 lines) | 13.8s for 5 | **~£0.50** |
| qwen 2.5:7b (local) | 78.1% (25/32) | 101.2s for 5 | £0 (CPU/GPU only) |
| Sonnet 4.6 | 100% (32/32) | 26.6s for 5 | ~£5.00 |

**Verdict: no change from U61.** Qwen sits at the same 78.1% it scored in May. Haiku
remains the right primary; Sonnet fallback for the 3.1% edge cases.

## What this rerun tested

- Same 5 invoices, same truth.json (32 hand-curated line items)
- Same Anthropic API + same local Ollama (qwen2.5:7b model unchanged since May)
- Same prompts + same tool schema

## Why Qwen didn't improve

We hoped local OCR + the Brother pipeline would change something. It didn't —
because OCR isn't the bottleneck in this bench (the truth set uses
pre-extracted PDF text, not OCR'd raster scans). The bench tests pure
**line-extraction** quality given clean text.

Where Qwen still fails:
- **Cornwall Cooling** (sample 220): 1/7 lines. Service-line layouts with
  engineer time + travel + mileage trip qwen up — it returns one aggregated
  line instead of seven. Same failure mode as May.
- **St Austell Brewery** (sample 168): 7/8 lines. Misses the EPR-discount
  line; Haiku also misses this one, only Sonnet gets it.

## Cost projection

If we standardise on Haiku for the existing 285-invoice backlog + new
arrivals (~10/week ongoing):

- One-off backlog: 285 × £0.005 = **£1.43**
- Steady-state: 10/week × 52 = 520/year × £0.005 = **~£2.60/year**
- Sonnet fallback for ~5% (validation failures): 26 invoices × £0.05 = **£1.30/year**

**Total annual spend: ~£4/year**. Compared to Qwen at 78% (i.e. 22% requires
human triage) — the human-time cost of triage dwarfs £4.

## Decision

Keep `u61-line-items-extract.sh` as-is. Haiku primary + Sonnet validation
fallback. Don't re-bench Qwen until Qwen 3 or similar comes out.

A worthwhile parallel experiment for later: Mistral OCR for *image*-based
invoice ingestion (we already shipped the adapter skeleton in U70). That's a
different bench targeting OCR quality, not LLM extraction quality.
