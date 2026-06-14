# Architecture Review (Phase A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a deep, context-engineering-lens review of the home_ai architecture as a living wiki doc plus distilled pervasive-memory entries that both Claude Code and Hermes will inherit.

**Architecture:** This is a research/synthesis deliverable, not unit-testable software. Tasks fan out read-only Explore agents over subsystems, synthesize a structural audit + a five-layer context-engineering scorecard, write the wiki doc, then distill the durable findings into memory files. Verification steps are concrete acceptance checks (greps, MCP fetch), not pytest.

**Tech Stack:** Markdown (wiki + memory), the Explore subagent, homeai-mcp (`:8765`), git.

**Spec:** `docs/superpowers/specs/2026-06-14-architecture-review-and-hermes-memory-bridge-design.md`

**Lens source:** `/home_ai/games/belt-dynasties/docs/CONTEXT_ENGINEERING_NOTES.md` — five context layers (user / session / enterprise / external / historical), conductor pattern, handoff-confidence, cost-per-task.

---

## File Structure

- Create: `docs/wiki/architecture-review-2026-06.md` — the review (structural audit + scorecard).
- Modify: `docs/wiki/README.md` — add a link to the new review.
- Create: `~/.claude/projects/-home-joly/memory/project_architecture_review_2026_06.md` — distilled top findings as a memory.
- Create: `~/.claude/projects/-home-joly/memory/feedback_context_engineering_scorecard.md` — the scorecard's reusable lens + the worst gaps as feedback.
- Modify: `~/.claude/projects/-home-joly/memory/MEMORY.md` — index lines for the two new memories.

---

### Task 1: Survey the AI-component surface (read-only fan-out)

**Files:** none yet — this task gathers evidence into the plan executor's notes.

- [ ] **Step 1: Dispatch parallel Explore agents (one message, concurrent)**

Dispatch four read-only Explore agents, each "medium" breadth, with these briefs. Each returns *conclusions only* (component boundaries, inputs/outputs, where state/context comes from, failure modes) — no file dumps.

1. **Ingest pipelines:** invoice-pipeline, report-ingestion, gmail-ingest, nanny, touchoffice, caterbook, weather. For each: trigger, data in, data out, where it can silently fail. Sources: `docs/wiki/*`, n8n topology, `scripts/u*`.
2. **Agent layer:** Hermes, bot-responder, homeai-mcp, counterparty-resolver, cognition. For each: what model, what context it sees, how it hands off, whether it tracks confidence/cost.
3. **Data/isolation core:** Postgres schema groups, the RLS/realm/entity model, the invariant checker. Where context (realm/entity GUCs) is set and where it's lost.
4. **Infra/ops:** Docker services + the cron fleet (joly's crontab) + Vault dependencies. What breaks what when it's down.

- [ ] **Step 2: Record findings**

Collect the four agents' conclusions into working notes. No commit yet (evidence only).

---

### Task 2: Build the context-engineering scorecard

**Files:**
- Create: `docs/wiki/architecture-review-2026-06.md`

- [ ] **Step 1: Write the scorecard table**

For every AI component found in Task 1 (Step 1, brief 2 — plus invoice-extract, report-parser), add one row scoring each five-layer context against present / partial / absent, plus handoff-confidence and cost-tracking columns. Example shape (fill with real findings, not these placeholders):

```markdown
## Context-Engineering Scorecard

| Component | User | Session | Enterprise | External | Historical | Handoff confidence | Cost tracked | Named gap |
|---|---|---|---|---|---|---|---|---|
| invoice-extract | n/a | partial | absent (no vendor priors) | n/a | absent | none | no (u163 gap) | runs ~490 tok cold, no vendor memory |
| bot-responder | partial | yes | partial | yes (MCP) | partial | n/a | partial | … |
| counterparty-resolver | n/a | yes | yes (anchors) | n/a | yes (watermark) | REVIEW flag | n/a | … |
| Hermes | yes (USER.md) | yes | partial (SOUL) | yes (SearXNG/MCP) | partial (mnemosyne) | proposal files | yes (api-tracker) | read-only blindspots |
```

- [ ] **Step 2: Verify every component has a row**

Run: `grep -c '^| ' docs/wiki/architecture-review-2026-06.md`
Expected: count ≥ number of AI components identified in Task 1. If any component is missing a row, add it.

- [ ] **Step 3: Commit**

```bash
cd /home_ai
git add docs/wiki/architecture-review-2026-06.md
git commit -m "docs(wiki): context-engineering scorecard for home_ai AI components"
```

---

### Task 3: Write the structural audit half

**Files:**
- Modify: `docs/wiki/architecture-review-2026-06.md`

- [ ] **Step 1: Add the structural audit sections**

Prepend (above the scorecard) sections covering, from Task 1 findings: System map (services + dataflow); Per-pipeline failure-mode table (trigger / silent-failure mode / current guard); RLS-realm context flow (where GUCs set, where lost); Top architectural debt (ranked, each with: what, blast radius, fix sketch). Use tables. No prose rambling.

- [ ] **Step 2: Verify the debt section is ranked and concrete**

Run: `grep -A30 'architectural debt' docs/wiki/architecture-review-2026-06.md | grep -c '^| '`
Expected: ≥5 ranked debt rows, each naming a real component (no "TBD").

- [ ] **Step 3: Commit**

```bash
cd /home_ai
git add docs/wiki/architecture-review-2026-06.md
git commit -m "docs(wiki): structural audit + ranked architectural debt"
```

---

### Task 4: Wire the review into the system (README + MCP reachability)

**Files:**
- Modify: `docs/wiki/README.md`

- [ ] **Step 1: Link the review from the wiki index**

Add a line under the wiki README's page list:
`- [Architecture Review 2026-06](architecture-review-2026-06.md) — context-engineering scorecard + structural audit + ranked debt`

- [ ] **Step 2: Verify MCP can read it**

Confirm the new doc is served by homeai-mcp (per the MCP standard, wiki pages are AI-readable). Run:
`curl -s http://127.0.0.1:8765/healthcheck >/dev/null && echo "mcp up"` then confirm the wiki doc path resolves through whatever resource lists the wiki (check `docs/slug-catalog.md` for how wiki pages are exposed; if the catalog needs a new slug entry, add it).
Expected: the review is reachable by an agent, not just on disk.

- [ ] **Step 3: Commit**

```bash
cd /home_ai
git add docs/wiki/README.md docs/slug-catalog.md
git commit -m "docs(wiki): link architecture review + expose via MCP catalog"
```

---

### Task 5: Distill durable findings into pervasive memory

**Files:**
- Create: `~/.claude/projects/-home-joly/memory/project_architecture_review_2026_06.md`
- Create: `~/.claude/projects/-home-joly/memory/feedback_context_engineering_scorecard.md`
- Modify: `~/.claude/projects/-home-joly/memory/MEMORY.md`

- [ ] **Step 1: Write the project memory (top findings)**

Create `project_architecture_review_2026_06.md` with frontmatter (`type: project`) summarising: date, the top 5 architectural-debt items with one-line fixes, link to the wiki doc. Body links related memories with `[[...]]`.

- [ ] **Step 2: Write the feedback memory (the reusable lens + worst gaps)**

Create `feedback_context_engineering_scorecard.md` (`type: feedback`) capturing the five-layer lens as a reusable evaluation tool, plus the 2-3 worst context gaps as guidance with **Why:** and **How to apply:** lines.

- [ ] **Step 3: Add MEMORY.md index lines**

Add two `- [Title](file.md) — hook` lines to `MEMORY.md`.

- [ ] **Step 4: Verify both memories are well-formed**

Run: `head -8 ~/.claude/projects/-home-joly/memory/project_architecture_review_2026_06.md` and the feedback file.
Expected: valid frontmatter (`name`, `description`, `metadata.type`) on both; both appear in MEMORY.md grep:
`grep -c architecture_review ~/.claude/projects/-home-joly/memory/MEMORY.md` → ≥1.

- [ ] **Step 5: Commit the wiki side (memory dir is outside the repo)**

The memory files live under `~/.claude/...` (not in the home_ai repo) so they are not committed here; they are picked up by the Phase B bridge automatically. Confirm no repo changes remain:
```bash
cd /home_ai && git status --short
```
Expected: clean (memory writes are out-of-tree by design).

---

## Self-Review (run before handoff)

- **Spec coverage:** structural audit (Task 3) ✓; context-engineering scorecard (Task 2) ✓; wiki doc + MCP-readable (Tasks 2-4) ✓; distilled memory entries inside bridge scope (Task 5) ✓; fan-out read-only execution (Task 1) ✓.
- **Acceptance:** every AI component has a scorecard row (Task 2 Step 2); ≥5 ranked debt rows (Task 3 Step 2); review MCP-reachable (Task 4 Step 2); two memories well-formed + indexed (Task 5 Step 4).
- **Dependency:** Phase B's bridge will carry the Task 5 memories to Hermes; no extra work here.
