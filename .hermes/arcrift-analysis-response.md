# ArcRift Analysis — Response

**Date:** 2026-06-06 · Analysis only, no implementation (per the prompt).
**Method:** grounded in the *live* system, not the spec. SPEC's RAG/Qdrant is a
Phase 3–5 plan; the implementation diverged, so the questions are answered against
what actually runs.

## TL;DR verdict

| Idea | Decision | Why |
|---|---|---|
| **HyDE retrieval** | **No (defer, conditional)** | Retrieval already works (hybrid FTS+cosine, tuned). Business-data queries are mostly *factual/structured* — HyDE's hallucinated hypothetical doc risks steering retrieval toward made-up specifics. Benefit is recall on *vague* queries, which isn't a measured pain here. |
| **Async embedding queue + DLQ** | **No (already solved)** | Embedding coverage is 130,304 / 130,305. The embed script logs-and-continues **and is idempotent**, so re-runs recover failures — same end-state as a DLQ. The event pipeline *already* has a real DLQ (`dead_letter` + `recover_stale_leases` + `retry_count`). |
| **Browser chat capture** | **No (kill)** | Claude Code: 62 sessions, 161 MB, 24 active in the last 7 days. Web-chat capture table (`chat_hub_sessions`): **0 rows**. The important work is in Claude Code and already captured. Web UI is ~10% throwaway analysis. |

**Overall: ArcRift solves a different problem** (a developer's personal cross-tool
AI-coding-chat memory). Home AI is a business-automation engine whose knowledge
graph *is* the relational DB. The overlap is superficial; we already have
equivalents for every pattern. This is mostly shiny-thing-chasing — one tiny
housekeeping check falls out (below), nothing to build.

---

## Q1 — HyDE retrieval

**What we actually have.** Retrieval is **not** Qdrant. Embeddings live in a
Postgres table `search_vectors` (nomic-embed-text, `search_document:`/`search_query:`
task prefixes), queried by `build-dashboard` (`main.py:~2529`) as a **hybrid**:
tsvector FTS + cosine over `search_vectors`. I tuned this path earlier in U242 T1
(stopwords, OR-safe tokens, plainto fallback) and recall was already solid.
**Qdrant (v1.17.1) is provisioned but only referenced in a static demo page
(`playground.html`) — it is not in any production query path.**

**HyDE's fit for *our* queries.** HyDE helps when the query is vague/rephrased and
semantically distant from the stored text. Our retrieval workload is mostly:
1. **Structured business questions** ("how much did we pay St Austell in May",
   "show invoices from X") → these go to SQL/MCP or FTS and want *factual
   precision*. HyDE actively hurts here: the synthetic answer can invent figures
   that pull retrieval toward fabricated specifics.
2. **Context RAG over emails / cultural-memory dossiers** → the dossiers are
   already distilled high-signal summaries, so vector recall is good as-is.

**Cost vs benefit.** Cost = one extra local LLM call (qwen2.5:7b, ~1–2s) per query
on a **3060 that's already GPU-contended** (Jo games on it; see
`feedback_gpu_driver_mount_freeze`). Benefit = better recall on *vague* queries —
which isn't a complaint we've measured.

**Recommendation: No now; conditional experiment later.** Don't add a HyDE node.
*If* vague-query recall becomes a demonstrated pain (someone asks "what's going on
with the roof?" and gets nothing), run a bounded A/B: HyDE on the **dossier/email
RAG path only**, never the structured/financial path, behind a flag, measured on a
labelled query set. Effort if pursued: ~0.5 day (the node is genuinely ~20 lines;
the *evaluation harness* is the real work). Belongs in a future RAG-quality step,
not the current build order.

---

## Q2 — Async embedding queue + dead-letter queue

**Is there a real problem? Largely no.** Two mechanisms already cover it:

1. **Embeddings are an idempotent backfill, not an inline event step.**
   `scripts/u235-embed-email-chunks.sh` embeds chunks missing a `search_vectors`
   row. On an Ollama error it logs `[embed] ERR …` and `continue`s (counts `n_err`),
   leaving the chunk un-embedded — which means the **next run retries it**. Current
   coverage: **130,304 / 130,305 embedded** (one residual, almost certainly an empty
   chunk). So failures are *not* silently lost; the idempotent re-run is the
   recovery — functionally the same guarantee a DLQ gives.

2. **The event pipeline already has a DLQ.** Per AGENTS.md + SPEC PART 2/4: events
   that fail land in `dead_letter` with `retry_count`, and `recover_stale_leases`
   re-queues stuck `processing` rows. That *is* "retry N times then a visible dead
   letter queue." (The dashboard even surfaces `dead_letter` count via `/status`.)

**The Ollama-under-gaming-load scenario is real** but already absorbed: inline
Ollama calls (e.g. the email classifier) fail → event retries → `dead_letter` if
persistent; batch embeddings self-heal on re-run.

**The one genuine gap** isn't a missing queue — it's **whether the embed backfill is
scheduled**. Coverage being ~100% implies re-runs happen, but I couldn't confirm a
cron for it non-interactively (root crontab). If embedding is run manually, a single
transient Ollama outage stays un-recovered until someone notices.

**Recommendation: No build.** Don't add an async queue/DLQ — we have both patterns.
*Do* one 2-minute check: confirm `u235-embed-email-chunks.sh` is on root's cron
(like `u35`/`u95`); if not, add it with the standard `cd /home_ai && …` wrapper.
Optionally, fold the new API retry/cooldown protocol's sibling idea into the embed
loop (retry an Ollama 5xx a few times before `continue`) — a 5-line tweak, not a
subsystem. Belongs in pipeline-hardening housekeeping, ~15 min.

---

## Q3 — Browser chat capture

**The data answers this bluntly.**
- Claude Code (Hermes-captured transcripts): **62 sessions, 161 MB, 24 active in the
  last 7 days.** This is where Home AI is designed, debugged, and maintained.
- Web/local chat capture (`chat_hub_sessions`): **0 rows.**

Jo's durable AI work — every architectural decision, pipeline fix, schema change —
happens in Claude Code and is already captured. The web UI is SPEC Pattern 4:
"paste data into Claude.ai to *think*" — ad-hoc analysis, ~10%, and deliberately
throwaway (you paste context *out*, you don't accumulate decisions *in*).

**Recommendation: Kill.** A Chrome extension intercepting 7 web AI platforms is real
maintenance surface (extension upkeep, per-site DOM scraping that breaks on UI
changes, a PII pathway *around* `body_text_safe`) to capture the *least* durable 10%
of AI usage. The cost/benefit is upside-down. If a specific web-chat decision ever
matters, it can be pasted into a Claude Code session in 10 seconds — which routes it
through Hermes anyway. **Don't revisit unless the Claude-Code/web split inverts.**

---

## Q4 — Same problem or different?

**Different problem.** ArcRift is a *single developer's personal memory layer for
AI-coding chats* across browser tools — local-first, SQLite, no server, optimized for
"what did the AI tell me about this codebase last week." Home AI is a *multi-entity
business-automation engine*: a relational Postgres with RLS as the source of truth, a
signed event bus, n8n pipelines, and Claude Code as the maintenance cockpit. **Our
knowledge graph is the database schema itself**, not an extracted side-store.

**Transferable patterns — honest audit:**
- *Vector search / embeddings* — we have it (`search_vectors` + FTS hybrid). ArcRift
  uses sqlite-vec; we use Postgres. No transfer needed.
- *HyDE* — a real, general technique, but marginal for our factual/structured
  workload (Q1). The one *idea* worth filing, not building.
- *Async queue + DLQ* — we already have both shapes (Q2).
- *Browser capture* — wrong usage profile (Q3).

**So: mostly chasing shiny things.** ArcRift is a well-built tool for its niche;
nothing in it beats what we already run. The only non-zero takeaways are (a) HyDE as a
*deferred, conditional* experiment, and (b) the housekeeping check that the embed
backfill is scheduled — neither is an ArcRift adoption, just good hygiene.

---

## Side-finding worth noting (not in the prompt)

**Qdrant is dead weight right now.** It's running (a container + memory) but only
referenced by a demo page; real retrieval is Postgres `search_vectors`. Either wire
Qdrant in deliberately (if we expect >1–2 M vectors where pgvector/array search
strains) or drop the container to reclaim resources on the 3060 box. Decide on
purpose rather than leaving it half-provisioned — but that's a separate call from
ArcRift.
