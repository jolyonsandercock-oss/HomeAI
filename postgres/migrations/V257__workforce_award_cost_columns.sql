-- =============================================================================
-- V257 — capture Workforce's authoritative base wage cost on workforce_shifts
-- =============================================================================
-- Workforce's /api/v2/shifts?show_costs=true returns `cost` (= award_cost +
-- allowance_cost), the historically-accurate BASE wage (rate-at-the-time x
-- hours, breaks/allowances handled by Workforce). This is more accurate than
-- our trigger, which costs every shift at the employee's *current* staff_meta
-- rate (proven wrong: e.g. user 1866810 is £15/h now, was £13.50/h in Jul-2025).
--
-- These columns are additive + nullable and DO NOT change cost_estimate. They
-- let us capture the accurate base now; on Thursday (once the token has the
-- `settings` scope and we know the real on-cost %) we set
--   cost_estimate := award_cost * (1 + on_cost_pct/100)
-- with leave entries staying NULL/0 so holiday is never double-counted.
-- =============================================================================

BEGIN;

ALTER TABLE workforce_shifts
  ADD COLUMN IF NOT EXISTS award_cost          numeric(12,4),
  ADD COLUMN IF NOT EXISTS allowance_cost      numeric(12,4),
  ADD COLUMN IF NOT EXISTS cost_last_synced_at timestamptz;

COMMENT ON COLUMN workforce_shifts.award_cost IS
  'Workforce base wage cost for the shift (award_interpretation), historically accurate; excludes on-costs. Source: /api/v2/shifts?show_costs=true cost_breakdown.award_cost.';
COMMENT ON COLUMN workforce_shifts.allowance_cost IS
  'Workforce allowance cost component (cost_breakdown.allowance_cost). Usually 0.';
COMMENT ON COLUMN workforce_shifts.cost_last_synced_at IS
  'When award_cost/allowance_cost were last refreshed from Workforce.';

COMMIT;
