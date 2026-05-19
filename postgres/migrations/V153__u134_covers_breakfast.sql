-- =============================================================================
-- V153 — U134 T5: add breakfast_count to dashboard_covers_today
-- =============================================================================
-- Breakfast head count = guests staying the night BEFORE the target date
-- (i.e. who slept in last night and are eating breakfast this morning).
-- On Day 0 (arrival day) a guest isn't counted for that morning — only
-- from their second morning onward. Mirrors normal hotel logic.
-- =============================================================================

BEGIN;

UPDATE query_whitelist
   SET sql_template = $sql$WITH target AS (
                              SELECT COALESCE(:date::date, CURRENT_DATE) AS d
                          ),
                          breakfast AS (
                              SELECT COALESCE(
                                       SUM(adults + COALESCE(children, 0)), 0
                                     ) AS breakfast_count
                                FROM accommodation_bookings, target
                               WHERE checkin_date <= target.d - INTERVAL '1 day'
                                 AND checkout_date > target.d - INTERVAL '1 day'
                                 AND status IN ('confirmed','deposit_paid','paid','active')
                          ),
                          covers AS (
                              SELECT COUNT(*) FILTER (WHERE booking_type='Lunch')      AS lunch_count,
                                     COUNT(*) FILTER (WHERE booking_type='Dinner')     AS dinner_count,
                                     COUNT(*) FILTER (WHERE booking_type='Sunday')     AS sunday_count,
                                     SUM(party_size) FILTER (WHERE booking_type='Lunch')  AS lunch_pax,
                                     SUM(party_size) FILTER (WHERE booking_type='Dinner') AS dinner_pax,
                                     COUNT(*) FILTER (WHERE party_size >= 8)           AS group_count
                                FROM restaurant_reservations, target
                               WHERE reservation_at::date = target.d
                                 AND status IN ('confirmed','enquiry','arrived')
                          )
                          SELECT (SELECT breakfast_count FROM breakfast)::int AS breakfast_count,
                                 covers.lunch_count,  covers.dinner_count,  covers.sunday_count,
                                 covers.lunch_pax,    covers.dinner_pax,    covers.group_count
                            FROM covers$sql$,
       approved_at = NOW(),
       notes       = COALESCE(notes, '') || E'\nV153 (U134 T5): add breakfast_count = guests staying previous night'
 WHERE slug = 'dashboard_covers_today';

COMMIT;
