# Two AI agents, one system: how to get "4 eyes" without contradictions
### Architecture brief for GPT-5.5 cross-review · 2026-06-21

---

## 0. What we need from you

We run a self-hosted "home AI" admin engine for a small UK hospitality/property business. **Two AI
agents operate on it:** *Claude Code* (deep, verifying, implements) and *Hermes* (a DeepSeek-based
daily-driver agent — fast, broad, conversational). The owner wants the value of two independent
perspectives ("4 eyes") but is tired of them **making contradictory suggestions** that the human has
to manually arbitrate. We've diagnosed the root cause and drafted a fix. **Please pressure-test the
diagnosis and the design (§3–§6), and answer the questions in §7.**

---

## 1. The problem, with real evidence

Over one working session, the two agents repeatedly contradicted each other. Every case had the *same
shape* — a confident claim from one agent, falsified by a 30-second query against the live system:

| Claim | Live reality (measured) | Failure mode (§3) |
|---|---|---|
| "The n8n event path is largely **DEAD**" | Master Router runs **2,880×/day** — busiest component | 1 · compaction-stale |
| Invoice backfill "**11,506** remaining, 3-day ETA" | **653** extractable; **43** that matter | 2 · unfiltered count |
| "**60–80%** of dead-letters are malformed JSON" | **0** malformed-AI; **55/57** phantom | 2 · unverified premise |
| "u95 harvester is **broken**" | Runs fine; capture current | 1/2 · stale + unchecked |
| "Parallel models → **2–3×**" | One GPU; ~1.2–1.5× realistic | 3 · honest estimate (untagged) |
| "**Zero** observability" | 4 freshness watchdogs already running | 1 · stale |

None of these are stupidity — they're the predictable output of *reasoning from un-measured inputs*. The
verifier (Claude) caught the scout (Hermes) — but **only because a human manually relayed between them.**
The whole point of the fix is to automate that relay.

---

## 2. The reframe

We do **not** want the two agents to always agree — collapsing them into one brain throws away the
value of independent perspectives. **We want them to disagree *productively*:** one generates, one
verifies, both standing on the *same facts*. The bug isn't divergence. The bug is that they
**generate and verify from different, drifting facts.**

---

## 3. Root-cause diagnosis: THREE distinct failure modes (refined with Hermes' input)

Claude's first cut blamed "staleness" for everything. Hermes correctly pushed back: the contradictions
are **three different failures with three different fixes** — conflating them would lead to building the
wrong thing.

1. **Compaction-stale memory.** *("n8n is dead.")* The agent inherited a stale fact from an **old
   session's context-compaction**, not from reading a doc. → Fixed by **Pillar 1 (live-state)**: never
   trust compacted memory for a fact you can measure.
2. **Discipline / counting failures.** *(`11,506` was a live `count(*)` run **without** `WHERE
   extractable`; the 12-chunk overbuild never verified its own count.)* These are **not** staleness — the
   agent had the data and a rule for it ("never trust a raw count — filter first") and didn't apply it.
   → Fixed by **Pillar 2 (enforced verification)**, **not** a shared log. A shared log can't fix a
   discipline lapse; only enforcement can.
3. **Honest estimates.** *(2–3× from parallel models; 360/day throughput.)* Reasoned guesses from specs
   — legitimate, sometimes right, sometimes wrong. → Fixed by **Pillar 2 (`[unverified]` tagging)**: the
   estimate is fine *as long as it's flagged as one.*

**Implication:** Pillar 1 (live facts) and Pillar 3 (shared log) handle modes 1 and the propagation
problem; but **Pillar 2 (enforcement) is more load-bearing than Claude first weighted it** — because
modes 2 and 3 are *behavioural*, and shared facts alone don't fix behaviour. Both agents agree the
substrate is necessary; the open question (§7) is how to make verification *enforceable*, not optional.

---

## 4. The proposed fix: shared facts + a role protocol (mostly wiring existing parts)

**Pillar 1 — One live, *generated* ground truth (retire the prose doc as a source).**
A machine-generated **STATE snapshot** built from the actual system on a schedule — n8n run-counts,
pipeline freshness, data-coverage %, backlog counts, GPU state, cron inventory — exposed through the
existing **`homeai-mcp`** server (already the canonical AI surface). **Both agents query live state;
neither reasons from memory.** This alone kills the entire "dead / broken / 11,506 / zero-observability"
class — because facts become *measured, not remembered*.

**Pillar 2 — A verification contract.** A convention both agents follow: every quantitative or
"X is broken/done" claim must be **either cited to a live query or tagged `[unverified]`.** Then
11,506 / 2–3× / 60–80% wear the tag and the human (or the other agent) knows to discount them.

**Pillar 3 — A shared, *bidirectional* decision/finding log (the "unified memory").** One append-only
store (a DB table + an MCP resource) both agents **read and write in real time.** Claude fixes the
skip-bug → it lands there → Hermes sees it *before* proposing work that re-triggers it. A one-way,
lagged Claude→Hermes memory bridge exists today; make it **two-way and live**, or replace it with this.

**Pillar 4 — A work-claims lock.** Both agents touch the same crontab / bank / extractor files. A tiny
shared `work_claims` table (agent, resource, intent, timestamp) checked before acting prevents
collisions (a duplicate backfill and several file-edit near-misses happened this session).

**Role protocol that turns divergence into a loop:**
- **Hermes** = *scout/proposer* (fast, broad, cheap). Generates ideas; claims tagged `[unverified]`.
- **Claude** = *verifier/implementer*. Checks against live state, builds, commits.
- A claim is *fact* only once verified + logged; a proposal is *done* only once implemented + logged.

This is exactly what worked this session — Claude verifying Hermes' scouting. Pillars 1 + 3 **automate
the human relay** that currently makes it work.

---

## 5. What already exists to wire (this is integration, not green-field)
- `homeai-mcp` (:8765) — the canonical external AI surface; both agents already reach it. *Add a
  live-state resource.*
- `ops.pipeline_runs` + `ops.pipeline_registry` + freshness watchdogs — the live-state feed exists;
  *aggregate it into the snapshot.*
- `cognition` schema (proposals, benchmark) — a natural home for the shared decision log.
- The Claude→Hermes memory bridge (mnemosyne sync) — *make it bidirectional.*
- `bot_instructions` table — already a shared queue, but **one-way** (human→agents) per Hermes; the
  decision log generalises it to agent↔agent read/write.
- `scripts/audit-invariants.py` — shared guardrails already enforced pre-push (a model for *enforced*,
  not aspirational, verification — Pillar 2).

> **Provenance:** §3's three-failure-mode refinement and the `bot_instructions` note are Hermes' (the
> brief is now a two-agent synthesis — itself a small proof the loop works when facts are shared).

---

## 6. Smallest first step (what we'll build first)
Two things would have prevented **every** contradiction in §1:
1. **A live-state MCP resource** (generated, never stale).
2. **A shared bidirectional decision/finding log** both read+write.

We plan to build those two next.

---

## 7. Questions for you (GPT-5.5)

1. **Is the diagnosis right** — that the contradictions are an *information-substrate* problem
   (stale/asymmetric facts), not a model-quality problem? What are we missing?
2. **Live-state surface:** is a generated snapshot behind MCP the right primitive, or would you push
   state *to* each agent (event-driven) vs. have them *pull* it? Trade-offs for a two-agent system?
3. **The verification contract** (`[unverified]` tagging) is a soft convention — agents can ignore it.
   How would you make "claims must be verified" *enforceable* rather than aspirational?
4. **Role split** (Hermes=scout, Claude=verifier): is a fixed generator/verifier split right, or
   should the roles be dynamic per-task? Does a fixed split waste the "4 eyes" on tasks where both
   should generate?
5. **Conflict resolution:** when the two agents still disagree *after* sharing facts (a genuine
   judgment call, not a stale fact), what's the arbitration mechanism — human, a third "judge" pass,
   confidence-weighted, or something else?
6. **Failure mode to watch:** what's the risk that a *shared* memory/state layer creates a *single
   point of correlated error* (both agents wrong the same way because the shared snapshot is wrong) —
   and how would you guard against it without re-introducing divergence?

---

*Grounded in a real working session, 2026-06-21. Every claim in §1 was measured against the live
system. The irony is the point: the brief is itself an artefact of one agent verifying another.*
