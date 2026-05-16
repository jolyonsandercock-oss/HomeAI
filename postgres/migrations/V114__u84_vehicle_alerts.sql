-- =============================================================================
-- V114 — U84: vehicle date alerts in the action queue
-- =============================================================================
-- Today's audit found 3 vehicle dates inside 30 days that surface nowhere:
--   WF14FNP Seat Alhambra  road tax overdue 15 days   (2026-05-01)
--   WF14FNP Seat Alhambra  insurance due in 5 days    (2026-05-21)
--   50AHJ   Mercedes 500SL road tax due in 4 days     (2026-05-20)
--
-- Fix: v_vehicle_alerts view + UNION into v_action_queue. Now they show
-- up in /private/actions, /work/actions (with realm filter), and the
-- "Open actions" count tile.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

DROP VIEW IF EXISTS v_vehicle_alerts CASCADE;
CREATE VIEW v_vehicle_alerts AS
WITH per_kind AS (
  SELECT id, registration, make_model, 'mot' AS kind, mot_due AS due_date
    FROM vehicles WHERE mot_due IS NOT NULL
  UNION ALL
  SELECT id, registration, make_model, 'insurance', insurance_renewal
    FROM vehicles WHERE insurance_renewal IS NOT NULL
  UNION ALL
  SELECT id, registration, make_model, 'road_tax',  road_tax_due
    FROM vehicles WHERE road_tax_due IS NOT NULL
  UNION ALL
  SELECT id, registration, make_model, 'service',   service_due_date
    FROM vehicles WHERE service_due_date IS NOT NULL
)
SELECT
  id                                              AS vehicle_id,
  registration,
  make_model,
  kind,
  due_date,
  (due_date - CURRENT_DATE)::int                   AS days_to_due,
  CASE
    WHEN due_date < CURRENT_DATE              THEN 'high'    -- overdue
    WHEN due_date - CURRENT_DATE <= 7         THEN 'high'    -- this week
    WHEN due_date - CURRENT_DATE <= 30        THEN 'medium'  -- this month
    WHEN due_date - CURRENT_DATE <= 60        THEN 'low'
    ELSE                                           NULL
  END                                              AS severity
FROM per_kind
WHERE due_date <= CURRENT_DATE + 60;

COMMENT ON VIEW v_vehicle_alerts IS
'U84 V114. Vehicle MOT/insurance/road tax/service dates due inside 60d.';

-- Replace v_action_queue to include vehicle alerts.
DROP VIEW IF EXISTS v_action_queue CASCADE;
CREATE VIEW v_action_queue AS

-- Open exceptions (mart.exceptions)
SELECT
  'exception'::text                                                           AS source,
  e.id::text                                                                  AS ref,
  e.severity::text                                                            AS severity,
  e.kind::text                                                                AS kind,
  COALESCE(e.summary, e.kind)::text                                           AS title,
  COALESCE(e.transaction_date, e.raised_at::date)                             AS age_date,
  GREATEST(0, (CURRENT_DATE - COALESCE(e.transaction_date, e.raised_at::date))::int) AS age_days,
  e.realm::text                                                               AS realm,
  e.detail                                                                    AS extra
FROM mart.exceptions e
WHERE e.status = 'open'
  AND e.severity IN ('critical','high','medium')

UNION ALL

-- Invoices awaiting review
SELECT
  'invoice_review'::text                                                      AS source,
  v.id::text                                                                  AS ref,
  CASE
    WHEN COALESCE(v.amount_seen,0) >= 500 THEN 'medium'
    ELSE                                       'low'
  END::text                                                                   AS severity,
  'invoice_needs_review'::text                                                AS kind,
  COALESCE(v.vendor_name, v.subject, 'Unknown vendor')::text                  AS title,
  COALESCE(v.received_at::date, CURRENT_DATE)                                 AS age_date,
  GREATEST(0, (CURRENT_DATE - COALESCE(v.received_at::date, CURRENT_DATE))::int) AS age_days,
  COALESCE(v.realm, 'work')::text                                             AS realm,
  jsonb_build_object(
    'amount',  v.amount_seen,
    'vendor',  v.vendor_name,
    'subject', v.subject
  )                                                                           AS extra
FROM vendor_invoice_inbox v
WHERE v.status = 'needs_review'

UNION ALL

-- Pending bot instructions
SELECT
  'bot_instruction'::text                                                     AS source,
  b.id::text                                                                  AS ref,
  'low'::text                                                                 AS severity,
  'instruction_pending'::text                                                 AS kind,
  COALESCE(LEFT(b.raw_subject, 120), 'Pending instruction')::text             AS title,
  COALESCE(b.received_at::date, CURRENT_DATE)                                 AS age_date,
  GREATEST(0, (CURRENT_DATE - COALESCE(b.received_at::date, CURRENT_DATE))::int) AS age_days,
  COALESCE(b.realm, 'work')::text                                             AS realm,
  jsonb_build_object('lane', b.lane)                                          AS extra
FROM bot_instructions b
WHERE b.status = 'pending'

UNION ALL

-- Document expiries (existing path)
SELECT
  'document_expiry'::text                                                     AS source,
  d.id::text                                                                  AS ref,
  CASE
    WHEN (d.expiry_date - CURRENT_DATE) < 14 THEN 'high'
    WHEN (d.expiry_date - CURRENT_DATE) < 30 THEN 'medium'
    ELSE                                          'low'
  END::text                                                                   AS severity,
  'document_expiring'::text                                                   AS kind,
  COALESCE(d.title, d.category, 'Document')::text                             AS title,
  d.expiry_date                                                               AS age_date,
  GREATEST(0, (d.expiry_date - CURRENT_DATE)::int)                            AS age_days,
  COALESCE(d.realm, 'work')::text                                             AS realm,
  jsonb_build_object('expiry', d.expiry_date, 'category', d.category)         AS extra
FROM v_documents_expiry_due d
WHERE d.expiry_date IS NOT NULL
  AND (d.expiry_date - CURRENT_DATE) BETWEEN -7 AND 60

UNION ALL

-- Vehicle alerts (V114)
SELECT
  'vehicle_alert'::text                                                       AS source,
  (va.vehicle_id || ':' || va.kind)::text                                     AS ref,
  va.severity::text                                                           AS severity,
  ('vehicle_' || va.kind)::text                                               AS kind,
  CASE
    WHEN va.days_to_due < 0
      THEN va.registration || ' ' || va.kind || ' overdue (' || va.due_date || ')'
    ELSE va.registration || ' ' || va.kind || ' due ' || va.due_date
  END                                                                         AS title,
  va.due_date                                                                 AS age_date,
  CASE WHEN va.days_to_due < 0 THEN ABS(va.days_to_due) ELSE 0 END            AS age_days,
  'family'::text                                                              AS realm,
  jsonb_build_object(
    'vehicle_id', va.vehicle_id,
    'registration', va.registration,
    'make_model', va.make_model,
    'kind', va.kind,
    'due_date', va.due_date,
    'days_to_due', va.days_to_due
  )                                                                           AS extra
FROM v_vehicle_alerts va
WHERE va.severity IS NOT NULL;

COMMENT ON VIEW v_action_queue IS
'U84 unified action feed (V114). 5 sources: mart.exceptions,
vendor_invoice_inbox needs_review, bot_instructions, v_documents_expiry_due,
v_vehicle_alerts.';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'homeai_pipeline') THEN
    EXECUTE 'GRANT SELECT ON v_vehicle_alerts TO homeai_pipeline';
  END IF;
END$$;

-- Dropping v_action_queue with CASCADE also drops v_today_kpis_* (which
-- reference it). Recreate them so a fresh schema apply (V101→…→V114)
-- doesn't end up missing them.
CREATE OR REPLACE VIEW v_today_kpis_work AS
SELECT
  (SELECT COALESCE(SUM(balance), 0) FROM v_account_balances_now WHERE realm = 'work')      AS cash_on_hand,
  (SELECT COUNT(*) FROM v_action_queue
     WHERE realm IN ('work','shared')
       AND severity IN ('critical','high','medium'))                                       AS open_actions_count,
  (SELECT COUNT(*) FROM v_action_queue
     WHERE realm IN ('work','shared')
       AND severity = 'critical')                                                          AS critical_actions_count,
  (SELECT COUNT(*) FROM accommodation_bookings
     WHERE checkin_date = CURRENT_DATE
       AND status IN ('confirmed','deposit_paid','paid','active')
       AND realm = 'work')                                                                 AS bookings_today,
  (SELECT COALESCE(SUM(gross_amount), 0) FROM accommodation_bookings
     WHERE checkin_date = CURRENT_DATE
       AND status IN ('confirmed','deposit_paid','paid','active')
       AND realm = 'work')                                                                 AS bookings_today_revenue,
  (SELECT COUNT(*) FROM v_documents_expiry_due
     WHERE expiry_date IS NOT NULL
       AND (expiry_date - CURRENT_DATE) BETWEEN 0 AND 30
       AND COALESCE(realm, 'work') = 'work')                                               AS docs_expiring_30d,
  GREATEST(
    (SELECT MAX(ingested_at) FROM accommodation_bookings),
    (SELECT MAX(received_at) FROM vendor_invoice_inbox),
    (SELECT MAX(raised_at)   FROM mart.exceptions)
  )                                                                                        AS last_data_at;

CREATE OR REPLACE VIEW v_today_kpis_private AS
SELECT
  (SELECT COALESCE(SUM(balance), 0) FROM v_account_balances_now WHERE realm = 'family')    AS cash_on_hand,
  (SELECT COUNT(*) FROM v_action_queue
     WHERE realm IN ('family','shared')
       AND severity IN ('critical','high','medium'))                                       AS open_actions_count,
  (SELECT COUNT(*) FROM v_documents_expiry_due
     WHERE expiry_date IS NOT NULL
       AND (expiry_date - CURRENT_DATE) BETWEEN 0 AND 60
       AND COALESCE(realm, 'family') = 'family')                                           AS docs_expiring_60d,
  (SELECT COUNT(*) FROM v_calendar_upcoming
     WHERE start_at::date BETWEEN CURRENT_DATE AND CURRENT_DATE + 7)                       AS calendar_7d,
  (SELECT MAX(raised_at) FROM mart.exceptions)                                             AS last_data_at;

COMMIT;
