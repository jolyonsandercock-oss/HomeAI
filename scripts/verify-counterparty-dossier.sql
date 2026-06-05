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
-- Financials: for a linked counterparty, the function's total must equal an
-- independent recompute over the SAME cleaned-name join (no double counting).
DO $$
DECLARE cp_id bigint; fin jsonb; indep numeric;
BEGIN
  SELECT id INTO cp_id FROM counterparties
   WHERE linked_vendor IS NOT NULL ORDER BY signal_score DESC LIMIT 1;
  IF cp_id IS NULL THEN RAISE EXCEPTION 'no linked counterparty to test financials'; END IF;
  fin := home_ai.counterparty_financials(cp_id);
  SELECT COALESCE(sum(vil.line_gross),0) INTO indep
    FROM counterparties c
    JOIN vendor_invoice_inbox vii ON home_ai.clean_vendor_name(vii.vendor_name) = c.linked_vendor
    JOIN vendor_invoice_lines vil ON vil.invoice_id = vii.id
   WHERE c.id = cp_id;
  IF (fin->>'total_invoiced')::numeric <> indep THEN
    RAISE EXCEPTION 'financials total % <> independent recompute %', fin->>'total_invoiced', indep;
  END IF;
  IF NOT (fin ? 'n_invoices' AND fin ? 'last_invoice_date' AND fin->>'currency' = 'GBP') THEN
    RAISE EXCEPTION 'financials jsonb missing expected keys';
  END IF;
END $$;
-- A distilled dossier's stored financials must equal a fresh DB recompute
-- (LLM never sets numbers).
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad FROM counterparty_dossier d
   WHERE (d.financials->>'total_invoiced') IS DISTINCT FROM
         (home_ai.counterparty_financials(d.counterparty_id)->>'total_invoiced');
  IF bad > 0 THEN RAISE EXCEPTION '% dossiers have financials != DB recompute', bad; END IF;
END $$;

-- Every citation must resolve to a real email id.
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad FROM counterparty_dossier d
   CROSS JOIN LATERAL unnest(d.citations) cid
   LEFT JOIN emails e ON e.id = cid
   WHERE e.id IS NULL;
  IF bad > 0 THEN RAISE EXCEPTION '% dangling citations (no such email)', bad; END IF;
END $$;

-- Cultural memory is owner-only: a work-realm reader sees ZERO dossiers.
DO $$
DECLARE seen int;
BEGIN
  PERFORM set_config('app.current_realm','work',true);
  SET LOCAL ROLE homeai_readonly;
  SELECT count(*) INTO seen FROM counterparty_dossier;
  RESET ROLE;
  IF seen <> 0 THEN RAISE EXCEPTION 'work realm sees % dossiers (owner-only expected)', seen; END IF;
END $$;
