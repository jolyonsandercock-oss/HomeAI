-- =============================================================================
-- V154 — U135 T3: restaurant_reservations deposit columns
-- =============================================================================
-- Collins emails include a "Deposit paid: £NN" line on bookings that took
-- a card deposit. Capture that into structured columns so the week-strip
-- + cash-up reconciliation can surface it.
--
-- The actual Collins-email parser extension is a follow-up — this migration
-- lays the schema so existing rows stay NULL and new fields populate when
-- u101-harvest-collins-reservations.py learns to parse the deposit line.
-- =============================================================================

BEGIN;

ALTER TABLE restaurant_reservations
    ADD COLUMN IF NOT EXISTS deposit_pence INTEGER,
    ADD COLUMN IF NOT EXISTS deposit_paid_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_restaurant_reservations_deposit
    ON restaurant_reservations (reservation_at)
    WHERE deposit_pence IS NOT NULL;

-- Extend dashboard_specials_next_7d to include deposit-bearing non-group
-- reservations alongside the existing party_size >= 8 group bookings.
UPDATE query_whitelist
   SET sql_template = $sql$SELECT day, kind, label, party_size, payment_status,
                                  deposit_pence
                           FROM (
            SELECT reservation_at::date         AS day,
                   'group_booking'::text        AS kind,
                   COALESCE(guest_name, '?')    AS label,
                   party_size,
                   NULL::text                   AS payment_status,
                   deposit_pence
              FROM restaurant_reservations
             WHERE reservation_at::date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '6 days'
               AND party_size >= 8
               AND status IN ('confirmed','enquiry','arrived')
            UNION ALL
            SELECT reservation_at::date,
                   'deposit_booking'::text,
                   COALESCE(guest_name, '?'),
                   party_size,
                   NULL::text,
                   deposit_pence
              FROM restaurant_reservations
             WHERE reservation_at::date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '6 days'
               AND deposit_pence IS NOT NULL AND deposit_pence > 0
               AND party_size < 8
               AND status IN ('confirmed','enquiry','arrived')
            UNION ALL
            SELECT checkin_date,
                   'group_stay'::text,
                   COALESCE(guest_name, '?'),
                   adults + COALESCE(children, 0),
                   payment_status,
                   NULL::int
              FROM accommodation_bookings
             WHERE checkin_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '6 days'
               AND status IN ('confirmed','deposit_paid','paid','active')
               AND adults + COALESCE(children, 0) >= 4
          ) x
          ORDER BY day, party_size DESC, label$sql$,
       approved_at = NOW(),
       notes       = COALESCE(notes,'') || E'\nV154 (U135 T3): include deposit-bearing non-group bookings'
 WHERE slug = 'dashboard_specials_next_7d';

COMMIT;
