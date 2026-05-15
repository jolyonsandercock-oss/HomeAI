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

## 2026-05-15 — U89 tidy (auto-doc + untracked sweep + STATUS regen)

| Track | Output | Result |
|---|---|---|
| T1 schema doc | `docs/schema.md` | 315 tables documented (7537 lines, partition children omitted) |
| T2 view dep graph | — | DEFERRED (mermaid graph generation complex; deferred to a follow-up) |
| T3 cron doc | `docs/cron.md` | All 43 cron entries with schedule/purpose + orphan list |
| T4 migration index | `docs/migrations.md` | All 96 migrations indexed |
| T5 STATUS regen | `STATUS.md` | Live: branch, last 20 commits, open work signals |
| T6 untracked file sweep | `audits/2026-05-15-untracked-files.md` | All untracked paths classified |
| T7 memory hygiene | — | DEFERRED — manual review needed for cross-references |
| T8 AGENTS.md drift | — | DEFERRED — manual review |

## 2026-05-15 — U90 in-person packet

| Track | Output | Headline |
|---|---|---|
| T3 packet generator | `audits/2026-05-15-jo-checklist.md` | ~75 min total (sudo block ~30, external block ~45). Vault auto-unseal first; NatWest CSV for acct 15 unblocks 4 recon arcs |
| T4 verify script | `scripts/u90-verify.sh` | 8 checks (sudo + external blocks). Pre-session shows 6 FAILs as expected |
| T5 STATUS update | (auto via T3 — packet IS the consolidated checklist) | STATUS.md regenerated by U89 already points here |

The packet is the deliverable. Everything from U86–U89 that needed Jo's
in-person attention is consolidated into ONE document Jo runs at the box.

## 2026-05-15 — U92 overnight ops finesse (partial — bench running)

| Track | Output | Status |
|---|---|---|
| T1 LR + Xero parked | jo-checklist.md updated | ✓ done (time 75→50 min) |
| T2 NatWest nudge cron | `scripts/u92-nudge-natwest.sh` registered at 09:30 | ✓ done |
| T3 U89 deferred | `docs/views.md` (908 lines), `audits/...memory-hygiene.md`, `audits/...agents-md-drift.md` | ✓ done |
| T4 Email backfill 400d | `vendor_invoice_inbox` now reaches **2025-02-24** (446 days back from today) | ✓ done — 99 rows ingested + bulk-triaged |
| T5 Invoice backfill 400d | (same as T4, single endpoint) | ✓ done |
| T6 Qwen vs Haiku bench | (`scripts/u61-line-item-bench.sh` re-running in background) | ⏳ in-flight |
| T7 Percentages audit | `audits/...percentages-audit.md` — found HARDCODED 60/40 wet/dry split in v_daily_gp pub GP | ✓ done |
| T8 Cash recon flow | `audits/...cash-recon-flow.md` — 3 fixes recommended (auto-expected_cash, per-session hunter, exception trigger) | ✓ done |
| T9 Yesterday's email-tasks | (carried — bot_instructions pending=0; will surface at next session start) | ✓ no-op |
| T10 Recommendations + stretch lock | (next step — drafting after bench finishes) | ⏳ |
