# Dead-letter triage

Generated 2026-05-15T20:30:28+01:00. Read-only.

Top 50 buckets of failed/dead-letter events grouped by (event_type, error_class).
Action candidates: each bucket is either safe-to-replay (idempotent emit), needs-fix (root cause), or skip (one-off corruption).

| event_type | error_class | count | oldest | newest | sample | retry_safety |
|---|---|---|---|---|---|---|
| email.received | Stale lease — exceeded retry limit | 121 | 2026-05-09 | 2026-05-10 | Stale lease — exceeded retry limit | idempotent (safe replay) |
| invoice.detected | (no message) | 55 | 2026-05-11 | 2026-05-13 |  | idempotent (safe replay) |
| email.received | (no message) | 46 | 2026-05-13 | 2026-05-13 |  | idempotent (safe replay) |
| document.received | (no message) | 31 | 2026-05-13 | 2026-05-13 |  | idempotent (safe replay) |
| invoice.detected | Stale lease — exceeded retry limit | 18 | 2026-05-09 | 2026-05-10 | Stale lease — exceeded retry limit | idempotent (safe replay) |
| email.received | Marked failed during V13 cleanup — recov | 15 | 2026-05-08 | 2026-05-08 | Marked failed during V13 cleanup — recover_stale_leases bug + duplicate Gmail Tr | idempotent (safe replay) |
| child.event.detected | (no message) | 7 | 2026-05-10 | 2026-05-13 |  | ? |
| email.received | Rollback U10-bis — classifier INSERT ema | 7 | 2026-05-10 | 2026-05-10 | Rollback U10-bis — classifier INSERT emails UNIQUE collision | idempotent (safe replay) |
| system.config_change | Marked failed during V13 cleanup — recov | 2 | 2026-05-07 | 2026-05-07 | Marked failed during V13 cleanup — recover_stale_leases bug + duplicate Gmail Tr | ? |
| invoice.detected | Marked failed during V13 cleanup — recov | 1 | 2026-05-06 | 2026-05-06 | Marked failed during V13 cleanup — recover_stale_leases bug + duplicate Gmail Tr | idempotent (safe replay) |
| system.asyncpg_test | Marked failed during V13 cleanup — recov | 1 | 2026-05-03 | 2026-05-03 | Marked failed during V13 cleanup — recover_stale_leases bug + duplicate Gmail Tr | ? |
| test.config | Marked failed during V13 cleanup — recov | 1 | 2026-05-03 | 2026-05-03 | Marked failed during V13 cleanup — recover_stale_leases bug + duplicate Gmail Tr | ? |
| test.debug | Marked failed during V13 cleanup — recov | 1 | 2026-05-03 | 2026-05-03 | Marked failed during V13 cleanup — recover_stale_leases bug + duplicate Gmail Tr | ? |

## Action queue (for U88 fix-and-forget)

- Total failure buckets: 13
- Idempotent → replay candidates: see rows marked 'idempotent'
- Destructive → require human review before retry
