# U88 — Fix and forget: clear the known-broken pile

**Prereqs**: U86 dead-letter triage available at `audits/2026-05-16-dead-letter-triage.md`.

**Realm**: `work` primarily (n8n workflows + cron jobs in entity 1 territory).

**Remote-doable**: ~80%. n8n workflow patches need the UI for credential reattachment (~30 min hands-on per node); rest is autonomous.

**Why this sprint exists**: every item below has been "known but unfixed" for at least two weeks (some longer). Background noise that erodes trust in the system. Each gets either resolved or formally retired in this sprint.

**Overnight-autonomous**: ~80% (5 of 7 tracks). T3 (U38.5 n8n nodes) stops at "ready for UI tap"; T4 (OCR watcher restoration) is fully scriptable.

## Tracks

### T1 — Gmail Ingest workflow `QMKzaCFrKBS4ewWm` (~30 min)

**Build**:
- Investigate why it's been inactive (selftest pre-existing fail). Check `workflow_history` for last successful execution + error trail.
- Three possible outcomes, pick one:
  1. **Reactivate** — fix the cause, restart, confirm new events flow.
  2. **Replace** — if superseded by `google-fetch` sidecar (likely), formally delete from n8n and remove from selftest as "covered by google-fetch".
  3. **Retire** — rename to `_archive_…` in workflow_entity, mark inactive permanently, document in `feedback_gmail_ingest_retired.md`.
- Document the decision in `decisions/2026-05-16-gmail-ingest-disposition.md`.

**Acceptance**:
- Selftest no longer treats it as a pre-existing fail (either it passes, or it's no longer named).

---

### T2 — n8n Dreaming workflow erroring at 02:00 (~20 min)

**Build**:
- Per project memory, the Python implementation runs at 02:15 and is canonical. The n8n version is the broken one.
- Disable the n8n Dreaming workflow (`UPDATE workflow_entity SET active=false WHERE name LIKE '%Dreaming%'`) AND remove its trigger row to stop the 02:00 alert noise.
- Verify the Python `scripts/u36-dreaming-nightly.sh` is still on cron + still running clean.

**Acceptance**:
- No more 02:00 error in `n8n_execution_data`. Python version still firing.

---

### T3 — U38.5: migrate 5 remaining Anthropic n8n nodes to tool-use (~3 hr)

**Build**:
- Nodes: Gmail Haiku Classifier, Invoice P2 Haiku, Nanny P8 Haiku, Report P9 Sonnet, Dreaming n8n. Each per `decisions/u38-tool-use-migration.md` (if it exists) or the U38 sprint plan.
- For each: swap to `format=tool` + `input_schema` (schemas already in `/home_ai/ai_schemas/`). Update sibling nodes consuming `.message.content` → `.content[0].input.X`.
- One at a time, smoke-test after each. Patch the active `workflow_history.versionId` row directly (per AGENTS.md rule 8), NOT just `workflow_entity.nodes`.
- Stops at "ready" for any node whose credential needs a fresh attach via UI.

**Acceptance**:
- Each migrated node produces a structured output matching its schema on at least one real input. Per-node smoke test logged.

---

### T4 — OCR watcher restoration (~30 min)

**Build**:
- This session wrote `scripts/u73-ocr-watcher.{sh,service}` + `scripts/u73-install-ocr.sh` — they vanished from the working tree (likely a manual reset). Restore from this conversation's git history if possible; otherwise recreate from `decisions/2026-05-15-u78-clover-batches-and-account-map.md`'s description.
- Install: `sudo bash scripts/u73-install-ocr.sh` (deferred to U90 for the sudo step; this track just lays down the files).

**Acceptance**:
- Three files exist on disk, are syntactically valid, pass `shellcheck`. Install step queued for U90.

---

### T5 — Replay safe dead letters (~45 min)

**Build**:
- Read U86 T5's `dead-letter-triage.md`. For every bucket flagged `retry_safety=idempotent`, replay the event payload via the appropriate pipeline (each pipeline already idempotency-keyed).
- Log every replay to `audits/2026-05-16-dead-letter-replay.log` with before/after status.
- Do NOT replay buckets flagged `destructive` or `unknown` — leave for human review.

**Acceptance**:
- Dead-letter count drops. Replay log records each attempt.

---

### T6 — Cron exit-code audit + repair (~45 min)

**Build**:
- Script `scripts/u81-audit-cron.sh`. For every script invoked from `crontab -l`, find its log file under `/home_ai/logs/` and report exit-codes from the last 7 runs.
- For each failing cron: classify (transient / config / dead-code) and either fix in-place or remove from cron with a note in `audits/2026-05-16-cron-health.md`.
- Add log-rotation for any cron log that's > 50 MB.

**Acceptance**:
- Every cron job either passes consistently or is removed from cron. `cron_health.md` lists the disposition.

---

### T7 — FIXME/TODO sweep (~30 min)

**Build**:
- `grep -rn 'TODO\|FIXME\|XXX\|HACK' services/ scripts/`. For each: read context, classify "still relevant" vs "stale comment vs already done". Delete stale comments; convert relevant ones into `bot_instructions` rows so they surface at session start.
- Output: `audits/2026-05-16-todo-sweep.md` with counts.

**Acceptance**:
- All sweep items resolved (deleted or queued). No "still relevant" comments remain in code without a tracking row.

---

### T8 — Commit (~5 min)

**Build**:
- One commit per fixed item is allowed (small commits are fine for this sprint). Reference the U88 sprint in each.

**Acceptance**:
- Working tree clean. Each fix is its own commit OR one rollup commit `U88: fix-and-forget …`.

## What this sprint does NOT do

- Does **not** add any new functionality. Strictly fixes/removes.
- Does **not** redesign the dreaming pipeline; just disables the broken n8n version.
- Does **not** install the OCR watcher service (sudo deferred to U90).
- Does **not** replay destructive-bucket dead letters.

## Follow-on sprints

- **U89 — Tidy**: doc-gen will surface anything U88 missed.
- **U90 — In-person packet**: ships the OCR watcher install (sudo).
