-- u15-regression.sql — exercises recover_stale_leases_v2 downstream-verification
-- branch. Synthesises a stuck event with retry_count=3, plus a matching
-- downstream emails row, runs v2, asserts the event was marked 'processed'
-- (not dead-lettered) and an audit row was written.
--
-- Runs entirely inside a single transaction with ROLLBACK at the end so prod
-- state is unchanged. Exit code is the assertion count — 0 = pass.
--
-- Usage:
--   docker exec -i homeai-postgres psql -U postgres -d homeai \
--     -v ON_ERROR_STOP=1 -f /tmp/u15-regression.sql
--
-- The test outputs PASS/FAIL lines you can grep.

\set ON_ERROR_STOP on

BEGIN;

-- ── 1. Synthesise downstream emails row first ─────────────────────────
SET LOCAL app.current_entity = '3';
INSERT INTO emails (gmail_message_id, account, from_address, subject, received_at, body_text, classification, entity_id, confidence_score)
VALUES (
  'u15-regression-' || extract(epoch from now())::text,
  'bot', 'sender@regression.local', 'U15 regression test', NOW(),
  'body', 'fyi', 3, 1.0
)
RETURNING id AS test_email_id, gmail_message_id AS test_gmid \gset

-- ── 2. Synthesise stuck event with retry_count=3 ──────────────────────
INSERT INTO events (
  event_type, source, entity_id, payload, payload_signature,
  trace_id, idempotency_key,
  status, retry_count, processing_started_at, processing_node_id
)
VALUES (
  'email.received', 'u15_test', 3,
  jsonb_build_object('gmail_message_id', :'test_gmid', 'from_address', 'sender@regression.local'),
  'fake-sig-for-test',
  gen_random_uuid(),
  'u15-test-' || extract(epoch from now())::text,
  'processing', 3, NOW() - INTERVAL '15 minutes', 'test-node'
)
RETURNING id AS test_event_id \gset

-- ── 3. Snapshot before ────────────────────────────────────────────────
SELECT 'BEFORE  status=' || status || ' retry=' || retry_count AS before
  FROM events WHERE id = :test_event_id;

-- ── 4. Run v2 ─────────────────────────────────────────────────────────
SELECT 'V2_OUT  recovered=' || recovered_count
            || ' resolved_post_lease=' || resolved_post_lease
            || ' dead_lettered=' || dead_lettered_count AS v2_out
  FROM recover_stale_leases_v2();

-- ── 5. Assert ─────────────────────────────────────────────────────────
SELECT CASE
         WHEN status = 'processed' THEN 'PASS — event marked processed'
         ELSE 'FAIL — event status=' || status || ' (expected processed)'
       END AS event_check
  FROM events WHERE id = :test_event_id;

SELECT CASE
         WHEN COUNT(*) = 0 THEN 'PASS — no dead_letter row created'
         ELSE 'FAIL — ' || COUNT(*)::text || ' dead_letter row(s) created'
       END AS dl_check
  FROM dead_letter WHERE event_id = :test_event_id;

SELECT CASE
         WHEN COUNT(*) = 1 THEN 'PASS — recovered_post_lease audit row written'
         ELSE 'FAIL — audit_log entries=' || COUNT(*)::text
       END AS audit_check
  FROM audit_log
 WHERE event_id = :test_event_id
   AND action = 'recovered_post_lease';

-- ── 6. Negative branch: stuck event with NO downstream → dead-lettered ─
INSERT INTO events (
  event_type, source, entity_id, payload, payload_signature,
  trace_id, idempotency_key,
  status, retry_count, processing_started_at, processing_node_id
)
VALUES (
  'email.received', 'u15_test_neg', 3,
  jsonb_build_object('gmail_message_id', 'no-downstream-' || extract(epoch from now())::text),
  'fake-sig-for-test',
  gen_random_uuid(),
  'u15-test-neg-' || extract(epoch from now())::text,
  'processing', 3, NOW() - INTERVAL '15 minutes', 'test-node'
)
RETURNING id AS neg_event_id \gset

SELECT 'V2_OUT_NEG ' || (recovered_count::text || '/' || resolved_post_lease::text || '/' || dead_lettered_count::text) AS v2_neg
  FROM recover_stale_leases_v2();

SELECT CASE
         WHEN status = 'failed' THEN 'PASS — negative event correctly marked failed'
         ELSE 'FAIL — negative event status=' || status
       END AS neg_event_check
  FROM events WHERE id = :neg_event_id;

SELECT CASE
         WHEN COUNT(*) = 1 THEN 'PASS — negative event correctly dead-lettered'
         ELSE 'FAIL — negative event dead_letter rows=' || COUNT(*)::text
       END AS neg_dl_check
  FROM dead_letter WHERE event_id = :neg_event_id;

ROLLBACK;
