# Cron health audit

Generated 2026-05-15T20:37:03+01:00. Read-only.

For each cron-installed script: when did its log last get written, how big is it,
and how many recent invocations produced visible errors.

| script | log file | log size | last touched | recent errors | flag |
|---|---|---|---|---|---|
| backup-nightly.sh | (none) | — | — | — | 🟡 no log |
| u27-touchoffice-daily.sh | (none) | — | — | — | 🟡 no log |
| u28-caterbook-daily.sh | (none) | — | — | — | 🟡 no log |
| u29-daily-digest.sh | u29-daily-digest.log | 0.2 KB | 2026-05-14 21:00:02 | 0
0 |  |
| u29-heartbeat.sh | u29-heartbeat.log | 21.7 KB | 2026-05-15 20:30:02 | 0
0 |  |
| u29-instructions-poll.sh | u29-instructions-poll.log | 67.7 KB | 2026-05-15 20:35:02 | 0
0 |  |
| u29-workforce-sync.sh | u29-workforce-sync.log | 0.8 KB | 2026-05-15 02:15:03 | 0
0 |  |
| u32-cashing-up-parser.sh | (none) | — | — | — | 🟡 no log |
| u32-workforce-pay-sync.sh | (none) | — | — | — | 🟡 no log |
| u33-bot-responder.sh | u33-bot-responder.log | 0.3 KB | 2026-05-15 08:50:02 | 0
0 |  |
| u33-data-lane-router.sh | u33-data-lane-router.log | 17.2 KB | 2026-05-15 17:00:03 | 21 | 🔴 errors |
| u33-rejection-digest.sh | u33-rejection-digest.log | 0.0 KB | 2026-05-12 14:30:01 | 0
0 |  |
| u33-touchoffice-realtime.sh | u33-touchoffice-realtime.log | 72.7 KB | 2026-05-15 20:30:01 | 4 | 🔴 errors |
| u34-tanda-departments-sync.sh | (none) | — | — | — | 🟡 no log |
| u35-image-drift-check.sh | (none) | — | — | — | 🟡 no log |
| u36-dreaming-nightly.sh | (none) | — | — | — | 🟡 no log |
| u36-model-inventory-scan.sh | (none) | — | — | — | 🟡 no log |
| u36-reconciliation-explainer.sh | (none) | — | — | — | 🟡 no log |
| u39-review-drafter.sh | u39-review-drafter.log | 21.1 KB | 2026-05-15 20:30:01 | 0
0 |  |
| u40-companies-house-sync.sh | (none) | — | — | — | 🟡 no log |
| u41-land-registry-sync.sh | (none) | — | — | — | 🟡 no log |
| u42-vat-return-prep.sh | (none) | — | — | — | 🟡 no log |
| u44-feedback-applier.sh | (none) | — | — | — | 🟡 no log |
| u46-email-task-extractor.sh | (none) | — | — | — | 🟡 no log |
| u46-weather-daily.sh | (none) | — | — | — | 🟡 no log |
| u47e-uncertain-resolve.sh | u47e-uncertain-resolve.log | 0.4 KB | 2026-05-15 06:30:03 | 1 | 🔴 errors |
| u47-tanda-timesheets-sync.sh | u47-tanda-timesheets-sync.log | 0.2 KB | 2026-05-15 02:20:02 | 0
0 |  |
| u50-apply-feedback.sh | u50-apply-feedback.log | 7.2 KB | 2026-05-15 20:23:01 | 14 | 🔴 errors |
| u50-stale-ack.sh | u50-stale-ack.log | 0.1 KB | 2026-05-15 18:25:01 | 0
0 |  |
| u51-vehicle-alerts.sh | u51-vehicle-alerts.log | 0.0 KB | 2026-05-15 09:00:01 | 0
0 |  |
| u54-card-recon-writer.sh | (none) | — | — | — | 🟡 no log |
| u54-pipeline-watchdog.sh | (none) | — | — | — | 🟡 no log |
| u56-realm-scoped-backup.sh | (none) | — | — | — | 🟡 no log |
| u61-coverage-audit.sh | (none) | — | — | — | 🟡 no log |
| u61-line-items-extract.sh | (none) | — | — | — | 🟡 no log |
| u62-calendar-sync.sh | u62-calendar-sync.log | 15.5 KB | 2026-05-15 20:30:03 | 1 | 🔴 errors |
| u62-doc-alerts.sh | u62-doc-alerts.log | 0.2 KB | 2026-05-15 09:00:01 | 1 | 🔴 errors |
| u62-paperless-sync.sh | u62-paperless-sync.log | 46.1 KB | 2026-05-15 20:30:02 | 7 | 🔴 errors |
| u66-telegram-bot.sh | u66-telegram-bot.log | 20.0 KB | 2026-05-15 20:37:02 | 0
0 |  |
| u68-recon-orchestrator.sh | (none) | — | — | — | 🟡 no log |
| u69-morning-digest.sh | (none) | — | — | — | 🟡 no log |
| u72-missing-data-hunters.sh | (none) | — | — | — | 🟡 no log |
| u75-pipeline-smoke.sh | (none) | — | — | — | 🟡 no log |

## Summary

- Cron-installed scripts: 43
- Logs > 50 MB (rotate candidate): 0
- Logs > 7d cold (might be dead crons): see 🟡 flags
- Logs with recent error lines: see 🔴 flags
