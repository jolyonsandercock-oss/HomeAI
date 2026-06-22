# Hermes Agent — 48GB Local Hardware Plan

Prepared: Thu 11 Jun 2026
For: Jolyon Sandercock
Revisit: Week commencing 15 Jun 2026

---

## Current Baseline

| Component | Now | Planned Upgrade |
|-----------|-----|-----------------|
| GPU | RTX 3060 12GB | **48GB** (RTX 6000 Ada / A6000) |
| System RAM | 107Gi | **256GB** (optional) |
| Primary Model | DeepSeek API (cloud) | **Qwen 2.5-72B** (fully local) |
| Invoice OCR | Cloud API round-trip | **Qwen2.5-VL-72B** (local vision) |
| PostgreSQL buffers | 128MB (default!) | **48GB** |
| Hermes memory | Mnemosyne v2 (installed) | Same — already local-first |

---

## What 48GB GPU Unlocks

### Primary Model Options

| Model | Quantisation | VRAM | Best For |
|-------|-------------|------|----------|
| **Qwen 2.5-72B-Instruct** | 4-bit GGUF (Q4_K_M) | ~40GB | ⭐ Best all-rounder |
| **Qwen2.5-VL-72B** | 4-bit GGUF | ~40GB | ⭐ Vision model for invoice OCR |
| Llama 3.3-70B | 4-bit GGUF | ~40GB | Strong reasoning |
| DeepSeek V2.5-67B | 4-bit GGUF | ~38GB | Excellent code/reasoning |

### Invoice Extraction Pipeline (Before vs After)

**Before** (cloud):
> Invoice email → Send image to OpenAI/Google → Extract text → Send to LLM → Parse → DB
> *Multiple API calls, latency, cost, data leaves network*

**After** (local):
> Invoice email → **Qwen2.5-VL-72B reads the image in one pass** → DB
> *Single local model, zero cost, zero egress, sub-second*

### VRAM Budget Breakdown

| Component | Usage |
|-----------|-------|
| Qwen 2.5-72B (4-bit) | 40 GB |
| KV cache (32K context) | 5 GB |
| nomic-embed-text | 0.3 GB |
| Surya OCR (dedicated pass) | 4 GB (swap model) |
| **Total in use** | **~45 GB / 48 GB** |

---

## What 256GB RAM Adds

### PostgreSQL — The Real Bottleneck

With 256GB RAM, PostgreSQL tuning transforms:

```sql
-- Current (defaults):      -- Planned (tuned):
shared_buffers = 128MB     →  shared_buffers = 48GB
effective_cache_size = 4GB →  effective_cache_size = 192GB
work_mem = 4MB             →  work_mem = 256MB
maintenance_work_mem = 64MB → maintenance_work_mem = 4GB
```

Your 7,957 events, 16,033 invoices, weather/tides/sales tables — **all live in RAM**. Regression queries that took seconds become sub-millisecond.

### Multi-Model Loading

With 256GB RAM + mmap, keep all of these loaded simultaneously:

| Model | Storage | Load Time |
|-------|---------|-----------|
| Qwen 2.5-72B (GGUF, mmap'd) | ~25GB on disk | Seconds |
| Qwen2.5-VL-72B (GGUF, mmap'd) | ~25GB on disk | Seconds |
| nomic-embed-text | 274MB | Instant |
| PostgreSQL (all data) | ~5GB in RAM | Always hot |

No waiting for model loads. Context switch in seconds.

### vLLM KV Cache Offloading

With flash attention + system RAM spill:
- 32K context stays in VRAM (~5GB)
- 64K context stays in VRAM (~10GB)
- 128K context spills to RAM (~20GB, still fast)
- **256K context** — possible with RAM offloading (unthinkable on 12GB card)

---

## Hermes Config Changes

Once the new hardware is in place:

```yaml
model:
  provider: openai                          # vLLM/Ollama OpenAI API
  base_url: http://homeai-ollama:11434/v1   # Local endpoint
  default: qwen2.5:72b

auxiliary:
  vision:
    provider: openai
    base_url: http://homeai-ollama:11434/v1
    model: qwen2.5-vl:72b                  # <-- Vision model for invoices
  compression:
    provider: openai
  approval:
    provider: openai

delegation:
  provider: openai
  base_url: http://homeai-ollama:11434/v1
  max_concurrent_children: 3               # 48GB handles 3 concurrent 72B
  max_spawn_depth: 2                       # Sub-subagents

memory:
  provider: mnemosyne                       # Already configured ✓
```

**Result:** Every Hermes function — reasoning, vision, compression, tool approval, delegation, session titling, curator — runs **100% local**. Zero cloud calls.

---

## What's Already Done (This Session)

- ✅ **Mnemosyne v2 plugin** installed in Hermes venv
- ✅ **11 memory tools** — semantic recall, scratchpad, fact invalidation, pattern detection
- ✅ **Skill saved** at `~/.hermes/skills/software-development/mnemosyne-memory-plugin/`
- ✅ **This plan saved** at `~/.hermes/skills/software-development/48gb-local-hardware-plan/`

---

## Buy Order Recommendation

| # | Item | Est. Cost | Impact |
|---|------|-----------|--------|
| 🥇 | **48GB GPU** (RTX 6000 Ada or A6000) | £3-5K | Single biggest leap |
| 🥈 | **256GB RAM** (6×32GB or 4×64GB) | £400-800 | Multiplier on everything |
| 🥉 | NVMe database drive (if not on one) | £100-200 | Nice-to-have |

---

## Revisit Checklist (Next Week)

- [ ] GPU installed and nvidia-smi shows 48GB
- [ ] Ollama updated: pull qwen2.5:72b-instruct-q4_K_M (or chosen GGUF)
- [ ] Ollama updated: pull qwen2.5-vl:72b
- [ ] Test inference: `docker exec homeai-ollama ollama run qwen2.5:72b "Hello"`
- [ ] Hermes config updated (see above)
- [ ] `/reset` Hermes session with new model
- [ ] Test invoice extraction: send a sample invoice
- [ ] If RAM upgraded: tune PostgreSQL shared_buffers
- [ ] Disable DeepSeek API key (stop paying)
