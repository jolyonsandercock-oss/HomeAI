# Model Stack Update — June 1 2026

## Changes Applied to Ollama
- **Removed:** phi4:14b (9.1GB) — unused in production, superseded by qwen3.5:9b
- **Added:** qwen3.5:9b (6.6GB) — 32.4 AI Index, multimodal, native thinking mode
- **Kept:** nomic-embed-text (274MB) — embeddings

## Inference Tier Map
- **Fast/default** — qwen3.5:9b (Q4_K_M, 6.6GB). Handles: email classification, reply drafting, invoice extraction
- **Heavy** — none locally. Escalate to Claude API for complex reasoning
- **Embeddings** — nomic-embed-text

## Optimizations Applied
- OLLAMA_KV_CACHE_TYPE=q8_0 — halves KV cache memory
- OLLAMA_FLASH_ATTENTION=0 — disabled, caused regression on CUDA 13.2 driver
- OLLAMA_KEEP_ALIVE=-1 — model stays resident

## GPU Budget
- RTX 3060 12GB
- qwen3.5:9b loaded: ~5.3GB VRAM + ~2.2GB KV cache = ~7.5GB
- Headroom: ~4.5GB for context expansion (16K-32K feasible)

## Important
- qwen3.5:9b defaults to "thinking mode" — pass `enable_thinking: false` for classification tasks
- JSON schema constrained decoding: `"format":"json"` with `"temperature":0`
- No local fallback model — if qwen3.5 fails, escalate directly to Claude API
