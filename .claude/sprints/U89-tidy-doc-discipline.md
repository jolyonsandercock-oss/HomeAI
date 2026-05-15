# U89 — Tidy: auto-doc, untracked sweep, process discipline

**Prereqs**: U86 (audits/INDEX exists) + U87 (entropy hook installed). U88 cleanup not strictly required but useful.

**Realm**: cross-cutting (documentation maps the whole system).

**Remote-doable**: 100% — pure file generation + cleanup. No live-service changes.

**Why this sprint exists**: STATUS.md drifted 2 days ago and no automation caught it; AGENTS.md references paths that may no longer exist (the u73-ocr-* files vanished, the cron table in `project_homeai.md` was stale by U78); orphaned scripts pile up over time. Documentation that doesn't regenerate itself goes stale, full stop.

**Overnight-autonomous**: yes — every track generates files or removes dead ones; nothing modifies live services.

## Tracks

### T1 — Schema doc generator (~45 min)

**Build**:
- Script `scripts/u82-gen-schema-doc.sh`. Query `pg_tables`, `pg_views`, `pg_constraint`, `pg_policies` → emit `docs/schema.md` with one section per table:
  - Columns + types + nullability
  - Indexes + their definitions
  - RLS state + policies (named, with predicate snippet)
  - FK references (in + out)
  - Approximate row count from `pg_class.reltuples`
- Sort sections alphabetically; toc at top.
- Idempotent (overwrites).

**Acceptance**:
- `docs/schema.md` produced, >1 row per table, includes `clover_batches` and `account_property_map` (from U78).

---

### T2 — View dependency graph (~30 min)

**Build**:
- Script `scripts/u82-gen-view-deps.sh`. For every view, parse `pg_depend` to find what tables/views it reads. Emit `docs/views.md` with definitions + dependency tree.
- Bonus: a mermaid graph block at the top showing `v_card_reconciliation` → `v_dojo_daily` + `touchoffice_fixed_totals`; same for `v_clover_daily` → `clover_batches`.

**Acceptance**:
- `docs/views.md` exists, includes mermaid block that renders on GitHub.

---

### T3 — Cron doc generator (~30 min)

**Build**:
- Script `scripts/u82-gen-cron-doc.sh`. Read `crontab -l`. For each entry, extract the script path and pull its leading docstring/comment. Emit `docs/cron.md` as a table: schedule | script | purpose (from docstring) | last-runs-status (from U88 T6).
- Flag scripts on cron that don't exist on disk (orphan entries) and scripts on disk that match `u\d+-` but aren't on cron (orphan scripts — surface to T6).

**Acceptance**:
- `docs/cron.md` exists. All current cron entries listed. Orphans flagged.

---

### T4 — Migration index regen (~15 min)

**Build**:
- Script `scripts/u82-gen-migration-index.sh`. `ls postgres/migrations/V*.sql | sort -V`, for each extract the leading `-- comment` (first 5 lines after `BEGIN;`). Emit `docs/migrations.md`: V## | filename | one-line summary | sprint reference (from `git log` mention).
- Includes V58..V96 which were absent from project_homeai.md before this sprint.

**Acceptance**:
- `docs/migrations.md` lists all 96 migrations with summaries.

---

### T5 — STATUS.md regeneration (~30 min)

**Build**:
- Script `scripts/u82-regen-status.sh`. Generates STATUS.md from:
  - `project_homeai.md` "Current build state" lines
  - `git log --oneline` since last STATUS regen
  - `audits/INDEX.md` recent entries
  - Open items from `bot_instructions WHERE status='pending'`
- Adds a top-of-file `_generated: <date>` line so future drift is visible at a glance.
- Add invocation to the `/retro` skill (so STATUS.md regen is automatic at session end).

**Acceptance**:
- STATUS.md regenerated; matches reality at end of U89.

---

### T6 — Untracked + orphan file cleanup (~45 min)

**Build**:
- Script `scripts/u82-audit-untracked.sh`. Compare `find /home_ai -type f` (filtering out volumes, logs, caches, archives) against `git ls-files`. For each untracked:
  - Match `u\d+-*` script → recent (this month) → likely intentional, suggest `git add`
  - Match `_archive/` → skip
  - Match `*.log`, `*.pid`, `*.swp` → ensure `.gitignore` covers
  - Match anything else → list for human review
- Output: `audits/2026-05-16-untracked-files.md`. Apply uncontroversial gitignore additions immediately.

**Acceptance**:
- Audit produced. Working tree's "untracked but should-be-tracked" list ≤ 5 items.

---

### T7 — Memory & decisions hygiene (~30 min)

**Build**:
- Script `scripts/u82-audit-memory.sh`. Read `memory/MEMORY.md` index; ensure every `[link](file.md)` resolves. For each `feedback_*.md` / `project_*.md` file in the memory dir, ensure it's listed in MEMORY.md. Resolve `[[wiki-link]]` references — flag dangling.
- Same for `.claude/decisions/`: verify each dated decision file has a matching git commit in its window.
- Output: `audits/2026-05-16-memory-hygiene.md`.

**Acceptance**:
- Audit produced. No dangling `[[links]]` after fix-up.

---

### T8 — AGENTS.md vs reality check (~20 min)

**Build**:
- Script `scripts/u82-audit-agents-md.sh`. Extract every path / command / table-name / script-name from AGENTS.md. Verify each: path exists, table exists, script is executable.
- Output: `audits/2026-05-16-agents-md-drift.md`. Apply trivial fixes (rename if file moved); flag substantive drift for human review.

**Acceptance**:
- Audit produced. AGENTS.md works as a fresh-session onboarding doc again.

---

### T9 — Commit (~5 min)

**Build**:
- Single commit `U89: tidy — auto-doc generation + untracked sweep + STATUS regen`.
- Update `audits/INDEX.md`.

**Acceptance**:
- Working tree clean. `docs/` populated. STATUS.md timestamp matches today.

## What this sprint does NOT do

- Does **not** ship any new application functionality (per the no-new-functionality directive).
- Does **not** delete any sprint plan or decision file — only orphan binary/log files.
- Does **not** rewrite SPEC.md (its content is architectural, not generated).

## Follow-on sprints

- **U90 — In-person packet**: uses T1–T4 doc outputs to populate the human-readable checklist.
- Nightly doc regen becomes a cron job once U89's generators are proven.
