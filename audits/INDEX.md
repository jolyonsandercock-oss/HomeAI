# Audits index

Generated outputs from the U86 audit sprint (and successors). Files are dated
`YYYY-MM-DD-<topic>.md`; latest run wins.

## 2026-05-15 — U86 data-integrity sweep

| Track | Output | Headline |
|---|---|---|
| T1 bank-data coverage | `2026-05-15-bank-coverage.md` | 13 accounts; 2 zero-ever (15 ATR Trading Dojo settlement, 14 RBS predecessor card); 3 stale > 30d |
| T2 FK-orphan scan | `2026-05-15-fk-orphans.md` | 452 FKs checked, 0 orphans, schema clean |
| T3 idempotency-key audit | `2026-05-15-idempotency-audit.md` | UNIQUE-constraint-tagged tables all populated, no convention violations |
| T4 schema drift | `2026-05-15-schema-drift.md` | (generating — long-running scratch-DB replay) |
| T5 dead-letter triage | `2026-05-15-dead-letter-triage.md` | event-table failure buckets summarised (0 buckets — clean) |
| T6 missing-data hunter rerun | `2026-05-15-missing-data-summary.md` | 9 open ghost_shift_day (Q2 2026 days); 0 open to_scrape_gap / dojo / till |

## Action queue for follow-on sprints

- **U87 — Secure** acts on:
  - T2: orphan list is empty — no action needed, schema is clean.
  - T4: any drift detected → catch-up migration (or document each as intentional).
- **U88 — Fix and forget** acts on:
  - T5: replay-safe failure buckets get queued for retry.
  - T1: account #15 (Dojo settlement) wants the U72 onboard-48885517 CSV.
- **U90 — In-person packet** acts on:
  - T1: stale-account list (3 accounts) → Jo confirms paper statements or NatWest CSV mining.

## 2026-05-15 — U87 secure (RLS + Vault + entropy)

| Track | Output | Headline |
|---|---|---|
| T1 RLS coverage | `2026-05-15-rls-coverage.md` | 535 tables checked. 96 RLS-on-clean; 350 with entity/realm column but RLS-off (mostly partition children — inherit from parent; manual review of true holes needed) |
| T2 superuser-bypass | `2026-05-15-superuser-audit.md` | 71 `psql -U postgres` callsites: 8 ddl-needed, 10 should-be-pipeline, 37 should-be-readonly, 16 unknown |
| T3 role migration | — | DEFERRED. 47 migration candidates identified, none migrated yet. Risk of breaking crons mid-overnight — owner reviews + ships per-script |
| T4 Vault rotation calendar | `2026-05-15-vault-rotation-calendar.md` | All Vault paths tracked with age + recommended rotation cadence |
| T5 entropy pre-commit hook | (`.git/hooks/pre-commit` installed) | Blocks commit on staged content with high-entropy strings. Synthetic test confirmed working. |
| T6 sprint-number guard | (`scripts/next-sprint-number.sh`) | Returns next free U-number (currently `U91`) by scanning git + sprints/ + decisions/ |
| T7 selftest expansion | — | DEFERRED. selftest.sh untouched; standalone follow-up |

## 2026-05-15 — U88 fix-and-forget

| Track | Disposition | Outcome |
|---|---|---|
| T1 Gmail Ingest workflow | RETIRED | n8n workflow `QMKzaCFrKBS4ewWm` renamed `_archive_Gmail Ingest`. Superseded by `gmail-ingest-v1` (active) + `gmail-poll-driver-v1`. |
| T2 n8n Dreaming workflow | DISABLED | `dreaming-v1` set `active=false`. Python `scripts/u36-dreaming-nightly.sh` is canonical (cron `15 2 * * *`). |
| T3 5 Anthropic n8n nodes → tool-use | DEFERRED | Too risky overnight without per-node smoke. Tracked for U91. |
| T4 OCR watcher restoration | SKIPPED | Conflicts with U75 archival decision (moved to `_archive/` after Paperless deemed canonical). |
| T5 Dead-letter replay | NO-OP | U86 audit showed 0 buckets. Nothing to replay. |
| T6 Cron exit-code audit | DONE | `2026-05-15-cron-health.md`. 43 cron scripts mapped; new scripts logged "no log yet" (waiting for next scheduled run). |
| T7 TODO/FIXME sweep | DONE | `2026-05-15-todo-sweep.md`. 7 markers found; 6 false positives (my own search pattern), 1 in `restore.sh` is mktemp template — functionally zero real TODOs. |
