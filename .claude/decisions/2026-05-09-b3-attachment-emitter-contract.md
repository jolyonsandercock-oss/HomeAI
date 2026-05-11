# ADR — B3 attachment-emitter contract: Poller→P9 with gmail_message_id-only

**Date:** 2026-05-09
**Status:** Accepted (live in Gmail Poller + report-ingestion-v1)
**Replaces:** earlier B3 design that required `email_id` in the document.received payload

## Context

P9 (Report Ingestion) processes email attachments. The original SPEC §6.2
node sequence assumed P9 receives `email_id` (FK to `emails`) in the
`document.received` event payload. But:

- The Gmail Poller emits `email.received` events; gmail-ingest-v1 INSERTs
  the `emails` row (and assigns the email_id PK) only after AI classification.
- If the Poller emitted document.received with email_id, it would have to
  block on emails being created — but emails depends on Master Router
  routing email.received → email pipeline → INSERT emails. Race condition
  and circular wait.
- If the Poller emitted document.received WITHOUT email_id, P9's INSERT
  into email_attachments fails its FK constraint.

This blocked B3 for a sprint until the contract was redesigned.

## Decision

Two changes to the contract:

1. **Poller emits `document.received` with `gmail_message_id` only**, no
   email_id. Payload: `{gmail_message_id, attachment_id, filename, mime_type, size}`.
   Idempotency key: `report_{sha256(gmail_message_id+filename)}`.

2. **P9 resolves `email_id` at INSERT time** by joining `emails` on
   `gmail_message_id`. If the emails row doesn't exist yet (race — gmail-ingest-v1
   hasn't run), P9 INSERTs `email_attachments` with `email_id = NULL`. Since
   `email_attachments.email_id` is nullable in the schema, this is structurally
   allowed.

Idempotency Check is `(gmail_message_id, filename)` rather than
`(email_id, filename)` so re-fires of the same attachment converge on the
same `email_attachments` row.

## Consequences

**Positive:**
- Eliminates the circular dependency between Poller and email pipeline.
- P9 can run in any order relative to gmail-ingest-v1 — they converge.
- Contract is simpler: Poller knows nothing about emails table.

**Negative / followup needed:**
- email_attachments rows can have NULL email_id transiently (only until
  gmail-ingest-v1 INSERTs the email). A nightly back-fill job (Phase 2) should
  populate NULL email_ids by matching gmail_message_id.
- If P9 runs before gmail-ingest-v1 ever runs (e.g. email.received fails),
  the attachment is stranded with no email row. Acceptable — surfaced
  via dead_letter / audit_log.

## References

- Sprint 2 deferral discussion → Sprint 3 SP3-A3 implementation
- Patcher: `/tmp/patch-poller-attachments.py` + `/tmp/patch-p9-b3.py`
  (one-shot, not preserved)
- Implementation: Gmail Poller (`QMKzaCFrKBS4ewWm`) Parse + Sanitise +
  Sign + Build Event SQL nodes; `report-ingestion-v1` Validate Event +
  Idempotency Check + Upsert nodes
