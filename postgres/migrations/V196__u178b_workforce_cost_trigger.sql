-- =============================================================================
-- V196 — U178b: auto-populate workforce_shifts.cost_estimate on INSERT/UPDATE
-- =============================================================================
-- Tanda's u29 sync writes shifts with NULL cost_estimate. Pay rates live in
-- staff_meta (populated by u32-workforce-pay-sync). This trigger joins them
-- so cost_estimate is always populated on INSERT/UPDATE.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.workforce_shifts_compute_cost()
 RETURNS TRIGGER
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_rate_pence  INTEGER;
  v_on_cost_pct NUMERIC;
BEGIN
  IF NEW.hours_worked IS NULL OR NEW.cost_estimate IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT hourly_rate_pence, on_cost_pct
    INTO v_rate_pence, v_on_cost_pct
    FROM staff_meta
   WHERE user_external_id = NEW.user_external_id;

  IF v_rate_pence IS NOT NULL AND v_rate_pence > 0 THEN
    NEW.cost_estimate := ROUND(
      NEW.hours_worked * (v_rate_pence / 100.0) * (1 + COALESCE(v_on_cost_pct, 12.5) / 100.0),
      2
    );
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_workforce_shifts_cost ON workforce_shifts;
CREATE TRIGGER trg_workforce_shifts_cost
  BEFORE INSERT OR UPDATE OF hours_worked, user_external_id
  ON workforce_shifts
  FOR EACH ROW
  EXECUTE FUNCTION public.workforce_shifts_compute_cost();

COMMIT;
