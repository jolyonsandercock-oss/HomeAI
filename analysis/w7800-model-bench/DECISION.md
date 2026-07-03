# W7800 local-model benchmark + tier decision (2026-07-03/04)

Harness: model-evaluator run_benchmark_opt.py — U7 prompt pack, think=off,
num_ctx 8192, 28 scored samples (email classify / JSON validity / invoice
extract / report parse), composite = 0.65 accuracy + 0.35 speed (speed
target 60 t/s). Runs sequential on the live box, raw outputs alongside.

| model                     | email | json | invoice | reports | t/s   | composite |
|---------------------------|-------|------|---------|---------|-------|-----------|
| gemma4:26b                | 100.0 | 100  | 91.3    | 100     | 77.9  | **98.6**  |
| qwen2.5:7b  (incumbent)   | 90.0  | 100  | 85.4    | 100     | 100.2 | **96.0**  |
| qwen3.5:9b                | 85.0  | 100  | 85.4    | 100     | 80.5  | 95.2      |
| gemma4-qat31b             | 90.0  | 100  | 93.8    | 100     | 28.6  | 79.1      |
| gemma4:31b-it-q8_0        | 90.0  | 100  | 93.8    | 100     | 19.8  | 73.9      |
| qwen2.5:72b-instruct-q4_0 | 90.0  | 100  | 92.8    | 100     | 16.8  | 72.0      |
| phi4:14b                  | (500 on ollama `think` param — not scored; unused 30d anyway) |

## Decisions (model.tiers updated in static_context, live)
- **hot: qwen2.5:7b (unchanged).** gemma4:26b's +2.6 composite is under the
  +3% deploy threshold; qwen is also 1.3x faster wall-clock on the 4.8k/30d
  email volume and 1/4 the VRAM.
- **medium: gemma4:26b (was phi4:14b).** phi4 took ZERO medium calls in 30
  days and errors on think-param besides. gemma4:26b: +5.9pts invoice-field
  accuracy over hot, 100% email — verified live via /route.
- **heavy: gemma4-qat31b (was llama3.3:70b — NOT INSTALLED; tier would 404).**
  Best installed accuracy tier that coexists with the hot model in 48GB.
  Verified live via /route.
- qwen3.5:9b's 2026-06-01 rejection re-tested: the 3060 CPU-spill penalty is
  gone (80.5 t/s) but it still trails qwen2.5:7b — rejection stands on merit.
- 72B models: accuracy gains don't survive the speed weighting and 41-47GB
  evicts everything else; not worth a tier. Revisit only for a batch/offline
  quality pass.

## Follow-ups
- P2's n8n invoice.extract node still calls qwen2.5:7b directly (1,143
  calls/30d): pointing it at gemma4:26b (+5.9pts fields) is the single
  biggest real-accuracy win — n8n workflow patch, do in daylight.
- phi4:14b (9.1GB) now referenced by nothing — candidate for `ollama rm`.

## Correction + the real production win (added 2026-07-04, same session)

The "repoint P2 invoice.extract to gemma4:26b" follow-up above was based on a
misread: P2's extractor is already VISION-based (`gemma4-doc`, page image to
ollama), not qwen text. The actual production problem was far bigger: under
newer n8n's filesystem binary mode, P2's 'Build Extractor Prompt' read the
raw binary field and sent the literal storage marker 'filesystem-v2' to
ollama's images[] — Go base64 decode fails on the '-' at index 10 ("illegal
base64 data at input byte 10") — so EVERY with-attachment invoice failed at
extraction (58 errors today; the recurring dead-letter/stale-lease loop).
Fixed by u291 (getBinaryDataBuffer — binary-mode-agnostic; new workflow
version, rollback id in script output). Verified: the stuck Forest Produce
invoice processed end-to-end (webhook 200 in 17.2s), both re-driven
invoice.detected events processed by the live router within a minute,
stale leases now zero. Production email-classifier prompts checked: already
U7-grade. Remaining micro-optimisations: ollama keep_alive warm-pinning for
the three tier models; a U7-v2 prompt pass at qwen's email-classify misses.
