# R2 Decision Framework — OCR engine + local model stack

**Written 2026-07-03 (pre-results, deliberately)** so the bake-off verdict is mechanical.
Inputs: `/home_ai/analysis/r2-ocr-bench/RESULTS.md` (SET A = 100 ground-truthed invoices,
field accuracy; SET B = 80 hard-pile docs, gate-acceptance rate; engines: qwen2.5vl:7b,
gemma4-qat31b, qwen2.5vl:32b, mistral_ocr+qwen2.5:7b-text; ±learned-example variants).

## Decision 1 — bulk OCR engine (replaces qwen2.5vl:7b in u281/u285)

Primary metric: **SET B gate-acceptance** (the hard pile is the actual backlog; SET A is a
regression floor, not the target). Secondary: SET A all-fields-correct; tiebreak: latency, then cost.

- **Adopt Mistral** iff its SET B acceptance beats the best local engine by **≥15 percentage points**
  AND SET A all-fields ≥ best-local − 3pts. (Cloud dependency + PII egress must buy a step-change,
  not parity. Scope stays supplier-invoices-only; bank/mortgage documents remain local regardless.)
- **Adopt qwen2.5vl:32b (or gemma4-qat31b)** iff it beats 7b on SET B by **≥10pts** and Mistral
  doesn't clear its bar. Swap = env var `VISION_MODEL` on u281/u285 + registry note.
- **Stay on 7b** only if nothing clears those bars — then the hard pile goes to the Claude-vision
  escalation tier in bounded weekly batches instead.
- **Learned-example variant**: enable if it adds **≥5pts** on either set for its eligible subset
  with no SET A regression. (It is a ~20-line prompt-side change; cheap to keep.)

## Decision 2 — if Mistral wins OCR: the freed local vision budget

Only reached if Decision 1 = Mistral. The GPU then needs no big vision model resident:
- Delete qwen2.5vl:72b (48GB, never referenced) and qwen2.5vl:32b if it lost; KEEP qwen2.5vl:7b
  (6GB — cheap fallback when the API is down; wire the ocr registry fallback chain
  mistral_ocr → local_vision → tesseract).
- Promote the freed VRAM to text quality: A/B gemma4-doc (18GB) vs qwen2.5:72b-q4 (41GB) on
  line-extraction cross-foot rate over ~50 flagged 0-line invoices (off-peak, serial). Adopt 72b
  as the *scheduled-sweep* extractor iff it lifts cross-foot acceptance ≥8pts AND the sweep window
  stays under 2h; the hot tier (qwen2.5:7b) and gemma4-qat31b (Hermes/litellm local entry) are
  unaffected either way. Note 72b monopolises the GPU while loaded — sweeps must stay off-peak
  (03:00-06:00) with KEEP_ALIVE at default so it evicts after.

## Decision 3 — weight prune (after Decisions 1-2 settle)

Delete: qwen3.5:9b, phi4:14b, gemma4:26b, gemma4:31b, gemma4:31b-it-q8_0, hf.co GGUF dup,
qwen2.5:72b (fp16 47GB — keep only the q4_0), qwen2.5vl:72b, plus the Decision-1 losers not kept
as fallback. Expected reclaim ≈ 130-200GB. Keep: qwen2.5:7b, qwen2.5vl:7b (fallback),
gemma4-doc, gemma4-qat31b, nomic-embed-text, Decision-1/2 winners.

## Decision 4 — Haiku classify caps → local (independent of OCR)

Move `cap_dreaming` first, then `cap_email/report/child_classify` to qwen2.5:7b via the existing
LiteLLM ollama entry, ONE cap at a time, each gated by a 48h shadow comparison (log both outputs,
diff classification agreement ≥95% before cutting over). Keep Opus compliance, Sonnet
digest/cashflow/bot-responder on cloud. The invoice-ladder local tier (gemma4-qat31b before Haiku)
follows the same shadow-gate pattern.

## Standing constraints
- PII: Mistral = supplier invoices only until Jo revisits the egress posture with real usage data.
- Every adoption lands with: registry/freshness note, ai_usage logging for the new path,
  rollback = one env/config line, and a RESULTS.md link in the commit message.
- Executor (Opus or otherwise): if results are ambiguous against these thresholds (within 3pts of
  a bar), do NOT decide — present the table and stop.
