-- =============================================================================
-- V152 — U134 T4: rooms_week_economics slug
-- =============================================================================
-- Nights sold / unsold / % occupied / average stay for the current ISO week
-- (Monday-anchored). Drives the "Rooms — this week" section on the homepage.
-- =============================================================================

BEGIN;

INSERT INTO query_whitelist
    (slug, display_name, description, sql_template, param_schema, result_format,
     active, created_by, approved_at, approved_by, notes, realm)
VALUES
    ('rooms_week_economics',
     'Rooms — this week',
     'Single-row summary: room-nights sold, unsold, % occupied, average stay (nights) for the ISO week containing the target date (defaults today).',
     $sql$WITH target AS (
              SELECT COALESCE(:date::date, CURRENT_DATE) AS d
          ),
          week AS (
              SELECT
                  date_trunc('week', target.d)::date                   AS week_start,
                  (date_trunc('week', target.d) + INTERVAL '7 days')::date AS week_end_exclusive
              FROM target
          ),
          inventory AS (
              SELECT (value->>'count')::int AS rooms_total
                FROM static_context WHERE key = 'rooms.total.malthouse'
          ),
          nights AS (
              SELECT generate_series(week_start, week_end_exclusive - INTERVAL '1 day', INTERVAL '1 day')::date AS d
                FROM week
          ),
          occupancy AS (
              SELECT n.d, COUNT(DISTINCT ab.id) AS rooms_booked
                FROM nights n
                LEFT JOIN accommodation_bookings ab
                  ON ab.checkin_date <= n.d AND ab.checkout_date > n.d
                 AND ab.status IN ('confirmed','deposit_paid','paid','active')
               GROUP BY n.d
          ),
          stays AS (
              SELECT AVG(checkout_date - checkin_date)::numeric(5,2) AS avg_stay_nights
                FROM accommodation_bookings
               WHERE checkin_date >= (SELECT week_start FROM week)
                 AND checkin_date <  (SELECT week_end_exclusive FROM week)
                 AND status IN ('confirmed','deposit_paid','paid','active')
          )
          SELECT
              (SELECT week_start FROM week)                     AS week_start,
              SUM(rooms_booked)                                 AS room_nights_sold,
              (SELECT rooms_total FROM inventory) * 7           AS room_nights_capacity,
              CASE WHEN (SELECT rooms_total FROM inventory) > 0
                   THEN ROUND(SUM(rooms_booked)::numeric * 100
                              / ((SELECT rooms_total FROM inventory) * 7), 1)
                   ELSE NULL END                                AS pct_occupied,
              (SELECT avg_stay_nights FROM stays)               AS avg_stay_nights,
              (SELECT rooms_total FROM inventory) * 7
                  - SUM(rooms_booked)                           AS room_nights_unsold
          FROM occupancy$sql$,
     '{"date": {"type":"string","format":"date","optional":true}}'::jsonb,
     'table', true, 'V152-U134T4', NOW(), 'V152-U134T4',
     'Per U134 T4 plan — week-level room economics.', 'work')
ON CONFLICT (slug) DO UPDATE
   SET sql_template = EXCLUDED.sql_template,
       param_schema = EXCLUDED.param_schema,
       active       = true,
       approved_at  = NOW();

COMMIT;
