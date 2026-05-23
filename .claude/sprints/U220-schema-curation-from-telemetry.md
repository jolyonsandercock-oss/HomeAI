# U220 — Schema curation from cognition.schema_fires telemetry

**Prereqs**: at least 14 days of real `consumer='session'` data accumulated in `cognition.schema_fires` since the cognition build shipped 2026-05-23. Run `/schema-stats` first to confirm there's a useful sample (≥100 unique_prompts is a sensible floor).

**Realm**: owner. Cognition memory layer is OWNER-only.

**Remote vs in-person**: 100% remote. No production-state changes; only edits to `~/.claude/projects/-home-joly/schemas/` + small bot-prompt nudges.

**Why this sprint exists**: U220-partial shipped the `/schema-stats` tooling. The curation itself — pruning unfiring schemas, refining false-positive triggers, adding new schemas based on observed prompt patterns — was deliberately deferred to wait for evidence. Without this sprint, the 5 seed schemas sit there indefinitely with no proof they earn their keep. See [[project_cognition_build]] for the build context.

## Tracks

### T1 — Run /schema-stats + harvest data (~30 min)

**Build**:
- Run `/schema-stats` from a fresh Claude Code session
- Export the full data to a one-off CSV for record:
  ```
  COPY (SELECT * FROM cognition.schema_fires WHERE consumer='session') TO STDOUT WITH CSV HEADER
  ```
  → save to `.claude/decisions/2026-XX-XX-u220-schema-fires-snapshot.csv`
- Capture the 30-day picture for the audit trail

**Acceptance**:
- /schema-stats prints results (no view-missing error)
- CSV file written with ≥100 rows

---

### T2 — Prune unfiring schemas (~15 min)

**Build**:
- For each schema with `fired=0` in the 14-day window: delete `~/.claude/projects/-home-joly/schemas/<name>.md`
- Record decision in `.claude/decisions/2026-XX-XX-u220-schema-pruning.md` (one line per deletion)

**Acceptance**:
- `ls ~/.claude/projects/-home-joly/schemas/` shows only schemas that fired at least once
- `cognition.schema_fires` continues to log only currently-installed schemas (the hook ignores files that don't exist)

---

### T3 — Refine false-positive triggers (~30 min)

**Build**:
- For each schema with hit-rate suspiciously high (e.g. `bot-lookup-class` matching "what's the" on non-lookups):
  - Read 5-10 example matched prompts from `cognition.schema_fires` joined with `prompt_hash`
  - If keywords are too broad, narrow them (e.g. add a second-keyword requirement or use longer phrases)
  - Edit the schema file's `triggers.keywords` array
- One commit per schema refined, with a sample of the false-positive prompts in the message

**Acceptance**:
- After 7 more days, the refined schemas show better hit_pct distribution

---

### T4 — Add new schemas for observed high-frequency patterns (~60 min)

**Build**:
- Identify the top 10 most-common prompt shapes in `cognition.schema_fires` rows where NO schema matched (`prompt_hash`-level: prompts where every fire row is `hit=false`)
- For each repeated pattern, design a new schema in `~/.claude/projects/-home-joly/schemas/`:
  - frontmatter: `name`, `description`, `triggers.keywords`, optional `loads` references to existing memories
  - body: concise knowledge for the model to apply
- Keep schemas under 1 KB each

**Acceptance**:
- New schemas appear in `cognition.schema_fires` after the next session
- `/schema-stats` shows them firing

---

### T5 — Document final-state and next-revisit cadence (~10 min)

**Build**:
- Write `.claude/decisions/2026-XX-XX-u220-schema-curation-summary.md` capturing what was pruned, refined, added, and what the rationale was
- Update `[[project_cognition_build]]` memory entry to note this sprint's outcome

**Acceptance**:
- Decision doc exists and is committed
- Memory entry updated; MEMORY.md still valid

---

## What this sprint does NOT do

- Does not change `tighten_memory.py` or the bundle infrastructure
- Does not touch `cognition.benchmark` or the gates in `lib/gates.py`
- Does not deploy bot-side cognition (T2/T4 of the original cognition-build are still deferred — see [[project_cognition_build]])
- Does not aim for "100% hit rate" — some examined-but-no-match rows are expected and healthy

## Follow-on sprints

- **U-something** (in another 30-60 days): re-curate based on second-round telemetry. Schema effectiveness drifts as work themes shift; periodic pruning prevents bloat.
- If T2/T4 (vocabulary primer / bot router) ever become worth doing, they'd start here — but only if `/schema-stats` shows that schema-anchoring is producing measurable cognitive lift.
