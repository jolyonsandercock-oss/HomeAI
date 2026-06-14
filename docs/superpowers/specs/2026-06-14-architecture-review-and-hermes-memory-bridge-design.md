# Architecture Review + Hermes Memory & Culture Bridge — Design

**Date:** 2026-06-14
**Status:** Approved (design), pending implementation plan
**Author:** Claude Code (with Jo)

## Problem

Two related goals:

1. **Integrated deep architecture review** of the home_ai system, evaluated through
   the context-engineering lens (from the Belt Dynasties `CONTEXT_ENGINEERING_NOTES`),
   with the output wired *into* the system as durable knowledge — not a throwaway report.
2. **Transfer the build's pervasive memory and culture to Hermes** so it operates with
   full integrated knowledge of the AI project, while still building and evolving its own
   lasting memory.

## Context discovered

Hermes already has a three-surface memory system, and it already partially mirrors
Claude Code's:

| Surface | Role | State at design time |
|---|---|---|
| `~/.hermes/SOUL.md` | Always-on operating contract / culture (~2.6KB) | ~6 data-truth rules hand-copied from Claude Code post-mortems |
| `~/.hermes/memories/MEMORY.md` + `USER.md` | Flat `§`-delimited notes, Hermes auto-curates | ~8 entries, some already cross-copied |
| `~/.hermes/mnemosyne/data/mnemosyne.db` | The real engine: working/episodic/semantic split, `bge-small` embeddings, FTS, `trust_tier`, `author_type`, `scope`, `superseded_by`, consolidation | Live, sophisticated |

Key implications:
- The memory transfer is ~13% done, manually (≈6 of ~47 Claude Code memories).
- **mnemosyne's schema *is* the five-layer memory model** from the context-engineering
  notes (working / episodic / semantic, with provenance + trust columns). So "build and
  evolve its own lasting memory" is *already architecturally supported*. The real design
  problem is **coexistence**: inherited (Claude-authored) memory must layer over
  self-authored (Hermes) memory without either clobbering the other.

## Decisions (locked with Jo)

- **Transfer model:** living one-way bridge. Claude Code's memory dir stays canonical;
  synced into mnemosyne tagged `INHERITED` / `author_type='claude-code'`. Hermes keeps
  writing its own on top. Future Claude-authored memories propagate. **No reverse sync,
  no shared store** (explicit non-goals / YAGNI).
- **Transfer scope:** curated culture + infra. Include data-truth rules, financial-recon
  discipline, infra gotchas (vault / docker / RLS / n8n / counterparty), working discipline,
  AGENTS invariants. **Exclude** Claude-Code-workflow-only memories (sprint numbering,
  Ultraplan handoff, plan-mode) — Hermes can't act on them.
- **Review home:** living wiki doc + distilled pervasive-memory entries (which the bridge
  then carries to Hermes automatically).
- **Sequence:** A (review) → B (bridge). A's findings become memory entries; B's next
  sync carries them to Hermes.

---

## Sub-project A — Integrated Architecture Review

**Lens:** the Belt Dynasties context-engineering model turned inward onto home_ai's own
AI pipeline.

### Two halves

1. **Structural audit** — component boundaries, data flows, failure modes, debt across:
   Docker services; the ~7 ingest pipelines (invoice, report ingestion, gmail ingest,
   nanny, touchoffice, caterbook, weather); the RLS / realm model; the agent layer
   (Hermes, bot-responder, MCP, counterparty resolver, cognition).
2. **Context-engineering scorecard** — rate each AI component against the five context
   layers (user / session / enterprise / external / historical) plus handoff-confidence
   and cost-per-task. Surfaces *where context is lost* (e.g. invoice-extract at ~490 tokens
   with no historical context; bot-responder caching gaps; Hermes's read-only blindspots).

### Execution

Fan out parallel **read-only** Explore agents over subsystems; synthesize centrally
(conclusions only, no file dumps). The audit reuses existing artefacts where they exist
(`docs/SYSTEM-DEEP-DIVE.md`, `scripts/audit-invariants.py`, the wiki terrain pages).

### Output

- `docs/wiki/architecture-review-2026-06.md` — living, version-controlled, MCP-readable.
- Durable findings distilled into **pervasive-memory entries** in the Claude Code store
  (e.g. a context-engineering scorecard memory, top architectural-debt items). These are
  inside the bridge's transfer scope, so Hermes inherits them on the next sync.

### Success criteria

- Every AI component has a scorecard row with named gaps.
- At least the top architectural-debt items are captured as memory, not just prose.
- The wiki doc is reachable via MCP and linked from the wiki README.

---

## Sub-project B — Living Memory & Culture Bridge to Hermes

### Safety principle (the whole design rests on this)

mnemosyne separates memory by provenance. The bridge **layers, never overwrites**:

```
Hermes recall = [ INHERITED ]      ← Claude Code memory, one-way sync, author_type='claude-code'
              + [ SELF-AUTHORED ]   ← Hermes's own memory, never touched by the bridge
```

The bridge only ever reads / upserts / supersedes records **it owns**
(`author_type='claude-code'`). Hermes-authored memory is never read, edited, or deleted.

### Three transfer targets, by altitude

| Target | Gets | Rationale |
|---|---|---|
| `SOUL.md` (always-on) | ~10 highest cultural / discipline rules: verify-before-done, no-guessed-flags, break-loop-after-3, financial-recon 7 rules, audit-consumers-before-replacing | Always in context — this is "culture" |
| `mnemosyne.db` (recall-on-demand) | The ~30 curated infra / data-truth gotchas | Too many for always-on; surface on relevance |
| *(excluded)* | Claude-Code-workflow-only memories | Hermes can't act on them |

### The bridge — `scripts/hermes-memory-bridge.py` (cron)

1. Reads the Claude Code memory dir; selects the transfer set via a **tagged manifest**
   (explicit include/exclude per memory, so scope is auditable and stable across runs).
2. Upserts each selected memory into mnemosyne **through Hermes's own `remember`
   ingestion path — NOT raw SQL.** Raw `INSERT` would leave `memory_embeddings` empty and
   the record semantically unrecallable (FTS-only). This is the single biggest build risk
   and must be resolved in the plan (identify the ingestion entry point: mnemosyne tool
   call, CLI, or HTTP).
3. Keyed by the memory's `name` slug → re-runs **upsert, not duplicate**. When the source
   memory changes, the prior inherited record is marked `superseded_by` the new one.
4. **Provenance:** every written record carries `author_type='claude-code'`,
   `scope='global'`, a stable external key = the `name` slug, `source` pointing back to the
   filename, and an appropriate `trust_tier` (high enough to be trusted, not so high it
   auto-overrides Hermes's own corrections).
5. **Sentinel-aware:** memory is a watched persistence surface (`hermes-sentinel.sh`).
   Bridge writes must be expected — either re-baseline after sync or whitelist the bridge's
   write signature — so legitimate syncs don't trip drift alerts.

### Culture (distinct from facts)

`SOUL.md` already encodes the operating contract. The bridge's SOUL.md update enriches it
with the **build/working discipline** as a culture block: verify-before-done,
no-guessed-CLI-flags, break-iteration-loops-after-3, audit-consumers-before-replacing-a-producer,
the financial-recon 7 rules. This is the cultural transfer, separate from the factual
mnemosyne transfer.

### Coexistence guarantees (acceptance tests)

- After a sync, every Hermes-authored mnemosyne record is byte-identical to before.
- Re-running the bridge produces zero duplicate inherited records.
- Editing a source memory and re-syncing supersedes (not duplicates) the inherited record.
- Inherited records are semantically recallable (embedding present, `recall` returns them).
- A sync does not trigger a false sentinel drift alert.

### Success criteria

- ≥ the curated ~30 infra/data-truth memories present as inherited records, recallable.
- SOUL.md carries the working-discipline culture block.
- Bridge runs on cron, idempotent, one-way, provably non-clobbering.

---

## Non-goals (YAGNI)

- Reverse sync (Hermes → Claude Code).
- A single shared memory store with cross-agent write authority.
- Migrating Hermes off mnemosyne or changing its memory engine.

## Open questions for the plan

- Exact mnemosyne ingestion entry point that generates embeddings (tool / CLI / HTTP)?
- Sentinel reconciliation: re-baseline vs whitelist the bridge signature?
- Cron cadence (daily likely; memory changes are low-frequency).
