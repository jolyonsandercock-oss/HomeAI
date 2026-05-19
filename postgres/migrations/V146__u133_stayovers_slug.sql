-- =============================================================================
-- V146 — U133 T6: dashboard_stayovers_today slug
-- =============================================================================
-- Guests staying tonight who are neither arriving nor departing.
-- Same row shape as dashboard_checkins_today / dashboard_checkouts_today so
-- the homepage 3-column grid can reuse one component.
-- =============================================================================

BEGIN;

INSERT INTO query_whitelist
    (slug, display_name, description, sql_template, param_schema, result_format,
     active, created_by, approved_at, approved_by, notes, realm)
VALUES
    ('dashboard_stayovers_today',
     'Stayovers today',
     'Guests checked in before today and checking out after today — i.e. staying tonight, no movement. Drives middle column of the homepage check-ins / stayovers / check-outs grid.',
     $sql$SELECT guest_name, room,
                COALESCE(total_amount, gross_amount, 0) AS amount,
                payment_status,
                (adults + COALESCE(children, 0)) AS party_size
           FROM accommodation_bookings
          WHERE checkin_date < CURRENT_DATE
            AND checkout_date > CURRENT_DATE
            AND status IN ('confirmed','deposit_paid','paid','active')
          ORDER BY room$sql$,
     '{}'::jsonb,
     'table',
     true,
     'V146-U133T6',
     NOW(),
     'V146-U133T6',
     'Per U133 T6 plan — middle column of homepage occupancy grid.',
     'work')
ON CONFLICT (slug) DO UPDATE
   SET sql_template = EXCLUDED.sql_template,
       description  = EXCLUDED.description,
       active       = true,
       approved_at  = NOW();

COMMIT;
