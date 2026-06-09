-- verify-financial-counterparty.sql — P0 assertions; psql exits non-zero on any failure.
\set ON_ERROR_STOP on

-- table + key columns exist
DO $$ DECLARE missing text; BEGIN
  IF to_regclass('public.financial_counterparty') IS NULL THEN
    RAISE EXCEPTION 'financial_counterparty table does not exist'; END IF;
  SELECT string_agg(c, ', ') INTO missing
  FROM unnest(ARRAY['id','display_name','domain','kind','xero_contact_name','vat_number',
                    'realms','default_entity_id','status','merged_into','source_seed',
                    'first_seen','last_seen']) c
  WHERE c NOT IN (SELECT column_name FROM information_schema.columns
                  WHERE table_name='financial_counterparty');
  IF missing IS NOT NULL THEN RAISE EXCEPTION 'financial_counterparty missing columns: %', missing; END IF;
END $$;

-- RLS enabled
DO $$ BEGIN
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE relname='financial_counterparty') THEN
    RAISE EXCEPTION 'RLS not enabled on financial_counterparty'; END IF;
END $$;

-- RLS is DEFAULT-DENY: the realm_isolation policy must NOT contain a permissive-null branch
DO $$ DECLARE q text; BEGIN
  SELECT qual INTO q FROM pg_policies WHERE tablename='financial_counterparty' AND policyname='realm_isolation';
  IF q IS NULL THEN RAISE EXCEPTION 'realm_isolation policy missing'; END IF;
  IF q ILIKE '%current_setting%IS NULL%' OR q ILIKE '%= ''''%THEN true%' THEN
    RAISE EXCEPTION 'realm_isolation has a permissive-null branch (must be default-deny)'; END IF;
END $$;

-- seed produced rows and EXACTLY one identity per domain (no accidental near-dup merge/dup)
DO $$ DECLARE n int; dups int; BEGIN
  SELECT count(*) INTO n FROM financial_counterparty WHERE source_seed='invoice_domain';
  IF n = 0 THEN RAISE EXCEPTION 'seed produced 0 invoice_domain identities'; END IF;
  SELECT count(*) INTO dups FROM (
    SELECT domain FROM financial_counterparty WHERE domain IS NOT NULL GROUP BY domain HAVING count(*) > 1) d;
  IF dups > 0 THEN RAISE EXCEPTION 'duplicate domain identities: % domains', dups; END IF;
  RAISE NOTICE 'financial_counterparty seeded: % identities', n;
END $$;

-- link column on counterparties exists
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='counterparties' AND column_name='financial_counterparty_id') THEN
    RAISE EXCEPTION 'counterparties.financial_counterparty_id missing'; END IF;
END $$;
