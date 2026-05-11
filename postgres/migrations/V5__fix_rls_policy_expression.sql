-- V5__fix_rls_policy_expression.sql
-- The original entity_isolation policy expression was:
--   entity_id = current_setting('app.current_entity', true)::int
--   OR current_setting('app.current_entity', true) = 'all'
-- PostgreSQL does not guarantee boolean short-circuit, so the ::int cast is
-- evaluated even when the setting is 'all', failing with
-- "invalid input syntax for type integer: 'all'". This blocked any
-- non-superuser INSERT from a session running with app.current_entity='all'
-- (i.e. every system-level write from homeai_pipeline).
--
-- Fix: use CASE WHEN, which IS guaranteed to skip non-matching branches.
-- Also adds explicit WITH CHECK so future readers don't have to know about
-- the implicit USING-fallback rule.
--
-- Applies to all 10 entity-scoped tables that use entity_isolation.
-- rent_payments still excluded (no entity_id column — see V3 comment).
-- Idempotent: drops then recreates.

\set ON_ERROR_STOP on

DO $$
DECLARE
  t TEXT;
  expr CONSTANT TEXT := $expr$
    CASE
      WHEN current_setting('app.current_entity', true) = 'all' THEN TRUE
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'
           THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE FALSE
    END
  $expr$;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'events', 'emails', 'invoices', 'bank_transactions',
    'documents', 'cashflow_forecast',
    'epos_daily_reports', 'accommodation_daily_reports',
    'till_reconciliation', 'staff'
  ]
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS entity_isolation ON %I', t);
    EXECUTE format(
      'CREATE POLICY entity_isolation ON %I USING (%s) WITH CHECK (%s)',
      t, expr, expr
    );
    RAISE NOTICE 'rebuilt entity_isolation on %', t;
  END LOOP;
END $$;

-- Verification: 10 entity_isolation policies, all using CASE expression.
SELECT count(*) AS entity_isolation_policies
  FROM pg_policies
 WHERE schemaname = 'public' AND policyname = 'entity_isolation';

SELECT count(*) AS policies_using_case
  FROM pg_policies
 WHERE schemaname = 'public'
   AND policyname = 'entity_isolation'
   AND qual LIKE '%CASE%';
