-- verify-counterparty-registry.sql — assertions; psql exits non-zero on any failure.
\set ON_ERROR_STOP on

DO $$ BEGIN
  IF to_regclass('public.counterparties') IS NULL THEN
    RAISE EXCEPTION 'counterparties table does not exist';
  END IF;
END $$;

DO $$
DECLARE missing text;
BEGIN
  SELECT string_agg(c, ', ') INTO missing
  FROM unnest(ARRAY['id','kind','display_name','domain','primary_email','addresses',
                    'parent_org_id','realms','is_automated','email_count','first_seen',
                    'last_seen','linked_vendor','linked_confidence','signal_score',
                    'on_watchlist','created_at','updated_at']) AS c
  WHERE c NOT IN (SELECT column_name FROM information_schema.columns
                  WHERE table_name='counterparties');
  IF missing IS NOT NULL THEN RAISE EXCEPTION 'counterparties missing columns: %', missing; END IF;
END $$;

DO $$ BEGIN
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE relname='counterparties') THEN
    RAISE EXCEPTION 'RLS not enabled on counterparties';
  END IF;
END $$;
