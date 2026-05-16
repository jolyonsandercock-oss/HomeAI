-- =============================================================================
-- V105 — U84 Phase 3: /work/staff + /work/email KPI views
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

DROP VIEW IF EXISTS v_work_staff_kpis;
CREATE VIEW v_work_staff_kpis AS
SELECT
  (SELECT COUNT(*) FROM mart.v_ghost_shifts)                          AS ghost_shift_days,
  (SELECT MAX(start_time) FROM workforce_shifts)                      AS last_shift_seen,
  (SELECT COALESCE(SUM(hours), 0) FROM v_daily_labour_by_team
     WHERE report_date >= CURRENT_DATE - 7)                            AS hours_7d,
  (SELECT COALESCE(SUM(cost_with_oncost), 0) FROM v_daily_labour_by_team
     WHERE report_date >= CURRENT_DATE - 7)                            AS cost_7d,
  (SELECT COUNT(DISTINCT (team || department_name)) FROM v_daily_labour_by_team
     WHERE report_date >= CURRENT_DATE - 7)                            AS teams_active_7d;

DROP VIEW IF EXISTS v_work_email_kpis;
CREATE VIEW v_work_email_kpis AS
SELECT
  (SELECT COUNT(*) FROM v_email_tasks_open)                           AS tasks_open,
  (SELECT COUNT(*) FROM bot_instructions WHERE status='pending')      AS instructions_pending,
  (SELECT MAX(received_at) FROM bot_instructions)                     AS last_instruction_at;

COMMENT ON VIEW v_work_staff_kpis IS 'U84 /work/staff KPI row (V105).';
COMMENT ON VIEW v_work_email_kpis IS 'U84 /work/email KPI row (V105).';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'homeai_pipeline') THEN
    EXECUTE 'GRANT SELECT ON v_work_staff_kpis, v_work_email_kpis TO homeai_pipeline';
  END IF;
END$$;

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES
  ('work_staff_kpis','U84 /work/staff — staff KPI row',
   'SELECT * FROM v_work_staff_kpis',
   'Ghost shifts, last shift seen, 7d labour hours/cost/teams',
   'u84-phase3','owner',1, ARRAY['staff overview','labour stats'],
   now(),'u84-phase3'),
  ('work_email_kpis','U84 /work/email — email KPI row',
   'SELECT * FROM v_work_email_kpis',
   'Open email tasks, pending instructions, last instruction timestamp',
   'u84-phase3','owner',1, ARRAY['email overview'],
   now(),'u84-phase3')
ON CONFLICT (slug) DO UPDATE
  SET sql_template=EXCLUDED.sql_template, approved_at=now(), approved_by='u84-phase3';

COMMIT;
