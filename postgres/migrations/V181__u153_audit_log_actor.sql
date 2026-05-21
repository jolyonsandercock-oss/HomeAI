-- =============================================================================
-- V181 — U153 T3: add actor identity columns to audit_log
-- =============================================================================
-- Today audit_log captures the pipeline + ai_worker but not the human actor.
-- Once staff are on the system (U153), every action needs to be attributable
-- to the specific user, not just "system".
--
-- New columns:
--   actor_user  — the Remote-User header value from Authelia forward_auth
--                 (e.g. 'helen', 'jo', 'sandwich-staff-1'). NULL for
--                 system / pipeline actions that aren't triggered by a UI hit.
--   actor_role  — the primary group from Remote-Groups (e.g. 'manager',
--                 'floor-staff', 'kitchen-staff', 'owner'). NULL when
--                 actor_user is NULL.
--   actor_ip    — the X-Forwarded-For value (best-effort source IP) for
--                 forensics. NULL when actor_user is NULL.
--
-- Backwards compatible: all columns nullable; existing INSERTs unaffected.
-- =============================================================================

BEGIN;

ALTER TABLE audit_log
  ADD COLUMN IF NOT EXISTS actor_user TEXT,
  ADD COLUMN IF NOT EXISTS actor_role TEXT,
  ADD COLUMN IF NOT EXISTS actor_ip   TEXT;

CREATE INDEX IF NOT EXISTS idx_audit_log_actor_user
  ON audit_log (actor_user, created_at DESC)
  WHERE actor_user IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_audit_log_actor_role
  ON audit_log (actor_role, created_at DESC)
  WHERE actor_role IS NOT NULL;

-- New slug to surface per-actor activity on the Admin page.
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'audit_log_by_actor_7d',
  'Audit log — by actor, last 7 days',
  'Per-staff action counts: who did what across the dashboard. Drives multi-user accountability.',
  E'SELECT actor_user, actor_role, count(*) AS actions,
           array_agg(DISTINCT action ORDER BY action) AS action_kinds,
           max(created_at) AS latest_action
      FROM audit_log
     WHERE actor_user IS NOT NULL
       AND created_at > NOW() - INTERVAL ''7 days''
     GROUP BY actor_user, actor_role
     ORDER BY actions DESC',
  '{}', 'shared', true, NOW(), 'u153', 'u153'
) ON CONFLICT (slug) DO UPDATE
  SET sql_template = EXCLUDED.sql_template, realm = EXCLUDED.realm, approved_at = NOW();

COMMIT;
