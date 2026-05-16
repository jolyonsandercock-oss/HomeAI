-- =============================================================================
-- V120 — U99: track when a renewal email arrived per vehicle/kind
-- =============================================================================
-- Today's audit found WF14FNP insurance "due 5 days" alert is misleading —
-- AXA sent a "your insurance will renew soon" email on 27 April 2026 (it
-- auto-renews). Need a way to mark "no action required, insurer's on it".
--
-- Add a sidecar table:
--   vehicle_renewal_signals (vehicle_id, kind, signal_at, source, snippet)
-- and a view v_vehicle_alerts that suppresses alerts when a recent
-- signal arrived in the last 60 days.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

CREATE TABLE IF NOT EXISTS vehicle_renewal_signals (
  id              BIGSERIAL PRIMARY KEY,
  vehicle_id      BIGINT NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE,
  kind            TEXT   NOT NULL CHECK (kind IN ('mot','insurance','road_tax','service')),
  signal_at       TIMESTAMPTZ NOT NULL,
  source          TEXT,           -- vendor_domain (axa-insurance.co.uk, etc.)
  snippet         TEXT,           -- first ~200 chars of email body
  gmail_message_id TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (vehicle_id, kind, gmail_message_id)
);

CREATE INDEX IF NOT EXISTS idx_vrs_vehicle_kind_signal
  ON vehicle_renewal_signals (vehicle_id, kind, signal_at DESC);

COMMENT ON TABLE vehicle_renewal_signals IS
'U99 V120. Per-vehicle per-kind "insurer/registrar has acknowledged
upcoming renewal" log. Suppresses noisy due-soon alerts when a signal
landed in the last 60 days.';

-- Update v_vehicle_alerts to suppress when a recent signal exists
DROP VIEW IF EXISTS v_vehicle_alerts CASCADE;
CREATE VIEW v_vehicle_alerts AS
WITH per_kind AS (
  SELECT id, registration, make_model, 'mot' AS kind, mot_due AS due_date FROM vehicles WHERE mot_due IS NOT NULL
  UNION ALL
  SELECT id, registration, make_model, 'insurance', insurance_renewal FROM vehicles WHERE insurance_renewal IS NOT NULL
  UNION ALL
  SELECT id, registration, make_model, 'road_tax',  road_tax_due      FROM vehicles WHERE road_tax_due IS NOT NULL
  UNION ALL
  SELECT id, registration, make_model, 'service',   service_due_date  FROM vehicles WHERE service_due_date IS NOT NULL
),
signals AS (
  SELECT vehicle_id, kind, MAX(signal_at) AS latest_signal
  FROM vehicle_renewal_signals
  WHERE signal_at > now() - INTERVAL '60 days'
  GROUP BY vehicle_id, kind
)
SELECT
  pk.id                                              AS vehicle_id,
  pk.registration,
  pk.make_model,
  pk.kind,
  pk.due_date,
  (pk.due_date - CURRENT_DATE)::int                  AS days_to_due,
  CASE
    WHEN s.latest_signal IS NOT NULL                THEN 'low'      -- insurer has acked
    WHEN pk.due_date < CURRENT_DATE                 THEN 'high'
    WHEN pk.due_date - CURRENT_DATE <= 7            THEN 'high'
    WHEN pk.due_date - CURRENT_DATE <= 30           THEN 'medium'
    WHEN pk.due_date - CURRENT_DATE <= 60           THEN 'low'
    ELSE                                                 NULL
  END                                                AS severity,
  s.latest_signal                                    AS last_signal_at
FROM per_kind pk
LEFT JOIN signals s ON s.vehicle_id = pk.id AND s.kind = pk.kind
WHERE pk.due_date <= CURRENT_DATE + 60;

COMMENT ON VIEW v_vehicle_alerts IS
'U99 V120. Vehicle alerts with severity de-escalated to "low" when a
renewal signal (DVLA / insurer / etc.) landed in the last 60 days.';

-- Rebuild v_action_queue with the same v_vehicle_alerts UNION (it was
-- already there from V114; just need to include last_signal_at in extra).
DROP VIEW IF EXISTS v_action_queue CASCADE;
CREATE VIEW v_action_queue AS

-- Open exceptions
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

SELECT 'invoice_review'::text, v.id::text,
  CASE WHEN COALESCE(v.amount_seen,0) >= 500 THEN 'medium' ELSE 'low' END::text,
  'invoice_needs_review'::text,
  COALESCE(v.vendor_name, v.subject, 'Unknown vendor')::text,
  COALESCE(v.received_at::date, CURRENT_DATE),
  GREATEST(0, (CURRENT_DATE - COALESCE(v.received_at::date, CURRENT_DATE))::int),
  COALESCE(v.realm, 'work')::text,
  jsonb_build_object('amount', v.amount_seen, 'vendor', v.vendor_name, 'subject', v.subject)
FROM vendor_invoice_inbox v WHERE v.status = 'needs_review'

UNION ALL

SELECT 'bot_instruction'::text, b.id::text, 'low'::text, 'instruction_pending'::text,
  COALESCE(LEFT(b.raw_subject, 120), 'Pending instruction')::text,
  COALESCE(b.received_at::date, CURRENT_DATE),
  GREATEST(0, (CURRENT_DATE - COALESCE(b.received_at::date, CURRENT_DATE))::int),
  COALESCE(b.realm, 'work')::text,
  jsonb_build_object('lane', b.lane)
FROM bot_instructions b WHERE b.status = 'pending'

UNION ALL

SELECT 'document_expiry'::text, d.id::text,
  CASE WHEN (d.expiry_date - CURRENT_DATE) < 14 THEN 'high'
       WHEN (d.expiry_date - CURRENT_DATE) < 30 THEN 'medium' ELSE 'low' END::text,
  'document_expiring'::text,
  COALESCE(d.title, d.category, 'Document')::text,
  d.expiry_date, GREATEST(0, (d.expiry_date - CURRENT_DATE)::int),
  COALESCE(d.realm, 'work')::text,
  jsonb_build_object('expiry', d.expiry_date, 'category', d.category)
FROM v_documents_expiry_due d
WHERE d.expiry_date IS NOT NULL AND (d.expiry_date - CURRENT_DATE) BETWEEN -7 AND 60

UNION ALL

-- Vehicle alerts (V120 — now signal-aware)
SELECT 'vehicle_alert'::text,
  (va.vehicle_id || ':' || va.kind)::text,
  va.severity::text,
  ('vehicle_' || va.kind)::text,
  CASE
    WHEN va.last_signal_at IS NOT NULL
      THEN va.registration || ' ' || va.kind || ' due ' || va.due_date || ' (insurer on it)'
    WHEN va.days_to_due < 0
      THEN va.registration || ' ' || va.kind || ' overdue (' || va.due_date || ')'
    ELSE va.registration || ' ' || va.kind || ' due ' || va.due_date
  END,
  va.due_date,
  CASE WHEN va.days_to_due < 0 THEN ABS(va.days_to_due) ELSE 0 END,
  'family'::text,
  jsonb_build_object(
    'vehicle_id', va.vehicle_id,
    'registration', va.registration,
    'make_model', va.make_model,
    'kind', va.kind,
    'due_date', va.due_date,
    'days_to_due', va.days_to_due,
    'last_signal_at', va.last_signal_at
  )
FROM v_vehicle_alerts va
WHERE va.severity IS NOT NULL;

-- Rebuild v_today_kpis_* (cascade dropped them)
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
       AND status IN ('confirmed','deposit_paid','paid','active'))                         AS bookings_today,
  (SELECT COALESCE(SUM(gross_amount), 0) FROM accommodation_bookings
     WHERE checkin_date = CURRENT_DATE
       AND status IN ('confirmed','deposit_paid','paid','active'))                         AS bookings_today_revenue,
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

-- Insert the AXA → WF14FNP signal we found right now
INSERT INTO vehicle_renewal_signals (vehicle_id, kind, signal_at, source, snippet, gmail_message_id)
SELECT v.id, 'insurance', '2026-04-27 02:45:29+01'::timestamptz,
       'axa-insurance.co.uk',
       'Your car: SEAT ALHAMBRA SE TDI (140) Manual Diesel Your registration: WF14FNP. Insurance will renew soon.',
       'axa-2026-04-27'
FROM vehicles v WHERE v.registration = 'WF14FNP'
ON CONFLICT (vehicle_id, kind, gmail_message_id) DO NOTHING;

GRANT SELECT ON vehicle_renewal_signals TO PUBLIC;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'homeai_pipeline') THEN
    EXECUTE 'GRANT INSERT, SELECT ON vehicle_renewal_signals TO homeai_pipeline';
    EXECUTE 'GRANT USAGE, SELECT ON vehicle_renewal_signals_id_seq TO homeai_pipeline';
  END IF;
END$$;

COMMIT;
