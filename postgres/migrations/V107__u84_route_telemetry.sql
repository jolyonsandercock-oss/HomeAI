-- =============================================================================
-- V107 — U84 Phase 7: page-view telemetry summary view + slug
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

DROP VIEW IF EXISTS v_route_telemetry_7d;
CREATE VIEW v_route_telemetry_7d AS
SELECT
  ai_parsed->>'path'                        AS path,
  COUNT(*)                                   AS hits,
  COUNT(DISTINCT (ai_parsed->>'ua'))         AS distinct_ua,
  MAX(created_at)                            AS last_seen,
  MIN(created_at)                            AS first_seen
FROM audit_log
WHERE action = 'page_view'
  AND created_at > now() - INTERVAL '7 days'
GROUP BY ai_parsed->>'path'
ORDER BY hits DESC;

COMMENT ON VIEW v_route_telemetry_7d IS
'U84 page-view counts over last 7 days (V107). Drives decommissioning
decisions: a URL with 0 hits in 7d is safe to retire.';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'homeai_pipeline') THEN
    EXECUTE 'GRANT SELECT ON v_route_telemetry_7d TO homeai_pipeline';
  END IF;
END$$;

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES (
  'route_telemetry_7d',
  'U84 page-view counts · 7d',
  'SELECT * FROM v_route_telemetry_7d LIMIT 50',
  'Page-view hits per route in last 7 days. Drives decommissioning decisions.',
  'u84-phase7','owner',1, ARRAY['route stats','page views'],
  now(),'u84-phase7'
) ON CONFLICT (slug) DO UPDATE
  SET sql_template=EXCLUDED.sql_template, approved_at=now(), approved_by='u84-phase7';

COMMIT;
