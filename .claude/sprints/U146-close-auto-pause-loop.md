# U146 — Close the auto-pause loop

**Prereqs**: U135 + U138-U145 retrospective shipped. System running with `dead_letter_digest_threshold=200` as a band-aid.

**Realm**: cross-cutting (event pipeline).

**Remote vs in-person**: 100% remote.

**Why this sprint exists**: Since 2026-05-17 the system has auto-paused every ~12h with `auto_pause:DeadLetterFlood`. Root cause documented in [[feedback_pipeline_downstream_missing]] — four n8n pipelines share a noOp-skip pattern that returns no item → master-router HttpRequest errors → events stay in `processing` → stale-lease-recovery dead-letters them → flood. Report Ingestion (P9) was patched 2026-05-21 via n8n API; the other three (Gmail Ingest, Invoice Pipeline, Nanny Pipeline) still have the bug.

## Tracks

### T1 — Patch noOp-skip in Gmail Ingest Pipeline (P1) (~30 min)

**Realm**: cross-cutting.

**Build**:
- Fetch current workflow JSON via `n8n API GET /workflows/gmail-ingest-v1`.
- Insert `Complete Skipped Event` postgres node between `Already Processed?` true output and `Stop — Already Done` noOp.
  - SQL: `UPDATE events SET status='processed', processed_at=NOW() WHERE id = {{ $('Sanitise Email').first().json.event_id }} AND status='processing' RETURNING id, 'skipped' AS outcome;`
  - Credentials: `iTuuNfsqHY49MGhk` (HomeAI Postgres).
- Rewire connections: `Already Processed?` out 0 → `Complete Skipped Event` → `Stop — Already Done`.
- PUT via n8n API with body restricted to `{name, nodes, connections, settings, staticData}`.

**Acceptance**: trigger a known-processed email; confirm event status transitions to 'processed' within 5s. No DL row created.

### T2 — Patch noOp-skip in Invoice Pipeline (~30 min)

Same pattern as T1. Find the workflow's "already-processed" noOp (name varies), insert `Complete Invoice Event` postgres node updating events.status, rewire.

### T3 — Patch noOp-skip in Nanny Pipeline (~30 min)

Same pattern. Confirm the downstream completion table the recovery function checks (probably `nanny_events` or similar); align the SQL update.

### T4 — V164c partition-child sweep (~45 min)

**Realm**: cross-cutting (schema).

**Why**: V164 widened CHECK constraints on partition parents; V164b widened on declared partition parents (relkind='p'). Neither caught the 349 declarative partition CHILD tables (relkind='r'). INSERTs with realm='personal' into those partitions currently fail.

**Build**: new migration `V178__u146_partition_children_realm_widen.sql` — loop over `pg_class` where `relkind='r'` AND `relispartition=true`, find each child's CHECK constraint, drop+recreate with 'personal' added.

**Acceptance**: `SELECT count(*) FROM pg_constraint WHERE conname LIKE '%realm_check%' AND pg_get_constraintdef(oid) NOT LIKE '%personal%'` returns 0.

### T5 — V165 narrow apply: drop 'family' (~15 min)

**Realm**: cross-cutting.

**Build**: apply V165 (already in migrations dir, marked DRAFT). Pre-flight check: `SELECT count(*) FROM events WHERE realm='family'` is 0 across all major tables.

**Acceptance**: 0 CHECK constraints contain 'family'. `home_ai.set_realm('family')` raises exception.

### T6 — Revert DL threshold 200 → 5 (~5 min)

**Build**: `UPDATE static_context SET value = value || '{"dead_letter_digest_threshold": 5}'::jsonb WHERE key='system.limits';`

**Acceptance**: 24h soak passes without auto-pause.

## Done criteria

- Selftest passes (50 PASS / 0 FAIL).
- `system.state` stays 'running' for 24h.
- No new DLs from `stale_lease_recovery` for any of the four pipelines.
- All 4 pipelines: stuck `processing` events recover within 10s of patched-noOp branch firing.

## Risk

Low. Each pipeline patch is the proven Report Ingestion pattern. Partition-child sweep is additive (no data move). V165 is a constraint narrowing — already-pre-flighted by V164.
