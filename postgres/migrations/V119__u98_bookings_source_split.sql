-- =============================================================================
-- V119 — U98: bookings source breakdown + today KPI counts all OTA sources
-- =============================================================================
-- After U96 (direct Airbnb) and U97 (Caterbook-forwarded), accommodation_bookings
-- has multiple sources for the same property:
--   hotel_email           — direct hotel-email.com confirmations
--   airbnb                — direct Airbnb confirmations (U96)
--   caterbook_airbnb      — Airbnb via Caterbook (U97)
--   caterbook_agoda       — Agoda via Caterbook
--   caterbook_ctrip       — Ctrip via Caterbook
--   agodaycs / ctrip.com  — pre-existing rows
--   Airbnb                — pre-existing (mixed case)
--
-- This migration:
--   1. Updates v_today_bookings to surface source explicitly
--   2. Recreates v_today_kpis_work so bookings_today counts ALL accommodation
--      sources (not just the work realm — the realm constraint was too tight)
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

DROP VIEW IF EXISTS v_today_bookings CASCADE;
CREATE VIEW v_today_bookings AS
SELECT
  id, source, source_ref, guest_name, room,
  checkin_date, checkout_date, gross_amount, payment_status, status, realm,
  -- Normalise source for grouping/display
  CASE
    WHEN source ILIKE 'airbnb' OR source = 'caterbook_airbnb' THEN 'Airbnb'
    WHEN source ILIKE 'agoda%' OR source = 'caterbook_agoda'  THEN 'Agoda'
    WHEN source ILIKE 'ctrip%' OR source = 'caterbook_ctrip'  THEN 'Ctrip'
    WHEN source = 'hotel_email'                                 THEN 'Direct'
    WHEN source ILIKE 'expedia%'                                THEN 'Expedia'
    WHEN source ILIKE 'oyo%'                                    THEN 'OYO'
    WHEN source ILIKE '%booking%'                               THEN 'Booking.com'
    ELSE source
  END AS source_label
FROM accommodation_bookings
WHERE checkin_date = CURRENT_DATE
  AND status IN ('confirmed','deposit_paid','paid','active')
ORDER BY id;

COMMENT ON VIEW v_today_bookings IS
'U85 §T03 + U98 V119. Today check-ins with normalised source_label.';

-- New view: today's bookings grouped by source for the tile
DROP VIEW IF EXISTS v_today_bookings_by_source CASCADE;
CREATE VIEW v_today_bookings_by_source AS
SELECT source_label, COUNT(*) AS bookings, SUM(gross_amount)::numeric(12,2) AS revenue
FROM v_today_bookings
GROUP BY source_label
ORDER BY bookings DESC;

COMMENT ON VIEW v_today_bookings_by_source IS
'U98 V119. /work/today bookings tile source breakdown.';

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES (
  'today_bookings_by_source',
  'U98 — today bookings by source',
  'SELECT * FROM v_today_bookings_by_source',
  'Today check-ins grouped by normalised source (Airbnb/Agoda/Direct/...)',
  'u98','owner',1, ARRAY['bookings by source'],
  now(),'u98'
) ON CONFLICT (slug) DO UPDATE
  SET sql_template=EXCLUDED.sql_template, approved_at=now(), approved_by='u98';

-- Recreate v_today_kpis_work — bookings_today should count ALL realms for
-- the property (not just work). A Caterbook-forwarded booking might be
-- realm='shared' if the harvester defaulted it.
CREATE OR REPLACE VIEW v_today_kpis_work AS
SELECT
  (SELECT COALESCE(SUM(balance), 0) FROM v_account_balances_now WHERE realm = 'work')      AS cash_on_hand,
  (SELECT COUNT(*) FROM v_action_queue
     WHERE realm IN ('work','shared')
       AND severity IN ('critical','high','medium'))                                       AS open_actions_count,
  (SELECT COUNT(*) FROM v_action_queue
     WHERE realm IN ('work','shared')
       AND severity = 'critical')                                                          AS critical_actions_count,

  -- Bookings: count ALL accommodation bookings checking in today, regardless
  -- of realm (some Caterbook-forwarded rows land as realm='work' but new
  -- OTAs may default differently).
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

COMMIT;
