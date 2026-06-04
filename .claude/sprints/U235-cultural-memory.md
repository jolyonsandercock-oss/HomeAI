# U235 — Cultural Memory (Email RAG + Distilled Institutional Memory)

Status: PLANNED · Created 2026-06-04 · Owner: Jo · Drafted by: Claude (after Gemini design review)

## Goal

Turn the 74,636-email backfill into (1) a retrieval-augmented Q&A capability and,
ultimately, (2) a distilled, browsable **cultural memory** — entities, recurring
themes, decisions, relationships — surfaced in the dashboard. RAG is the
infrastructure; the distilled memory is the destination.

## Verified current state (2026-06-04)

| Fact | Evidence | Implication |
|---|---|---|
| 74,636 emails ingested | `emails` table | info 37,361 / admin 20,228 (work); jo 11,008 / pounana 5,938 (personal); bot 101 (owner) |
| Sanitiser **exists** | `services/google-fetch/main.py:384` `_sanitise()` | Backfill, don't build. HTML-strip + regex-redact + WS-collapse, **truncates to 2000 chars** |
| `body_text_safe` only ~3% populated | 2,466 / 74,636 | Historical emails predate the sanitiser → Stage 0 backfill |
| Embedding worker **exists & is realm-aware** | `scripts/u65-build-research-embeddings.sh`; `search_vectors` has 1,178 rows | `nomic-embed-text` (768-dim). Already embeds emails across work/personal/owner. Stage 1 = scale it |
| Vector store = `search_vectors` (`embedding real[]`) | `\d search_vectors` | No `vector` ext in image (`pg_available_extensions` = 0) → stay on `real[]` for now |
| **No cosine function for `real[]`** | `pg_proc` has only pg_trgm lexical sim | Rerank needs a small SQL cosine fn — build item |
| **`search_vectors` has NO RLS** | `relrowsecurity = f`, 0 policies | `realm` col is advisory only → SECURITY GAP, must add policy |
| Lexical retrieval ready | `emails.tsv` + `pg_trgm` GIN indexes | Hybrid lexical-first is viable today |

## Locked decisions

- **D1 — Vector strategy: Hybrid lexical-first.** `tsv`/`pg_trgm` pulls the top ~300
  candidates; a `real[]` cosine fn reranks only that subset. No pgvector image
  migration now; revisit HNSW only when scale demands it. **(Decoupled from Stage 0 —
  sanitisation backfill proceeds regardless of this.)**
- **D2 — Privacy: owner-unified memory, work surfaces stay segregated.** (Updated 2026-06-04:
  Jo is the sole, owner-level consumer.) The cultural memory **spans all realms** (work +
  personal + owner) for the owner session — Jo *wants* work and personal blended for his own
  queries. Defence-in-depth still required so the segregation holds for non-owner surfaces:
  1. Add **RLS policy on `search_vectors`** + `email_rag_chunks` (realm_isolation, mirroring `emails`).
  2. Retrieval worker **explicitly** appends `WHERE realm = ...` from session context (never relies on RLS alone — see U147 Bug A realm-evaporation trap).
  3. The cultural-memory query path runs **owner-realm** (spans all). The **work-realm** surfaces
     (team dashboard, read-only MCP) must NOT be able to read personal rows — RLS enforces this.
- **D3 — Injection defence is architectural, not regex.** `body_text_safe` is hygiene
  (HTML/tracker strip), NOT an injection firewall. Real guards: (a) realm-scoped
  retrieval at SQL layer, (b) synthesis LLM has **no tools / no exfil capability**,
  (c) retrieved content delimited as untrusted data in the prompt.
- **D4 — Build plain RAG-QA first as infra; distilled memory is the real deliverable.**

## Decisions resolved 2026-06-04 (Jo)

- **O1 → Full-body sanitise-then-chunk.** Sanitise the *entire* body (no 2000-char
  truncation) via new `home_ai.sanitise_full()`, then chunk (2000-char window, 1800 step
  → ~200 overlap) into `email_rag_chunks`. The existing 2000-char `_sanitise()` is left
  untouched (other consumers depend on its semantics).
- **O2 → Structured extraction store first** (entities + decisions + relationships), not a
  full knowledge graph. (Claude default; Jo did not object.)
- **O3 → Cultural memory for ALL realms.** Jo is the sole owner-level consumer — see D2.

## Staged plan

**Stage 0 — Sanitisation backfill. ✅ DONE 2026-06-04 (migration V225).**
- `home_ai.sanitise_full()` (no truncation; strips style/script/comment blocks + tags +
  injection phrases). New `email_rag_chunks` table (2000-char window / 1800 step), RLS
  realm_isolation + base_access (verified: work cannot read personal/owner).
- Result: **130,305 chunks across 69,967 emails** (remaining ~4,669 = empty/markup-only bodies).
  Realm carried: work 82,997 / personal 47,197 / owner 111.

**Stage 1 — Embeddings at scale.**
- Extend `u65` worker to chunk safe text (~512 tokens) and embed all emails via
  `nomic-embed-text` into `search_vectors` (idempotent on source_kind+source_id+model,
  realm carried from the email).
- Acceptance: every email has ≥1 embedding row; realm matches source.

**Stage 2 — Hybrid retrieval + security.**
- Add RLS policy on `search_vectors` (D2.1). Add `real[]` cosine SQL fn (D1).
- Retrieval = lexical candidate set (tsv/pg_trgm) → cosine rerank → top-k, realm-gated
  in SQL (D2.2). Expose as a whitelisted slug or `/api/rag/query`.
- Acceptance: a work-session query provably cannot return personal rows (test it).

**Stage 3 — Synthesis (RAG-QA).**
- Claude Sonnet over retrieved **safe** chunks, JSON-schema-constrained, OutcomeObject
  pattern, citations back to `email.id` (clickable to the /personal/emails page). No tools.
- Acceptance: answers cite sources; injection probe email cannot alter behaviour.

**Stage 4 — Distilled cultural memory (the destination).**
- Scheduled extraction worker (dreaming-style) → entities, recurring disputes, decisions,
  relationships into a structured store (+ narrative). Resolve O2/O3 first.

**Stage 5 — UI.**
- "Ask" box + browsable cultural-memory page (same pattern as the emails browser).

## Non-negotiables (AGENTS.md)

- Rule 4: only `body_text_safe`/RAG-safe text reaches any model prompt.
- Rule 3: `SET LOCAL app.current_entity` before any write.
- Constrained generation (JSON Schema), OutcomeObject output, sign event payloads.
- Pre-push entropy scan before any commit touching this work.

## First action

Stage 0 backfill is safe and needed regardless of every open decision. Recommend
starting there once O1 is picked.
