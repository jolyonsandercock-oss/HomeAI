# U64 — RAG first steps (Phase 5 v1)

**Prereqs**: U61 (emails FTS + line items + documents.ocr_text), U62 (calendar/tasks).

**Realm**: cross-cutting. Indexer carries realm forward from source rows; retrieval filters by `app.current_realm`.

**Remote-doable**: 100 %.

## Tracks

### T1 — V81 RAG schema + Qdrant collection
- V81 — table `rag_chunks (id, source_table, source_id, chunk_no, text, realm, entity_id, embedded_at, qdrant_point_id)`.
- New Qdrant collection `homeai-rag` — 768-dim cosine (or whatever the local embed model gives us), payload schema `{source_table, source_id, chunk_no, realm, entity_id}`.

### T2 — embedder + indexer
- Pick local embed model already installed in Ollama (nomic-embed-text or qwen3-embed if present). Fall back to `text-embedding-3-small` via OpenAI-compat shim if not. Probe Ollama for available embed models at boot.
- `/home_ai/scripts/u64-rag-index.sh` (cron `*/30`) — picks rows from:
  - `emails` where `tsv IS NOT NULL` and not yet indexed
  - `vendor_invoice_lines` (description + raw_payload notes)
  - `documents` where `ocr_text IS NOT NULL`
- Chunks at ~800 tokens with 100 overlap.
- Indexes ≤ 200 chunks per run to keep latency bounded.

### T3 — /api/research/ask + /research page
- `POST /api/research/ask` — body `{question, realm?}`. Pipeline:
  1. Embed question.
  2. Qdrant top-k=20.
  3. Re-rank by description trigram against question (cheap pseudo-rerank — no cross-encoder yet).
  4. Build context (top 8) — strip private content if realm mismatch.
  5. Sonnet 4.6 with tool-use; tool `cite_passage(source_table, source_id, quote)`. Required citations.
  6. Return narrative + cited passages.
- `/research` page — text box, answer card, citations expand to show source. Add Search-adjacent in ribbon.

## Acceptance
- After first cron pass, `rag_chunks` has > 500 rows; Qdrant `homeai-rag` has matching points.
- `curl /api/research/ask -d '{"question":"what was the wagyu burger bill from forest produce in march"}'` returns cited answer with at least one passage from `vendor_invoice_lines`.
- `/research` page renders the answer + citations expand-to-text.

## Cuts (U65)
- Cross-encoder reranking.
- Hybrid sparse+dense (BM25 + cosine + RRF).
- Live indexing on insert (vs batch).
- Image embeddings for documents.
