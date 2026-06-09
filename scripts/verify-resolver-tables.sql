-- verify-resolver-tables.sql — P1a structural assertions; psql exits non-zero on failure.
\set ON_ERROR_STOP on

DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['counterparty_anchor','counterparty_resolution_log',
      'counterparty_resolution_review_queue','counterparty_resolution_shadow',
      'counterparty_registry_version','counterparty_merge_history'] LOOP
    IF to_regclass('public.'||t) IS NULL THEN RAISE EXCEPTION 'table % missing', t; END IF;
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE relname=t) THEN
      RAISE EXCEPTION 'RLS not enabled on %', t; END IF;
  END LOOP;
END $$;

-- the active-anchor unique index (safety proof for unique-in-scope => HIGH)
DO $$ BEGIN
  IF to_regclass('public.counterparty_anchor_active_key') IS NULL THEN
    RAISE EXCEPTION 'counterparty_anchor_active_key (unique-active) index missing'; END IF;
  IF to_regclass('public.resolution_log_valid_key') IS NULL THEN
    RAISE EXCEPTION 'resolution_log_valid_key index missing'; END IF;
END $$;

-- default-deny: no permissive-null branch in realm-bearing policies
DO $$ DECLARE q text; t text; BEGIN
  FOREACH t IN ARRAY ARRAY['counterparty_anchor','counterparty_resolution_log',
      'counterparty_resolution_review_queue'] LOOP
    SELECT qual INTO q FROM pg_policies WHERE tablename=t AND policyname='realm_isolation';
    IF q IS NULL THEN RAISE EXCEPTION 'realm_isolation missing on %', t; END IF;
    IF q ILIKE '%IS NULL%THEN true%' OR q ILIKE '%= ''''%THEN true%' THEN
      RAISE EXCEPTION '% has permissive-null branch (must be default-deny)', t; END IF;
  END LOOP;
END $$;

-- resolver mode flag present and shadow
DO $$ BEGIN
  IF (SELECT value FROM static_context WHERE key='resolver.mode') IS DISTINCT FROM '"shadow"'::jsonb THEN
    RAISE EXCEPTION 'resolver.mode not set to shadow'; END IF;
END $$;

-- upsert_anchor exists
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname='upsert_anchor') THEN
    RAISE EXCEPTION 'home_ai.upsert_anchor missing'; END IF;
END $$;
