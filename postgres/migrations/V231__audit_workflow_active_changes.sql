-- V231 — audit n8n workflow active/inactive changes.
-- Gap surfaced 2026-06-05: Invoice Pipeline (P2) was found deactivated with no
-- record of when or why. n8n doesn't log activate/deactivate, so we add a trigger
-- on workflow_entity that writes every active-state flip to audit_log. Captures
-- future UI/API/DB toggles (incl. this session's P2 activation).
--
-- audit_log real columns: pipeline (NOT NULL), action (NOT NULL), record_type,
-- result, ai_parsed jsonb, created_at. The INSERT is wrapped in an exception
-- guard so a failed audit can NEVER break an n8n workflow_entity update (n8n
-- updates that table constantly).
BEGIN;

CREATE OR REPLACE FUNCTION home_ai.audit_workflow_active()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  IF NEW.active IS DISTINCT FROM OLD.active THEN
    BEGIN
      INSERT INTO audit_log(pipeline, action, record_type, result, ai_parsed)
      VALUES ('n8n', 'workflow_active_change', 'workflow',
              CASE WHEN NEW.active THEN 'activated' ELSE 'deactivated' END,
              jsonb_build_object(
                'workflow', NEW.name,
                'workflow_id', NEW.id,
                'from', OLD.active,
                'to', NEW.active,
                'changed_by', current_user));
    EXCEPTION WHEN OTHERS THEN
      NULL;  -- auditing must never break an n8n workflow update
    END;
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_audit_workflow_active ON workflow_entity;
CREATE TRIGGER trg_audit_workflow_active
  AFTER UPDATE ON workflow_entity
  FOR EACH ROW EXECUTE FUNCTION home_ai.audit_workflow_active();

COMMIT;
