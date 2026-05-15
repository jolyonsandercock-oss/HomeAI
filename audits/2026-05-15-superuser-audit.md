# Superuser-bypass audit

Generated 2026-05-15T20:34:08+01:00. Read-only.

Scripts in /home_ai/scripts/ and /home_ai/services/ that connect as
`postgres` superuser bypass RLS by default. Each is categorised:

- `ddl-needed` — runs migrations / CREATE / ALTER. Keep on superuser.
- `should-be-pipeline` — DML only. Migrate to `homeai_pipeline` + SET LOCAL guards.
- `should-be-readonly` — SELECT only. Migrate to `homeai_readonly`.

## Script-by-script

| file | line | category | rationale |
|---|---|---|---|
| scripts/u52-realm-shadow-test.sh | 90 | should-be-readonly | (auto) |
| scripts/u52-realm-shadow-test.sh | 104 | should-be-readonly | (auto) |
| scripts/u52-realm-shadow-test.sh | 134 | unknown | (auto) |
| scripts/schema-drift-check.sh | 56 | ddl-needed | (auto) |
| scripts/schema-drift-check.sh | 58 | ddl-needed | (auto) |
| scripts/schema-drift-check.sh | 60 | ddl-needed | (auto) |
| scripts/schema-drift-check.sh | 65 | ddl-needed | (auto) |
| scripts/u53-r5-realm-backfill.sh | 24 | unknown | (auto) |
| scripts/u68-recon-l2.sh | 23 | should-be-readonly | (auto) |
| scripts/u59c-account-transfer-link.sh | 20 | should-be-readonly | (auto) |
| scripts/u54-pipeline-watchdog.sh | 26 | should-be-readonly | (auto) |
| scripts/u86-audit-hunters-rerun.sh | 15 | should-be-readonly | (auto) |
| scripts/payments/test-phase1-acceptance.sh | 47 | should-be-readonly | (auto) |
| scripts/payments/test-phase1-acceptance.sh | 57 | should-be-readonly | (auto) |
| scripts/payments/test-phase1-acceptance.sh | 75 | should-be-readonly | (auto) |
| scripts/payments/test-phase1-acceptance.sh | 84 | should-be-readonly | (auto) |
| scripts/u68-recon-orchestrator.sh | 48 | should-be-readonly | (auto) |
| scripts/u86-audit-fk-orphans.sh | 9 | should-be-readonly | (auto) |
| scripts/u86-audit-fk-orphans.sh | 49 | should-be-readonly | (auto) |
| scripts/u72-onboard-48885517.sh | 28 | should-be-pipeline | (auto) |
| scripts/u72-onboard-48885517.sh | 55 | should-be-readonly | (auto) |
| scripts/u78-run.sh | 10 | ddl-needed | (auto) |
| scripts/u86-audit-idempotency.sh | 14 | should-be-readonly | (auto) |
| scripts/u86-audit-idempotency.sh | 42 | should-be-readonly | (auto) |
| scripts/u86-audit-idempotency.sh | 49 | should-be-readonly | (auto) |
| scripts/u86-audit-schema-drift.sh | 32 | ddl-needed | (auto) |
| scripts/u86-audit-schema-drift.sh | 35 | ddl-needed | (auto) |
| scripts/u67-recon-l1.sh | 31 | should-be-readonly | (auto) |
| scripts/u33-touchoffice-realtime.sh | 18 | should-be-readonly | (auto) |
| scripts/u58-bank-tx-categorise.sh | 18 | should-be-pipeline | (auto) |
| scripts/u61-backfill-orchestrator.sh | 25 | should-be-readonly | (auto) |
| scripts/u61-backfill-orchestrator.sh | 84 | should-be-pipeline | (auto) |
| scripts/u86-audit-dead-letters.sh | 10 | should-be-readonly | (auto) |
| scripts/u86-audit-bank-coverage.sh | 9 | should-be-readonly | (auto) |
| scripts/u62-doc-alerts.sh | 7 | should-be-readonly | (auto) |
| scripts/u62-doc-alerts.sh | 36 | should-be-pipeline | (auto) |
| scripts/u42-vat-return-prep.sh | 13 | should-be-readonly | (auto) |
| scripts/u51-vehicle-intake.sh | 30 | should-be-readonly | (auto) |
| scripts/u51-vehicle-intake.sh | 106 | should-be-readonly | (auto) |
| scripts/u56-realm-scoped-backup.sh | 31 | unknown | (auto) |
| scripts/u56-realm-scoped-backup.sh | 85 | should-be-readonly | (auto) |
| scripts/u70-ocr-bench.sh | 11 | should-be-readonly | (auto) |
| scripts/u50-stale-ack.sh | 14 | should-be-pipeline | (auto) |
| scripts/u36-dreaming-nightly.sh | 230 | should-be-pipeline | (auto) |
| scripts/u36-dreaming-nightly.sh | 235 | should-be-pipeline | (auto) |
| scripts/restore.sh | 106 | unknown | (auto) |
| scripts/restore.sh | 107 | unknown | (auto) |
| scripts/restore.sh | 109 | unknown | (auto) |
| scripts/restore.sh | 117 | unknown | (auto) |
| scripts/restore.sh | 118 | unknown | (auto) |
| scripts/restore.sh | 120 | unknown | (auto) |
| scripts/u87-audit-rls.sh | 11 | should-be-readonly | (auto) |
| scripts/u87-audit-superuser-usage.sh | 26 | ddl-needed | (auto) |
| scripts/u87-audit-superuser-usage.sh | 49 | unknown | (auto) |
| scripts/u69-morning-digest.sh | 30 | unknown | (auto) |
| scripts/u68-recon-l3.sh | 31 | should-be-readonly | (auto) |
| scripts/selftest.sh | 38 | unknown | (auto) |
| scripts/u72-missing-data-hunters.sh | 9 | should-be-readonly | (auto) |
| scripts/log-build-activity.sh | 59 | should-be-pipeline | (auto) |
| scripts/u39-insert-review.sh | 10 | unknown | (auto) |
| scripts/u75-pipeline-smoke.sh | 54 | should-be-readonly | (auto) |
| scripts/u75-pipeline-smoke.sh | 69 | should-be-pipeline | (auto) |
| scripts/u29-schools-backfill.sh | 42 | should-be-readonly | (auto) |
| scripts/u29-schools-backfill.sh | 67 | should-be-pipeline | (auto) |
| scripts/u62-paperless-bootstrap.sh | 29 | should-be-readonly | (auto) |
| scripts/u62-paperless-bootstrap.sh | 43 | should-be-readonly | (auto) |
| scripts/u62-paperless-bootstrap.sh | 45 | unknown | (auto) |
| scripts/u54-card-recon-writer.sh | 27 | should-be-readonly | (auto) |
| scripts/u36-jo-input-batch.sh | 10 | unknown | (auto) |
| scripts/u36-jo-input-batch.sh | 11 | unknown | (auto) |
| scripts/u61-coverage-audit.sh | 22 | should-be-readonly | (auto) |

## Summary

- Total `psql -U postgres` callsites: 71
- ddl-needed (keep superuser): 8
- should-be-pipeline (migrate): 10
- should-be-readonly (migrate): 37
- unknown (manual review): 16
