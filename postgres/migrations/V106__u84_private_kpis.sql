-- =============================================================================
-- V106 — U84 Phase 4: /private/* KPI views
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

DROP VIEW IF EXISTS v_private_family_kpis;
CREATE VIEW v_private_family_kpis AS
SELECT
  (SELECT COUNT(*) FROM children)                                     AS children_count,
  (SELECT COUNT(*) FROM child_events
     WHERE event_date >= CURRENT_DATE
       AND event_date <= CURRENT_DATE + 30)                            AS child_events_30d,
  (SELECT COUNT(*) FROM v_calendar_upcoming
     WHERE start_at >= now() AND start_at <= now() + INTERVAL '7 days') AS calendar_7d,
  (SELECT COUNT(*) FROM medical_history
     WHERE event_date >= CURRENT_DATE - 90)                            AS medical_recent_90d;

DROP VIEW IF EXISTS v_private_docs_kpis;
CREATE VIEW v_private_docs_kpis AS
SELECT
  (SELECT COUNT(*) FROM v_mortgage_summary WHERE active = true)         AS mortgages_active,
  (SELECT COUNT(*) FROM v_mortgage_summary WHERE active = false)        AS mortgages_closed,
  (SELECT COUNT(*) FROM vehicles)                                       AS vehicles_count,
  (SELECT COUNT(*) FROM v_documents_expiry_due
     WHERE expiry_date IS NOT NULL
       AND (expiry_date - CURRENT_DATE) BETWEEN 0 AND 60
       AND COALESCE(realm, 'family') = 'family')                        AS docs_expiring_60d;

COMMENT ON VIEW v_private_family_kpis IS 'U84 /private/family KPI row (V106).';
COMMENT ON VIEW v_private_docs_kpis IS 'U84 /private/docs KPI row (V106).';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'homeai_pipeline') THEN
    EXECUTE 'GRANT SELECT ON v_private_family_kpis, v_private_docs_kpis TO homeai_pipeline';
  END IF;
END$$;

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES
  ('private_family_kpis','U84 /private/family KPI row',
   'SELECT * FROM v_private_family_kpis',
   'Children count, events 30d, calendar 7d, medical 90d',
   'u84-phase4','owner',1, ARRAY['family overview'],
   now(),'u84-phase4'),
  ('private_docs_kpis','U84 /private/docs KPI row',
   'SELECT * FROM v_private_docs_kpis',
   'Mortgages active/closed, vehicles, docs expiring 60d',
   'u84-phase4','owner',1, ARRAY['private docs'],
   now(),'u84-phase4')
ON CONFLICT (slug) DO UPDATE
  SET sql_template=EXCLUDED.sql_template, approved_at=now(), approved_by='u84-phase4';

COMMIT;
