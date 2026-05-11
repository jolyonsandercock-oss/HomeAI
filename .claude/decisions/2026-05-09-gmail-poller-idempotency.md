# ADR — Gmail Poller emits idempotent email.received events

**Date:** 2026-05-09
**Status:** Accepted (live)
**Fixes:** Bug surfaced by postgres_exporter custom metrics — duplicate event rows

## Context

The Gmail Poller (`QMKzaCFrKBS4ewWm`) runs every 15 minutes and INSERTs an
`email.received` event for each Gmail message it sees. Pre-fix, each poll
re-inserted events for messages already in our DB — no idempotency check.

The `events` table has a non-unique index on `idempotency_key` (because
partitioned tables can't UNIQUE-index a non-partition-key column without
including `created_at` — see ADR on events idempotency). So `ON CONFLICT
(idempotency_key)` doesn't work; the application must check for duplicates
explicitly.

Sprint 1's monitoring sweep surfaced 23 events stuck in `processing` for
the same gmail_message_id, plus 11k spurious dead-letter rows from
recover_stale_leases() repeatedly dead-lettering the same stuck events.
Root cause: re-fetched messages → duplicate event rows → each duplicate
gets routed → email pipeline short-circuits (gmail_message_id already in
emails) → event stuck `processing` → recover_stale_leases dead-letters →
loop.

## Decision

Patch the Gmail Poller's `Sign + Build Event SQL` Code node to gate the
INSERT with `WHERE NOT EXISTS`:

```sql
INSERT INTO events (...)
SELECT 'email.received', ..., 'email_<gmail_message_id>', ...
 WHERE NOT EXISTS (
   SELECT 1 FROM events WHERE idempotency_key = 'email_<gmail_message_id>'
 )
RETURNING id, trace_id;
```

Same pattern applied to the per-attachment `document.received` events in
Sprint 3 (B3): `WHERE NOT EXISTS (SELECT 1 FROM events WHERE idempotency_key
= 'report_<sha256(gmail_message_id+filename)>')`.

## Consequences

**Positive:**
- Re-polling doesn't multiply events.
- recover_stale_leases() (V13/V14) now has clean signal — only genuinely-stale
  leases get dead-lettered.
- One less source of audit_log noise.

**Negative:**
- Trace continuity for the *same* email across multiple polls is
  abandoned — the second poll just no-ops. If the original event was
  somehow lost (e.g. hard pipeline failure with no event row), there's no
  retry from the poller. Acceptable: the dead_letter mechanism + manual
  replay covers this case.
- Detection of the bug took monitoring infrastructure to be in place first
  (custom postgres_exporter metrics → pipeline_processing_lease_age +
  dead_letter_recent_count gauges). Without those, the bug was invisible.

## References

- Implementation patcher: `/tmp/patch-poller.py` (one-shot)
- Sprint 2 SP2-A1 task entry
- Sister fix in V13 (recover_stale_leases atomicity) — without that fix,
  this WHERE NOT EXISTS alone wouldn't have stopped the dead_letter flood
- Memory: feedback_homeai.md "events.idempotency_key has NO unique constraint"
