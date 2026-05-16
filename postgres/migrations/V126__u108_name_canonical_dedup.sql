-- =============================================================================
-- V126 — U108: canonical-name column + hotel_email vs caterbook dedup
-- =============================================================================
-- Two issues caught in today's daily reality email:
--
-- 1. Hannah Hewland appears twice on today's departures: once via
--    source='hotel_email' (Brother-style booking notification, name
--    parsed without spaces) and once via source='caterbook_airbnb'
--    (Caterbook forwarding). Same booking, two ingestion paths.
--    V121's source-prefix dedup only caught direct-Airbnb vs caterbook;
--    hotel_email vs caterbook needs a separate match.
--
-- 2. Cross-link in the daily summary failed because the hotel_email
--    parser stored "MatthiasStötzner" (no space) while Caterbook stored
--    "Matthias Stötzner". Equality match missed.
--
-- Fix:
--   - Add guest_name_canonical: lowercase + strip non-alphanumeric.
--     "Matthias Stötzner" + "MatthiasStötzner" both → "matthiasstötzner".
--   - Index it.
--   - Dedup hotel_email vs caterbook_* by (canonical, checkin_date).
--     Caterbook wins (richer data: guest_email, total, party size).
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- Normaliser function — public so any view can use it
CREATE OR REPLACE FUNCTION public.canonical_name(p text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT lower(regexp_replace(coalesce(p, ''), '[^[:alnum:]]+', '', 'g'))
$$;

COMMENT ON FUNCTION public.canonical_name(text) IS
'U108 V126. Normalises a person name for fuzzy matching: lowercases +
strips non-alphanumeric. "Matthias Stötzner" → "matthiasstötzner".';

-- Generated column on accommodation_bookings
ALTER TABLE accommodation_bookings
  ADD COLUMN IF NOT EXISTS guest_name_canonical TEXT
    GENERATED ALWAYS AS (canonical_name(guest_name)) STORED;
CREATE INDEX IF NOT EXISTS idx_ab_name_canonical
  ON accommodation_bookings (guest_name_canonical);

-- Same on restaurant_reservations
ALTER TABLE restaurant_reservations
  ADD COLUMN IF NOT EXISTS guest_name_canonical TEXT
    GENERATED ALWAYS AS (canonical_name(guest_name)) STORED;
CREATE INDEX IF NOT EXISTS idx_rr_name_canonical
  ON restaurant_reservations (guest_name_canonical);

-- Dedup hotel_email vs caterbook_*
-- Same person + same checkin → keep the Caterbook row as canonical
WITH pairs AS (
  SELECT he.id AS hotel_id, cb.id AS canonical_id
    FROM accommodation_bookings he
    JOIN accommodation_bookings cb
      ON he.guest_name_canonical = cb.guest_name_canonical
     AND he.checkin_date = cb.checkin_date
     AND he.source = 'hotel_email'
     AND cb.source LIKE 'caterbook_%'
     AND he.guest_name_canonical <> ''
     AND he.status NOT IN ('superseded','duplicate')
     AND cb.status NOT IN ('superseded','duplicate')
),
demote AS (
  UPDATE accommodation_bookings ab
     SET status = 'superseded',
         canonical_id = p.canonical_id
    FROM pairs p
   WHERE ab.id = p.hotel_id
   RETURNING ab.id
),
link AS (
  UPDATE accommodation_bookings ab
     SET canonical_id = ab.id
    FROM pairs p
   WHERE ab.id = p.canonical_id
     AND (ab.canonical_id IS NULL OR ab.canonical_id <> ab.id)
   RETURNING ab.id
)
SELECT (SELECT COUNT(*) FROM demote) AS hotel_email_superseded,
       (SELECT COUNT(*) FROM link)   AS caterbook_canonicals_set;

-- Rebuild v_today_bookings cross-link helper view
DROP VIEW IF EXISTS v_today_stay_dine_crosslink CASCADE;
CREATE VIEW v_today_stay_dine_crosslink AS
SELECT DISTINCT
  ab.id              AS booking_id,
  ab.guest_name      AS staying_as,
  ab.room,
  rr.id              AS reservation_id,
  rr.guest_name      AS dining_as,
  rr.party_size,
  rr.reservation_at,
  rr.booking_type
FROM accommodation_bookings ab
JOIN restaurant_reservations rr
  ON ab.guest_name_canonical = rr.guest_name_canonical
 AND rr.reservation_at::date BETWEEN ab.checkin_date AND ab.checkout_date
WHERE ab.checkin_date <= CURRENT_DATE
  AND ab.checkout_date  >  CURRENT_DATE
  AND ab.status IN ('confirmed','deposit_paid','paid','active')
  AND rr.status IN ('confirmed','enquiry','arrived')
  AND rr.reservation_at::date = CURRENT_DATE
  AND ab.guest_name_canonical <> ''
ORDER BY rr.reservation_at;

COMMENT ON VIEW v_today_stay_dine_crosslink IS
'U108 V126. Guests staying AND dining tonight, matched on
canonical_name (whitespace-insensitive).';

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES (
  'stay_dine_crosslink_today',
  'U108 — guests staying + dining tonight',
  'SELECT * FROM v_today_stay_dine_crosslink',
  'Today VIP cross-link: people in the inn AND at the restaurant tonight',
  'u108','owner',1, ARRAY['vip crosslink','staying dining'],
  now(),'u108'
) ON CONFLICT (slug) DO UPDATE SET
  sql_template=EXCLUDED.sql_template, approved_at=now(), approved_by='u108';

COMMIT;
