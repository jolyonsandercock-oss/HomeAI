# 48GB GPU — Flip Checklist (corrected)

Prepared: 2026-06-11 by Claude Code. Supersedes the Hermes drop
(`48gb-hardware-plan.md`) for the Hermes-config and capacity numbers.
Run this top-to-bottom on install day.

## Corrections to the Hermes plan (verified wrong)

| Hermes claim | Reality |
|---|---|
| `max_concurrent_children: 3` — "48GB handles 3 concurrent 72B" | **No.** One 72B Q4_K_M is ~40GB weights + ~4-5GB KV at 32K context ≈ 44-45GB. Exactly **one** 72B fits. Children must use a small model or cloud flash. |
| Text 72B + VL-72B both resident | **No.** They swap — Ollama unloads one to load the other (seconds from page cache with enough RAM, but not concurrent). |
| "Invoice image → VL-72B → DB, sub-second" | A 72B VL pass on an invoice image is **tens of seconds** on this class of card. Still worth it (quality + zero egress), but batch it; don't put it on a latency-sensitive path. |
| Model tag `qwen2.5-vl:72b` | Ollama tag is **`qwen2.5vl:72b`** (no hyphen). |
| PostgreSQL `shared_buffers = 48GB` | Too aggressive even at 256GB RAM; diminishing returns past ~16-32GB and double-buffering with the OS cache. See the Postgres tuning already applied 2026-06-11 (16GB on 107GB RAM); revisit to 32GB only if RAM goes to 256GB. |

## Install-day checklist

1. **Pre-flight (before opening the case)**
   - [ ] PSU headroom: P620 PSU is 1000W; RTX 6000 Ada ≈ 300W TDP — fine. Check the card needs a CEM5/16-pin vs 8-pin adapter.
   - [ ] `nvidia-smi` driver 595.x supports Ada/Ampere workstation cards — no driver change expected. If the card needs a newer driver, remember the **GPU driver mount freeze** trap: Ollama container uses CDI (U226 pattern); restart containers after any driver change.
2. **Hardware verify**
   - [ ] `nvidia-smi --query-gpu=name,memory.total --format=csv` shows ~49140 MiB.
   - [ ] `docker exec homeai-ollama nvidia-smi` sees the card (CDI still good).
3. **Models**
   - [ ] `docker exec homeai-ollama ollama pull qwen2.5:72b-instruct-q4_K_M`
   - [ ] `docker exec homeai-ollama ollama pull qwen2.5vl:72b` (check tag exists first: `ollama search qwen2.5vl` — pull a newer-generation 70B-class model instead if one has superseded it; re-run the U7-style eval before trusting it)
   - [ ] Smoke test: `docker exec homeai-ollama ollama run qwen2.5:72b-instruct-q4_K_M "Say OK"` and watch `nvidia-smi` for VRAM fit. If it CPU-spills (remember qwen3.5:9b did on the 3060), drop context length or quant.
4. **Hermes flip** (each is one command)
   ```
   hermes config set model.default qwen2.5:72b-instruct-q4_K_M
   hermes config set model.provider openai
   hermes config set model.base_url http://127.0.0.1:11434/v1
   hermes config set model.context_length 32768
   hermes config set auxiliary.vision.model qwen2.5vl:72b
   # delegation STAYS on deepseek-v4-flash (cloud) — do not point children at
   # the local 72B; two concurrent children would force constant model swapping.
   ```
   - [ ] `hermes -z "Reply ROUTING-OK and your model name"` returns the local model.
   - [ ] Keep `fallback_providers: ["nous"]` and the deepseek keys — local box down ≠ assistant down.
5. **Pipelines (optional, after Hermes proves stable)**
   - [ ] Consider pointing llm-router T3 (digest/reconciliation) at the 72B and retiring llama3.3:70b CPU runs.
   - [ ] Invoice vision re-pass for the 7 CamScanner-watermarked Principality PDFs (known Tesseract failure) — first real VL-72B job.
6. **Keep paying nothing you don't use**
   - [ ] Watch DeepSeek spend for a week; if local handles the load, lower the DeepSeek keys' priority but don't delete them.

## RAM upgrade (if/when 256GB lands)
- Postgres: raise `shared_buffers` 16GB→32GB, `effective_cache_size` 64GB→160GB. One container restart.
- Ollama: set `OLLAMA_KEEP_ALIVE=-1` for the 72B so it stays mmap-warm.
