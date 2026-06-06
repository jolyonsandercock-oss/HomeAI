-- V237 — H2: add the standard realm_isolation policy to snag_inbox.
-- snag_inbox had RLS ENABLED but ZERO policies = deny-all for any non-superuser.
-- Harmless today (services connect as postgres superuser → bypass), but it would
-- block all access the moment U249 moves services off superuser. Mirrors the
-- realm_isolation policy already on vendor_category_rules / card_statements.
-- Reversible: DROP POLICY realm_isolation ON public.snag_inbox;
BEGIN;

CREATE POLICY realm_isolation ON public.snag_inbox
  USING (
    CASE
      WHEN current_setting('app.current_realm', true) = 'owner'    THEN true
      WHEN current_setting('app.current_realm', true) = 'work'     THEN realm = ANY (ARRAY['work','shared'])
      WHEN current_setting('app.current_realm', true) = 'personal' THEN realm = ANY (ARRAY['personal','shared'])
      WHEN current_setting('app.current_realm', true) IS NULL
        OR current_setting('app.current_realm', true) = ''         THEN true
      ELSE false
    END
  )
  WITH CHECK (
    CASE
      WHEN current_setting('app.current_realm', true) = 'owner'    THEN true
      WHEN current_setting('app.current_realm', true) = 'work'     THEN realm = ANY (ARRAY['work','shared'])
      WHEN current_setting('app.current_realm', true) = 'personal' THEN realm = ANY (ARRAY['personal','shared'])
      WHEN current_setting('app.current_realm', true) IS NULL
        OR current_setting('app.current_realm', true) = ''         THEN true
      ELSE false
    END
  );

-- snag_inbox had no table grant for the pipeline role either (pre-staging for U249/H5).
GRANT SELECT ON public.snag_inbox TO homeai_pipeline;

COMMIT;
