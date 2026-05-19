-- =============================================================================
-- V145 — U133 T5: dashboard_specials_next_7d slug
-- =============================================================================
-- Surface group bookings + group stays per day across the week strip.
-- Threshold: restaurant party_size >= 8, accommodation adults+children >= 4.
-- =============================================================================

BEGIN;

INSERT INTO query_whitelist
    (slug, display_name, description, sql_template, param_schema, result_format,
     active, created_by, approved_at, approved_by, notes, realm)
VALUES
    ('dashboard_specials_next_7d',
     'Specials & group bookings — next 7 days',
     'Group bookings (restaurant party_size >= 8) and group stays (accommodation adults+children >= 4) for today + 6 days forward. Drives inline tile lines on the dashboard week strip.',
     $sql$SELECT day, kind, label, party_size, payment_status FROM (
            SELECT reservation_at::date         AS day,
                   'group_booking'::text        AS kind,
                   COALESCE(guest_name, '?')    AS label,
                   party_size,
                   NULL::text                   AS payment_status
              FROM restaurant_reservations
             WHERE reservation_at::date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '6 days'
               AND party_size >= 8
               AND status IN ('confirmed','enquiry','arrived')
            UNION ALL
            SELECT checkin_date                                      AS day,
                   'group_stay'::text                                AS kind,
                   COALESCE(guest_name, '?')                         AS label,
                   adults + COALESCE(children, 0)                    AS party_size,
                   payment_status
              FROM accommodation_bookings
             WHERE checkin_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '6 days'
               AND status IN ('confirmed','deposit_paid','paid','active')
               AND adults + COALESCE(children, 0) >= 4
          ) x
          ORDER BY day, party_size DESC, label$sql$,
     '{}'::jsonb,
     'table',
     true,
     'V145-U133T5',
     NOW(),
     'V145-U133T5',
     'Per U133 T5 plan — inline per-day specials on week strip.',
     'work')
ON CONFLICT (slug) DO UPDATE
   SET sql_template = EXCLUDED.sql_template,
       description  = EXCLUDED.description,
       active       = true,
       approved_at  = NOW();

COMMIT;
