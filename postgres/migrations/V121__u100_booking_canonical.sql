-- =============================================================================
-- V121 — U100: dedupe direct-Airbnb (U96) vs caterbook-Airbnb (U97)
-- =============================================================================
-- The same Airbnb booking arrives via two paths:
--   - automated@airbnb.com  → source='airbnb', source_ref=HM12345678
--   - caterbook.net forward → source='caterbook_airbnb', source_ref=HM12345678_L-1420
-- Caterbook rows have more data (checkin date, room, total, party size) so
-- they win as canonical. Direct rows are tagged status='superseded' with
-- canonical_id pointing at the caterbook row.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- Allow 'superseded' as a status value (status column has no check constraint
-- so just need to ensure downstream tolerates it). Check existing constraint:
DO $$
DECLARE
  v_ck TEXT;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_ck
    FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid
   WHERE r.relname = 'accommodation_bookings' AND c.contype = 'c' AND c.conname LIKE '%status%';
  IF v_ck IS NOT NULL THEN
    RAISE NOTICE 'Existing status CK: %', v_ck;
  END IF;
END $$;

-- Pair up + link.
WITH pairs AS (
  SELECT
    a.id AS direct_id,
    c.id AS canonical_id
  FROM accommodation_bookings a
  JOIN accommodation_bookings c
    ON a.source IN ('airbnb', 'Airbnb')
   AND c.source = 'caterbook_airbnb'
   AND substr(c.source_ref, 1, 10) = a.source_ref
   AND (a.status <> 'superseded' OR a.status IS NULL)
),
link_canonical AS (
  -- Mark caterbook keeper as canonical=self
  UPDATE accommodation_bookings ab
     SET canonical_id = ab.id
    FROM pairs p
   WHERE ab.id = p.canonical_id
     AND (ab.canonical_id IS NULL OR ab.canonical_id <> ab.id)
   RETURNING ab.id
),
demote_direct AS (
  -- Demote direct-Airbnb rows
  UPDATE accommodation_bookings ab
     SET status = 'superseded',
         canonical_id = p.canonical_id
    FROM pairs p
   WHERE ab.id = p.direct_id
   RETURNING ab.id
)
SELECT
  (SELECT COUNT(*) FROM link_canonical) AS canonicals_set,
  (SELECT COUNT(*) FROM demote_direct)  AS direct_superseded;

-- Make sure today's bookings view excludes superseded rows
DROP VIEW IF EXISTS v_today_bookings CASCADE;
CREATE VIEW v_today_bookings AS
SELECT
  id, source, source_ref, guest_name, room,
  checkin_date, checkout_date, gross_amount, payment_status, status, realm,
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
  AND status IN ('confirmed','deposit_paid','paid','active')  -- excludes 'superseded'
ORDER BY id;

CREATE OR REPLACE VIEW v_today_bookings_by_source AS
SELECT source_label, COUNT(*) AS bookings, SUM(gross_amount)::numeric(12,2) AS revenue
FROM v_today_bookings GROUP BY source_label ORDER BY bookings DESC;

-- The bookings_today count on v_today_kpis_work already filters
-- status IN (confirmed, deposit_paid, paid, active) so superseded
-- rows drop out automatically.

COMMIT;
