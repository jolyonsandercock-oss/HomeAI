# n8n workflow topology — events, the master router, dead letters

Ingest is event-sourced through one Postgres `events` table (partitioned).
Producers (gmail-ingest, scrapers, emitters) INSERT typed events
(`email.received`, `document.received`, `invoice.detected`,
`child.event.detected`, …) with idempotency keys and HMAC-signed payloads.

**The master router** is the single consumer loop: it calls
`claim_event_batch()` (FOR UPDATE SKIP LOCKED, pending, <7 days old, batch 10,
status→processing) and dispatches each event to its pipeline sub-workflow.
Terminal states: `processed` (with `processed_at` ALWAYS stamped — V261
backfilled 4,400 events whose emitters wrote born-terminal rows without it),
`done` (record-only types), `failed`. `recover_stale_leases_v3` re-pends
events stuck in `processing` (e.g. after an n8n restart) and dead-letters
retry-exhausted ones into `dead_letter` — unresolved DLs page via the
supervisor; a DL flood historically auto-paused pipelines.

**Editing workflows at runtime:** n8n executes `workflow_history` via
`workflow_entity.activeVersionId` — editing `workflow_entity.nodes` directly
does NOTHING; insert a history row and repoint, or use the n8n API. Expression
syntax trap: never put literal `}}` inside `{{…}}`. The Postgres node breaks
on multi-statement writes containing `SET LOCAL`, and inline `$N`-looking
values collide with pg-promise binds — use parameterized queries.

Known overlap: `document.received` duplicates the invoice harvester's coverage
for invoice emails (a stuck one usually means the harvester already captured
the doc — verify in `vendor_invoice_inbox` before re-driving). Crons that feed
n8n live in joly's crontab, not root's; `cron-health-check.py` watches their
log mtimes (only `>>`-style logging is visible to it).
