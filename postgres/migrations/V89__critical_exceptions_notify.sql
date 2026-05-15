-- =============================================================================
-- V89 — critical-exception NOTIFY → immediate Telegram (U71 T2)
-- =============================================================================
-- Every INSERT into mart.exceptions with severity='critical' fires
-- pg_notify('telegram_immediate', <json>). The critical-listener service
-- (services/critical-listener/) LISTENs and forwards to Telegram via the
-- shared bot. Non-critical severities never trigger — the morning digest
-- already covers them.
--
-- Payload shape:
--   { id, kind, source, site, summary, raised_at }
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

CREATE OR REPLACE FUNCTION mart.notify_critical_exception()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.severity = 'critical' THEN
        PERFORM pg_notify(
            'telegram_immediate',
            json_build_object(
                'id',        NEW.id,
                'kind',      NEW.kind,
                'source',    NEW.source,
                'site',      NEW.site,
                'summary',   NEW.summary,
                'raised_at', NEW.raised_at
            )::text
        );
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_critical_notify ON mart.exceptions;
CREATE TRIGGER trg_critical_notify
AFTER INSERT ON mart.exceptions
FOR EACH ROW
EXECUTE FUNCTION mart.notify_critical_exception();

COMMIT;
