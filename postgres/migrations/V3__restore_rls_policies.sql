-- V3__restore_rls_policies.sql
-- Restores the 7 entity_isolation policies the original rls-policies.sql DO
-- block failed to install at init time. Without these, RLS-enabled tables
-- with no policies deny-all for non-superusers, breaking every pipeline that
-- writes as homeai_pipeline (n8n, model-evaluator, etc.).
--
-- Discovered: 2026-05-02 while running Step 9b verification gate.
-- The 3 tables that already have policies (epos_daily_reports,
-- accommodation_daily_reports, till_reconciliation) are skipped.
--
-- Idempotent: safe to re-run. Apply:
--   docker exec -i homeai-postgres psql -U postgres -d homeai \
--     -f - < postgres/migrations/V3__restore_rls_policies.sql

\set ON_ERROR_STOP on

DO $$
DECLARE
  t TEXT;
BEGIN
  -- rent_payments excluded: has no entity_id column (scopes via tenancy_id
  -- → tenancies.entity_id). Stays RLS-enabled with no policy = deny-all,
  -- which is fail-closed and safe. Revisit when building the rent pipeline
  -- (needs JOIN-based policy or a denormalised entity_id column).
  FOREACH t IN ARRAY ARRAY['events', 'emails', 'invoices', 'bank_transactions',
                           'documents', 'cashflow_forecast']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public'
         AND tablename = t
         AND policyname = 'entity_isolation'
    ) THEN
      EXECUTE format($f$
        CREATE POLICY entity_isolation ON %I
          USING (CASE
            WHEN current_setting('app.current_entity', true) = 'all' THEN true
            WHEN current_setting('app.current_entity', true) ~ '^\d+$'
              THEN entity_id = current_setting('app.current_entity', true)::integer
            ELSE false
          END)
          WITH CHECK (CASE
            WHEN current_setting('app.current_entity', true) = 'all' THEN true
            WHEN current_setting('app.current_entity', true) ~ '^\d+$'
              THEN entity_id = current_setting('app.current_entity', true)::integer
            ELSE false
          END)
      $f$, t);
      RAISE NOTICE 'created entity_isolation policy on %', t;
    ELSE
      RAISE NOTICE 'entity_isolation policy already exists on %, skipping', t;
    END IF;
  END LOOP;
END $$;

-- Verification: should return 10 (4 pre-existing + 6 restored).
SELECT count(*) AS entity_isolation_policies
  FROM pg_policies
 WHERE schemaname = 'public' AND policyname = 'entity_isolation';
