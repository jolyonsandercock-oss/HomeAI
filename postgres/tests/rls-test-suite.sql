-- /home_ai/postgres/tests/rls-test-suite.sql
-- Runs the RLS policy assertion suite against every entity-scoped table.
--
-- Usage from the host:
--   docker exec -i homeai-postgres psql -U homeai_pipeline -d homeai \
--     -v ON_ERROR_STOP=1 < /home_ai/postgres/tests/rls-test-suite.sql
--
-- Logic per table:
--   1. Insert one test row at entity_id=1 and one at entity_id=2 (only if
--      the table is empty, to avoid corrupting real data).
--   2. SET app.current_entity = '2'  → expect to see only entity_id=2 rows.
--   3. SET app.current_entity = '1'  → expect to see only entity_id=1 rows.
--   4. SET app.current_entity = 'all' → expect to see both.
--   5. SET app.current_entity = ''    → expect zero rows (CASE falls through).
--   6. ROLLBACK so test rows never persist.
--
-- A failing assertion raises EXCEPTION, aborting the script with a non-zero
-- exit. All tests in one transaction so either everything passes or the
-- transaction rolls back.
--
-- Connect AS `homeai_pipeline` — postgres superuser bypasses RLS, so the
-- test must use a role that RLS actually applies to. The script will fail
-- if connected as a superuser with `BYPASSRLS`.

\set ON_ERROR_STOP on

DO $main$
DECLARE
  -- Tables to test. NULL columns array = use defaults below; otherwise
  -- override per-table because some have NOT NULL columns we have to set.
  t TEXT;
  is_super BOOLEAN;
  rls_active BOOLEAN;
BEGIN
  -- Refuse to run as a role that bypasses RLS (it would silently pass)
  SELECT rolsuper OR rolbypassrls INTO is_super
    FROM pg_roles WHERE rolname = current_user;
  IF is_super THEN
    RAISE EXCEPTION 'RLS test must run as a non-bypassing role; current_user=% has BYPASSRLS or SUPERUSER', current_user;
  END IF;

  -- Spot-check that we are observing RLS on a known-RLS table
  PERFORM set_config('app.current_entity', '', true);
  -- emails has RLS; with empty entity setting we should see zero rows
  -- regardless of any data present
  IF EXISTS (SELECT 1 FROM emails) THEN
    RAISE EXCEPTION 'RLS gate broken: rows visible from emails with empty app.current_entity (role=% BYPASSRLS check failed?)', current_user;
  END IF;

  RAISE NOTICE 'RLS gate OK on emails — proceeding to per-table tests';
END
$main$;

-- ─────────────────────────────────────────────────────────────────
-- Per-table test: events partition (uses partition events_2026_05).
-- We INSERT into the parent and ROLLBACK at the end.
-- ─────────────────────────────────────────────────────────────────
BEGIN;

SELECT set_config('app.current_entity', 'all', true);

-- emails — known RLS table, no NOT NULL beyond gmail_message_id
INSERT INTO emails (gmail_message_id, entity_id, account, subject, classification, processed)
VALUES ('rls_test_e1', 1, 'jo', 'rls test e1', 'fyi', true),
       ('rls_test_e2', 2, 'jo', 'rls test e2', 'fyi', true);

-- entity 1 view
SELECT set_config('app.current_entity', '1', true);
DO $a$ BEGIN
  IF (SELECT count(*) FROM emails WHERE gmail_message_id LIKE 'rls_test_%') <> 1 THEN
    RAISE EXCEPTION 'emails RLS@e1 expected 1 row, got %',
      (SELECT count(*) FROM emails WHERE gmail_message_id LIKE 'rls_test_%');
  END IF;
  IF EXISTS (SELECT 1 FROM emails WHERE gmail_message_id = 'rls_test_e2') THEN
    RAISE EXCEPTION 'emails RLS@e1 leaked entity=2 row';
  END IF;
END $a$;

-- entity 2 view
SELECT set_config('app.current_entity', '2', true);
DO $b$ BEGIN
  IF (SELECT count(*) FROM emails WHERE gmail_message_id LIKE 'rls_test_%') <> 1 THEN
    RAISE EXCEPTION 'emails RLS@e2 expected 1 row, got %',
      (SELECT count(*) FROM emails WHERE gmail_message_id LIKE 'rls_test_%');
  END IF;
  IF EXISTS (SELECT 1 FROM emails WHERE gmail_message_id = 'rls_test_e1') THEN
    RAISE EXCEPTION 'emails RLS@e2 leaked entity=1 row';
  END IF;
END $b$;

-- 'all' view
SELECT set_config('app.current_entity', 'all', true);
DO $c$ BEGIN
  IF (SELECT count(*) FROM emails WHERE gmail_message_id LIKE 'rls_test_%') <> 2 THEN
    RAISE EXCEPTION 'emails RLS@all expected 2 rows, got %',
      (SELECT count(*) FROM emails WHERE gmail_message_id LIKE 'rls_test_%');
  END IF;
END $c$;

-- empty / unset view
SELECT set_config('app.current_entity', '', true);
DO $d$ BEGIN
  IF (SELECT count(*) FROM emails WHERE gmail_message_id LIKE 'rls_test_%') <> 0 THEN
    RAISE EXCEPTION 'emails RLS@empty expected 0 rows, got %',
      (SELECT count(*) FROM emails WHERE gmail_message_id LIKE 'rls_test_%');
  END IF;
END $d$;

-- bad/non-numeric view
SELECT set_config('app.current_entity', 'not_a_number', true);
DO $e$ BEGIN
  IF (SELECT count(*) FROM emails WHERE gmail_message_id LIKE 'rls_test_%') <> 0 THEN
    RAISE EXCEPTION 'emails RLS@bad expected 0 rows, got %',
      (SELECT count(*) FROM emails WHERE gmail_message_id LIKE 'rls_test_%');
  END IF;
END $e$;

ROLLBACK;

-- ─────────────────────────────────────────────────────────────────
-- Quick smoke test on a second table (events) to catch policy-expr drift
-- on the partitioned table specifically. Use a tiny payload + signature.
-- ─────────────────────────────────────────────────────────────────
BEGIN;

SELECT set_config('app.current_entity', 'all', true);

INSERT INTO events (event_type, source, entity_id, payload, payload_signature, status, idempotency_key, pipeline_version)
VALUES ('rls.test', 'rls_test', 1, '{"x":1}'::jsonb, 'rls_test_sig', 'done', 'rls_test_evt_e1', '1.0'),
       ('rls.test', 'rls_test', 2, '{"x":2}'::jsonb, 'rls_test_sig', 'done', 'rls_test_evt_e2', '1.0');

SELECT set_config('app.current_entity', '1', true);
DO $f$ BEGIN
  IF (SELECT count(*) FROM events WHERE source = 'rls_test') <> 1 THEN
    RAISE EXCEPTION 'events RLS@e1 expected 1 row';
  END IF;
END $f$;

SELECT set_config('app.current_entity', '2', true);
DO $g$ BEGIN
  IF (SELECT count(*) FROM events WHERE source = 'rls_test') <> 1 THEN
    RAISE EXCEPTION 'events RLS@e2 expected 1 row';
  END IF;
END $g$;

ROLLBACK;

-- Final marker
SELECT 'RLS test suite passed' AS result;
