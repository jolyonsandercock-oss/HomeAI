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

-- Population assertions (require home_ai.build_counterparty_registry() to have run).
DO $$ BEGIN
  IF (SELECT count(*) FROM counterparties WHERE kind='org') < 100 THEN
    RAISE EXCEPTION 'expected >=100 org counterparties, got %',
      (SELECT count(*) FROM counterparties WHERE kind='org');
  END IF;
END $$;

-- Own domain must be excluded.
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM counterparties WHERE domain = 'malthousetintagel.com') THEN
    RAISE EXCEPTION 'own domain malthousetintagel.com must not be a counterparty';
  END IF;
END $$;

-- A known real vendor domain must be present as an org with a realm.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM counterparties
                 WHERE kind='org' AND domain='jrf.lls.com'
                   AND array_length(realms,1) >= 1 AND email_count > 0) THEN
    RAISE EXCEPTION 'expected jrf.lls.com org with realm + email_count';
  END IF;
END $$;

-- People link to their org by domain.
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM counterparties p
    JOIN counterparties o ON o.kind='org' AND o.domain=p.domain
    WHERE p.kind='person' AND p.parent_org_id IS DISTINCT FROM o.id) THEN
    RAISE EXCEPTION 'person rows exist whose parent_org_id does not match their domain org';
  END IF;
END $$;
