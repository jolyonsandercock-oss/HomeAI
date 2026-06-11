-- =============================================================================
-- V262 — on-cost the workforce labour figures to match the Workforce report
-- =============================================================================
-- Jo's Workforce "on-cost report" (Fri 1–Sun 31 May 2026) shows Timesheet Cost
-- (on-costed, inc. allowances, exc. leave) = £44,447.24. Our base wage for the
-- same month (SUM(award_cost) of worked shifts, exc. leave) = £35,019.84.
--   on-cost multiplier = 44447.24 / 35019.84 = 1.26920  → +26.92%
-- This bundles holiday accrual + employer NI + pension (+ the allowances our
-- award_cost base omits) into one factor anchored to the report. The Workforce
-- API exposes NO on-cost field even with the settings scope (verified 2026-06-11),
-- so this empirical anchor is the source-of-truth match.
--
-- cost_estimate = award_cost × (1 + on_cost_pct/100) for WORKED shifts.
-- Leave entries (award_cost NULL) stay NULL/£0 — holiday is accrued onto worked
-- hours via the uplift, never double-counted when taken (Jo's model).
-- on_cost_pct lives in static_context so it's tunable without a migration.
-- =============================================================================

BEGIN;

-- ── 1. tunable on-cost rate ─────────────────────────────────────────────────
INSERT INTO static_context(key, value)
VALUES ('workforce.on_cost_pct', to_jsonb(26.92::numeric))
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

-- ── 2. recompute trigger: cost_estimate from award_cost × on-cost ───────────
CREATE OR REPLACE FUNCTION public.workforce_shifts_compute_cost()
 RETURNS TRIGGER
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_pct         numeric;
  v_rate_pence  integer;
BEGIN
  IF NEW.cost_estimate IS NOT NULL THEN
    RETURN NEW;  -- explicit value (e.g. backfill) wins
  END IF;

  SELECT COALESCE((value #>> '{}')::numeric, 26.92)
    INTO v_pct FROM static_context WHERE key = 'workforce.on_cost_pct';
  v_pct := COALESCE(v_pct, 26.92);

  -- Preferred: Workforce's own base wage (award_cost) × on-cost.
  IF NEW.award_cost IS NOT NULL THEN
    NEW.cost_estimate := ROUND(NEW.award_cost * (1 + v_pct/100.0), 2);
    RETURN NEW;
  END IF;

  -- Fallback (no award_cost yet): staff_meta rate × hours × on-cost.
  IF NEW.hours_worked IS NOT NULL THEN
    SELECT hourly_rate_pence INTO v_rate_pence
      FROM staff_meta WHERE user_external_id = NEW.user_external_id;
    IF v_rate_pence IS NOT NULL AND v_rate_pence > 0 THEN
      NEW.cost_estimate := ROUND(
        NEW.hours_worked * (v_rate_pence/100.0) * (1 + v_pct/100.0), 2);
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_workforce_shifts_cost ON workforce_shifts;
CREATE TRIGGER trg_workforce_shifts_cost
  BEFORE INSERT OR UPDATE OF hours_worked, user_external_id, award_cost
  ON workforce_shifts
  FOR EACH ROW
  EXECUTE FUNCTION public.workforce_shifts_compute_cost();

-- ── 3. backfill all worked shifts to award_cost × on-cost ───────────────────
UPDATE workforce_shifts
   SET cost_estimate = ROUND(award_cost * (1 + 26.92/100.0), 2)
 WHERE award_cost IS NOT NULL;

-- ── 4. assert May 2026 reproduces the report (£44,447.24 ± rounding) ────────
DO $$
DECLARE may_total numeric;
BEGIN
  SELECT SUM(cost_estimate) INTO may_total
    FROM workforce_shifts
   WHERE shift_date BETWEEN '2026-05-01' AND '2026-05-31'
     AND hours_worked IS NOT NULL AND award_cost IS NOT NULL;
  IF may_total IS NULL OR may_total < 44440 OR may_total > 44455 THEN
    RAISE EXCEPTION 'V262: May on-costed total % does not match report £44,447.24', may_total;
  END IF;
  RAISE NOTICE 'V262: May on-costed labour = % (report £44,447.24)', may_total;
END $$;

COMMIT;
