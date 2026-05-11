# U10-bis state — paused 2026-05-10 ~08:55 UTC

## What's running
- `homeai-google-fetch` service with `/poll-and-emit` endpoint — Python implementation handling 5-account auth + Gmail fetch + atomic claim+INSERT
- `gmail-poll-driver-v1` n8n workflow: scheduleTrigger (15 min) → HTTP POST `/poll-and-emit` → audit_log row. Active.
- Old `QMKzaCFrKBS4ewWm` legacy poller: deactivated.
- `gmail-ingest-v1` classifier: legacy "INSERT email.received" node REMOVED from both workflow_entity and workflow_history. Bounced 08:51 UTC.

## What's verified
- /poll-and-emit fired manually: 71 messages across 5 accounts, 0 errors, all dup-skipped (claims already in event_idempotency_keys)
- Driver fired automatically at 08:30:52, 16s, success — wrote 2 events with proper account values + 1 audit_log row
- BUT 2 duplicate events also appeared with empty account / pipeline_version='1.0' from gmail-ingest-v1's now-removed re-emission node

## What's pending verification
- Next 15-min driver fire (expected ~08:45-09:00 UTC) should produce events with ONLY pipeline_version='gmail_poller_py:1.0' (no '1.0' shadows)
- Verify by querying:
  ```sql
  SELECT pipeline_version, COUNT(*) FROM events
   WHERE event_type='email.received' AND created_at > '2026-05-10 08:45:00'
   GROUP BY 1;
  ```

## What to do next session
1. Check the post-08:45 events table — confirm only `gmail_poller_py:1.0` versions
2. If clean: mark U10-bis closed, update debt.yaml, AGENTS.md build state
3. If messy (still re-emitting somewhere): `gmail-ingest-v1` may need deeper rebuild
4. Selftest hardcodes `QMKzaCFrKBS4ewWm` as expected-active; needs update to expect `gmail-poll-driver-v1` instead. File: `/home_ai/scripts/selftest.sh`

## Lessons saved to memory this session
- Rule 10: Audit ALL consumers before replacing a producer
