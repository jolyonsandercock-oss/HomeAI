\set ON_ERROR_STOP on
DO $$ BEGIN
  IF to_regclass('public.counterparty_dossier') IS NULL THEN
    RAISE EXCEPTION 'counterparty_dossier table does not exist';
  END IF;
END $$;
DO $$
DECLARE missing text;
BEGIN
  SELECT string_agg(c, ', ') INTO missing
  FROM unnest(ARRAY['id','counterparty_id','summary','key_facts','financials',
                    'open_threads','people','citations','model','realms',
                    'distilled_through','generated_at']) AS c
  WHERE c NOT IN (SELECT column_name FROM information_schema.columns
                  WHERE table_name='counterparty_dossier');
  IF missing IS NOT NULL THEN RAISE EXCEPTION 'dossier missing columns: %', missing; END IF;
END $$;
DO $$ BEGIN
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE relname='counterparty_dossier') THEN
    RAISE EXCEPTION 'RLS not enabled on counterparty_dossier';
  END IF;
  IF home_ai.clean_vendor_name('"HostPresto!" <noreply@hostpresto.com>') <> 'HostPresto!' THEN
    RAISE EXCEPTION 'clean_vendor_name did not strip the address/quotes';
  END IF;
END $$;
