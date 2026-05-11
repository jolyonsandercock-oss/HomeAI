-- ============================================================
-- HOME AI SYSTEM — Row Level Security Policies
-- ============================================================
-- entity_isolation uses a CASE expression rather than
--   entity_id = current_setting(...)::int OR current_setting(...) = 'all'
-- because PostgreSQL does not guarantee boolean short-circuit, so the
-- ::int cast is evaluated even when the setting is 'all', failing with
-- "invalid input syntax for type integer: 'all'" for every non-superuser
-- session running with app.current_entity='all' (i.e. every system-level
-- write from homeai_pipeline). CASE branches are guaranteed to be skipped.
-- See migrations/V5__fix_rls_policy_expression.sql for the live-DB fix.
--
-- rent_payments is RLS-enabled but has NO policy = deny-all (fail-closed).
-- It has no entity_id column (scopes via tenancy_id → tenancies.entity_id),
-- so it needs a JOIN-based policy before the rent pipeline is built.

ALTER TABLE events                      ENABLE ROW LEVEL SECURITY;
ALTER TABLE emails                      ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoices                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE bank_transactions           ENABLE ROW LEVEL SECURITY;
ALTER TABLE epos_daily_reports          ENABLE ROW LEVEL SECURITY;
ALTER TABLE accommodation_daily_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE till_reconciliation         ENABLE ROW LEVEL SECURITY;
ALTER TABLE rent_payments               ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff                       ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE cashflow_forecast           ENABLE ROW LEVEL SECURITY;

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
    EXECUTE format(
      'CREATE POLICY entity_isolation ON %I USING (%s) WITH CHECK (%s)',
      t, expr, expr
    );
  END LOOP;
END $$;

CREATE POLICY hr_only ON staff USING (current_user = 'homeai_hr');

-- Roles use placeholder passwords — update via Vault after init:
--   ALTER ROLE homeai_pipeline PASSWORD '<vault:secret/postgres>';
CREATE ROLE homeai_pipeline LOGIN PASSWORD 'REPLACE_VIA_VAULT';
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO homeai_pipeline;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO homeai_pipeline;

CREATE ROLE homeai_hr LOGIN PASSWORD 'REPLACE_VIA_VAULT';
GRANT SELECT, INSERT, UPDATE ON staff, holiday_entitlement, holiday_requests,
  training_records, audit_log, events, dead_letter TO homeai_hr;

CREATE ROLE homeai_readonly LOGIN PASSWORD 'REPLACE_VIA_VAULT';
GRANT SELECT ON ALL TABLES IN SCHEMA public TO homeai_readonly;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
REVOKE UPDATE, DELETE ON security_audit_log FROM PUBLIC;
