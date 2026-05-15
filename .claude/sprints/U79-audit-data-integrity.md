# U79 — Audit: data integrity sweep

**Prereqs**: U78 shipped. No schema changes in this sprint.

**Realm**: cross-cutting (read-only across all four realms).

**Remote-doable**: 100% — pure SQL + filesystem reporting, no Vault/Docker/n8n changes.

**Why this sprint exists**: STATUS.md was 2 days stale at start of session, the Clover bank-settlement reconciliation hit a bank-data void mid-sprint, and `clover_batches`-ingest exposed OCR quality variance across the same scan. We need an honest map of what data is correct vs missing vs drifted before any further building. Outputs feed U80 (security tightening) and U83 (in-person packet).

**Overnight-autonomous**: yes — read-only audits, all writes go to `/home_ai/audits/`. Idempotent (re-runs overwrite the dated report).

## Tracks

### T1 — Bank-data coverage audit (~30 min)

**Build**:
- Script `scripts/u79-audit-bank-coverage.sh`. For each `bank_accounts.id`, count `bank_transactions` rows per calendar month from `MIN(transaction_date)` to today. Output as a table to `audits/2026-05-16-bank-coverage.md`.
- Flag account-months with 0 rows since the account's first-ever tx (i.e. genuine gaps, not pre-account).
- Also: each account's last imported tx — anything > 30 days stale.
- Output summary: count of (account, month) gaps; total stale accounts.

**Acceptance**:
- Audit file exists, lists at minimum: account #15 (Dojo settlement, 0 rows ever) and account #3 (ATR Trading, 81 rows over 6 years — clearly under-imported).

---

### T2 — Foreign-key orphan scan (~30 min)

**Build**:
- Script `scripts/u79-audit-fk-orphans.sh`. For every FK in `pg_constraint`, run `SELECT count(*) FROM child WHERE parent_fk IS NOT NULL AND parent_fk NOT IN (SELECT pk FROM parent)`. Skip FKs marked DEFERRABLE INITIALLY DEFERRED.
- Output: `audits/2026-05-16-fk-orphans.md` — one row per (child_table, fk_column, orphan_count).
- Where orphan_count > 0, sample 3 offending rows.

**Acceptance**:
- Report runs cleanly; lists every table-pair that has orphans. Empty report = clean schema.

---

### T3 — Idempotency-key collision + uniqueness audit (~20 min)

**Build**:
- Script `scripts/u79-audit-idempotency.sh`. Per AGENTS.md rule 7, `events.idempotency_key` has no UNIQUE constraint by design (we use `WHERE NOT EXISTS`). But other tables (`bank_transactions`, `vendor_invoice_inbox`, `clover_batches`, `dojo_transactions`) DO use UNIQUE on idempotency_key — confirm they're populated and that the convention holds.
- For `events` specifically: report keys with ≥2 rows (legitimate re-emits) split by `(event_type, count)`.
- Output: `audits/2026-05-16-idempotency-audit.md`.

**Acceptance**:
- Report distinguishes tables that enforce uniqueness vs those that rely on convention. Flags any convention violations.

---

### T4 — Schema drift detection (~45 min)

**Build**:
- Script `scripts/u79-audit-schema-drift.sh`. Apply `postgres/init-db.sql` + every migration to a scratch database; dump its schema with `pg_dump -s`. Dump the live schema. `diff` them, write the delta to `audits/2026-05-16-schema-drift.md`.
- Anything in live that isn't in migrations = drift (manual ALTER, never written to a migration). Anything in migrations that isn't live = migration didn't apply.

**Acceptance**:
- Diff file produced. If clean, file contains "no drift detected". If dirty, every drift line annotated with best-guess origin (table created via REPL? trigger added ad-hoc?).

---

### T5 — Dead-letter queue triage (~30 min)

**Build**:
- Script `scripts/u79-audit-dead-letters.sh`. Bucket `events WHERE status='dead_letter'` (or wherever the project parks them — confirm path) by `error_class` / `error_message`. For each bucket: count, oldest, newest, retry_safety classification (idempotent re-emit possible? destructive? unknown?).
- Output: `audits/2026-05-16-dead-letter-triage.md` with a retry-action queue at the bottom (which buckets U81 can safely replay).

**Acceptance**:
- Triage file groups every dead-letter by error bucket. U81's "fix and forget" sprint will act on it.

---

### T6 — Missing-data hunter rerun + summary (~15 min)

**Build**:
- Run existing `scripts/u72-*-hunters.sh` (per `git log`, U72 shipped "missing-data hunters"). Append their output to `audits/2026-05-16-missing-data-summary.md` with a one-line per hunter ("seen N, missing M, mismatch K").
- Sanity check: confirm hunters are still on cron and not silently failing.

**Acceptance**:
- Summary file exists, links back to each hunter's full output if any.

---

### T7 — Commit + index (~5 min)

**Build**:
- Stage `audits/2026-05-16-*.md` + the 6 audit scripts.
- Append a one-line entry per audit to `audits/INDEX.md` (created if missing).
- Commit message: `U79: data-integrity audit (bank coverage / FK orphans / idempotency / schema drift / dead-letters / hunters)`.

**Acceptance**:
- Single commit lands. `audits/INDEX.md` lists this sprint's outputs with timestamps.

## What this sprint does NOT do

- Does **not** repair any drift, fix orphans, or import missing bank data. Those are scoped to U80, U81, and U83 (in-person).
- Does **not** rotate secrets, change RLS, or restart containers.
- Does **not** create new tables. Read-only sprint.

## Follow-on sprints

- **U80 — Secure**: acts on T1 (gap list informs U83 in-person packet), T2 (orphans get either repaired or constraint-tightened), T4 (drift reconciled into a V97 catch-up migration if needed).
- **U81 — Fix and forget**: acts on T5 dead-letter triage.
