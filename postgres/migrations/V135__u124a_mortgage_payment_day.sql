-- =============================================================================
-- V135 — U124-A: mortgage_accounts.payment_day_of_month + v_obligations fix
-- =============================================================================
-- v_obligations (V133) used EXTRACT(DAY FROM opened_date) to compute the
-- next monthly DD date. But opened_date is NULL on every row, so no
-- mortgage payments ever surfaced.
--
-- Fix: add explicit payment_day_of_month column. Backfill what's known.
-- Rebuild the mortgage branch of v_obligations.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

ALTER TABLE mortgage_accounts
  ADD COLUMN IF NOT EXISTS payment_day_of_month INTEGER
    CHECK (payment_day_of_month BETWEEN 1 AND 28);

COMMENT ON COLUMN mortgage_accounts.payment_day_of_month IS
'U124-A V135. Day-of-month the monthly DD goes out. Capped at 28 so the
"next DD" calc works for every month including February.';

-- Backfill from known DD day for Principality 295905-02
-- (Jo confirmed 16th of the month, monthly £2,263.58)
UPDATE mortgage_accounts
   SET payment_day_of_month = 16
 WHERE lender = 'Principality Commercial'
   AND account_ref = '295905-02'
   AND payment_day_of_month IS NULL;

-- Rebuild v_obligations with the new column
DROP VIEW IF EXISTS v_obligations_due_3d CASCADE;
DROP VIEW IF EXISTS v_obligations CASCADE;

CREATE VIEW v_obligations AS
-- Mortgages — DD on payment_day_of_month each month, picking next future occurrence
SELECT
  'mortgage'::text                              AS source,
  ('mortgage:' || id::text)                     AS source_ref,
  lender || ' ' || account_ref                  AS label,
  -- Compute the next future DD date from today:
  CASE
    WHEN EXTRACT(DAY FROM CURRENT_DATE)::int <= payment_day_of_month
    THEN (DATE_TRUNC('month', CURRENT_DATE)
          + ((payment_day_of_month - 1) * INTERVAL '1 day'))::date
    ELSE (DATE_TRUNC('month', CURRENT_DATE + INTERVAL '1 month')
          + ((payment_day_of_month - 1) * INTERVAL '1 day'))::date
  END                                           AS due_date,
  'mortgage payment'::text                      AS kind,
  '£' || monthly_payment::text                  AS notes,
  'work'::text                                  AS realm
FROM mortgage_accounts
WHERE closed_date IS NULL
  AND monthly_payment IS NOT NULL
  AND payment_day_of_month IS NOT NULL
UNION ALL
-- Vehicles — MOT
SELECT 'vehicle', 'vehicle:' || id::text || ':mot',
       registration || ' MOT', mot_due::date, 'vehicle MOT',
       make_model, realm
  FROM vehicles WHERE mot_due IS NOT NULL
UNION ALL
SELECT 'vehicle', 'vehicle:' || id::text || ':insurance',
       registration || ' insurance', insurance_renewal::date, 'vehicle insurance',
       make_model, realm
  FROM vehicles WHERE insurance_renewal IS NOT NULL
UNION ALL
SELECT 'vehicle', 'vehicle:' || id::text || ':tax',
       registration || ' road tax', road_tax_due::date, 'vehicle road tax',
       make_model, realm
  FROM vehicles WHERE road_tax_due IS NOT NULL
UNION ALL
SELECT 'vehicle', 'vehicle:' || id::text || ':service',
       registration || ' service', service_due_date::date, 'vehicle service',
       make_model, realm
  FROM vehicles WHERE service_due_date IS NOT NULL
UNION ALL
SELECT 'compliance', 'compliance:' || id::text,
       property_id::text || ' ' || compliance_type, expiry_date,
       'compliance expiry', compliance_type, 'work'
  FROM property_compliance WHERE expiry_date IS NOT NULL
UNION ALL
SELECT 'child', 'child:' || id::text,
       COALESCE(summary, event_type), COALESCE(deadline::date, event_date::date),
       'child event', COALESCE(summary, ''), realm
  FROM child_events
 WHERE COALESCE(deadline, event_date) IS NOT NULL
   AND status NOT IN ('done','cancelled','dismissed');

COMMENT ON VIEW v_obligations IS
'U121 V133 + U124-A V135. All dated obligations. Mortgage payments now
use mortgage_accounts.payment_day_of_month.';

CREATE VIEW v_obligations_due_3d AS
SELECT * FROM v_obligations
 WHERE due_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 3
 ORDER BY due_date, source, label;

COMMIT;
