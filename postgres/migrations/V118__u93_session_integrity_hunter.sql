-- =============================================================================
-- V118 — U93: per-session till-recon integrity hunter
-- =============================================================================
-- Existing hunters cover gaps where a recon row is missing entirely
-- (till_recon_missing, ghost_shift_day). This adds finer-grained checks
-- on rows that DO exist but are obviously incomplete:
--   - Row has cash_counted but z_reading IS NULL    → kind=session_z_missing
--   - Row has cash_counted but card_total IS NULL   → kind=session_card_missing
--   - Row has z_reading > 0 but cash_counted IS NULL → kind=session_count_missing
--
-- Surfaces as mart.exceptions with severity=medium so they show up in
-- /work/actions (severity ≥ medium). Once Jo fills the field, the
-- exception can be resolved manually.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- Findings view
DROP VIEW IF EXISTS v_session_integrity_findings CASCADE;
CREATE VIEW v_session_integrity_findings AS
SELECT
  tr.id, tr.recon_date, tr.site, tr.session,
  tr.z_reading, tr.card_total, tr.cash_counted,
  CASE
    WHEN COALESCE(tr.cash_counted, 0) > 0 AND tr.z_reading IS NULL    THEN 'session_z_missing'
    WHEN COALESCE(tr.z_reading, 0)   > 0 AND tr.card_total IS NULL    THEN 'session_card_missing'
    WHEN COALESCE(tr.z_reading, 0)   > 0 AND tr.cash_counted IS NULL  THEN 'session_count_missing'
    ELSE                                                                    NULL
  END AS finding_kind,
  tr.realm
FROM till_reconciliation tr
WHERE tr.recon_date BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE
  AND tr.recon_date <= CURRENT_DATE
  AND (
    (COALESCE(tr.cash_counted, 0) > 0 AND tr.z_reading IS NULL) OR
    (COALESCE(tr.z_reading, 0)   > 0 AND tr.card_total IS NULL) OR
    (COALESCE(tr.z_reading, 0)   > 0 AND tr.cash_counted IS NULL)
  );

COMMENT ON VIEW v_session_integrity_findings IS
'U93 V118. Till recon rows that have data in some fields but are missing
others (z_reading, card_total, or cash_counted). 30-day window.';

-- Trigger to auto-raise
CREATE OR REPLACE FUNCTION public.till_session_integrity_to_exception()
RETURNS trigger
LANGUAGE plpgsql AS $function$
DECLARE
  v_kind text;
  v_summary text;
BEGIN
  IF NEW.recon_date > CURRENT_DATE THEN RETURN NEW; END IF;

  v_kind := CASE
    WHEN COALESCE(NEW.cash_counted, 0) > 0 AND NEW.z_reading IS NULL  THEN 'session_z_missing'
    WHEN COALESCE(NEW.z_reading, 0)   > 0 AND NEW.card_total IS NULL  THEN 'session_card_missing'
    WHEN COALESCE(NEW.z_reading, 0)   > 0 AND NEW.cash_counted IS NULL THEN 'session_count_missing'
    ELSE NULL END;
  IF v_kind IS NULL THEN RETURN NEW; END IF;

  v_summary := format(
    'Session integrity: %s at %s on %s',
    CASE v_kind
      WHEN 'session_z_missing'     THEN 'z reading missing'
      WHEN 'session_card_missing'  THEN 'card total missing'
      WHEN 'session_count_missing' THEN 'cash count missing'
    END,
    NEW.site, NEW.recon_date
  );

  INSERT INTO mart.exceptions
    (severity, kind, source, site, transaction_date, summary, detail, status, realm)
  VALUES
    ('medium', v_kind, 'till_reconciliation', NEW.site, NEW.recon_date,
     v_summary,
     jsonb_build_object(
       'recon_id', NEW.id,
       'z_reading', NEW.z_reading,
       'card_total', NEW.card_total,
       'cash_counted', NEW.cash_counted),
     'open', COALESCE(NEW.realm, 'work'))
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS trg_till_session_integrity ON till_reconciliation;
CREATE TRIGGER trg_till_session_integrity
AFTER INSERT OR UPDATE OF z_reading, card_total, cash_counted
ON till_reconciliation
FOR EACH ROW EXECUTE FUNCTION till_session_integrity_to_exception();

-- Backfill existing findings as open exceptions
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN SELECT * FROM v_session_integrity_findings LOOP
    INSERT INTO mart.exceptions
      (severity, kind, source, site, transaction_date, summary, detail, status, realm)
    VALUES (
      'medium', r.finding_kind, 'till_reconciliation', r.site, r.recon_date,
      format('Session integrity: %s at %s on %s',
        CASE r.finding_kind
          WHEN 'session_z_missing'     THEN 'z reading missing'
          WHEN 'session_card_missing'  THEN 'card total missing'
          WHEN 'session_count_missing' THEN 'cash count missing'
        END, r.site, r.recon_date),
      jsonb_build_object('recon_id', r.id,
        'z_reading', r.z_reading, 'card_total', r.card_total,
        'cash_counted', r.cash_counted),
      'open', r.realm
    ) ON CONFLICT DO NOTHING;
  END LOOP;
END $$;

COMMIT;
