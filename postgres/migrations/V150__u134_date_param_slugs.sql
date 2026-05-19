-- =============================================================================
-- V150 — U134 T2: make 7 "today" slugs accept a :date param (default = today)
-- =============================================================================
-- Enables the click-a-day-on-strip → day-view drilldown. Each slug now reads
--   COALESCE(:date::date, CURRENT_DATE)
-- instead of CURRENT_DATE directly, so calling with no param behaves
-- identically and calling with ?date=YYYY-MM-DD pivots the view.
-- =============================================================================

BEGIN;

-- frontend_today_gross — keep U132's "latest available report_date" fallback
-- but anchor the upper bound on the chosen date.
UPDATE query_whitelist
   SET sql_template = $sql$SELECT site,
                                  SUM(value)::numeric(12,2) AS gross,
                                  MAX(report_date) AS as_of
                           FROM touchoffice_department_sales
                           WHERE report_date = (
                             SELECT MAX(report_date)
                               FROM touchoffice_department_sales
                              WHERE report_date <= COALESCE(:date::date, CURRENT_DATE)
                           )
                           GROUP BY site$sql$,
       param_schema = '{"date": {"type":"string","format":"date","optional":true}}'::jsonb,
       approved_at  = NOW(),
       notes        = COALESCE(notes, '') || E'\nV150 (U134 T2): accept :date param'
 WHERE slug = 'frontend_today_gross';

-- frontend_accommodation_today
UPDATE query_whitelist
   SET sql_template = $sql$SELECT
       (SELECT COUNT(*) FROM accommodation_bookings WHERE checkin_date = COALESCE(:date::date, CURRENT_DATE)
          AND status IN ('confirmed','deposit_paid','paid','active')) AS arrivals,
       (SELECT COUNT(*) FROM accommodation_bookings WHERE checkout_date = COALESCE(:date::date, CURRENT_DATE)
          AND status IN ('confirmed','deposit_paid','paid','active')) AS departures,
       (SELECT COUNT(*) FROM accommodation_bookings WHERE checkin_date < COALESCE(:date::date, CURRENT_DATE)
          AND checkout_date > COALESCE(:date::date, CURRENT_DATE)
          AND status IN ('confirmed','deposit_paid','paid','active')) AS staying$sql$,
       param_schema = '{"date": {"type":"string","format":"date","optional":true}}'::jsonb,
       approved_at  = NOW(),
       notes        = COALESCE(notes, '') || E'\nV150 (U134 T2): accept :date param'
 WHERE slug = 'frontend_accommodation_today';

-- dashboard_covers_today (T5 also augments this with breakfast_count in V153)
UPDATE query_whitelist
   SET sql_template = $sql$SELECT COUNT(*) FILTER (WHERE booking_type='Lunch')  AS lunch_count,
                                  COUNT(*) FILTER (WHERE booking_type='Dinner') AS dinner_count,
                                  COUNT(*) FILTER (WHERE booking_type='Sunday') AS sunday_count,
                                  SUM(party_size) FILTER (WHERE booking_type='Lunch')  AS lunch_pax,
                                  SUM(party_size) FILTER (WHERE booking_type='Dinner') AS dinner_pax,
                                  COUNT(*) FILTER (WHERE party_size >= 8) AS group_count
                           FROM restaurant_reservations
                           WHERE reservation_at::date = COALESCE(:date::date, CURRENT_DATE)
                             AND status IN ('confirmed','enquiry','arrived')$sql$,
       param_schema = '{"date": {"type":"string","format":"date","optional":true}}'::jsonb,
       approved_at  = NOW(),
       notes        = COALESCE(notes, '') || E'\nV150 (U134 T2): accept :date param'
 WHERE slug = 'dashboard_covers_today';

-- dashboard_special_today
UPDATE query_whitelist
   SET sql_template = $sql$SELECT 'group_booking'::text AS kind,
                                  guest_name AS label,
                                  party_size AS detail,
                                  reservation_at::text AS notes
                           FROM restaurant_reservations
                           WHERE reservation_at::date = COALESCE(:date::date, CURRENT_DATE)
                             AND party_size >= 8
                             AND status IN ('confirmed','enquiry','arrived')
                           UNION ALL
                           SELECT 'group_stay'::text, guest_name,
                                  adults + COALESCE(children, 0),
                                  checkin_date::text || ' to ' || checkout_date::text
                           FROM accommodation_bookings
                           WHERE checkin_date <= COALESCE(:date::date, CURRENT_DATE)
                             AND checkout_date > COALESCE(:date::date, CURRENT_DATE)
                             AND status IN ('confirmed','deposit_paid','paid','active')
                             AND adults + COALESCE(children, 0) >= 4
                           ORDER BY 1$sql$,
       param_schema = '{"date": {"type":"string","format":"date","optional":true}}'::jsonb,
       approved_at  = NOW(),
       notes        = COALESCE(notes, '') || E'\nV150 (U134 T2): accept :date param'
 WHERE slug = 'dashboard_special_today';

-- dashboard_checkins_today
UPDATE query_whitelist
   SET sql_template = $sql$SELECT guest_name, room,
                                  COALESCE(total_amount, gross_amount, 0) AS amount,
                                  payment_status,
                                  (adults + COALESCE(children, 0)) AS party_size
                           FROM accommodation_bookings
                           WHERE checkin_date = COALESCE(:date::date, CURRENT_DATE)
                             AND status IN ('confirmed','deposit_paid','paid','active')
                           ORDER BY room$sql$,
       param_schema = '{"date": {"type":"string","format":"date","optional":true}}'::jsonb,
       approved_at  = NOW(),
       notes        = COALESCE(notes, '') || E'\nV150 (U134 T2): accept :date param'
 WHERE slug = 'dashboard_checkins_today';

-- dashboard_stayovers_today
UPDATE query_whitelist
   SET sql_template = $sql$SELECT guest_name, room,
                                  COALESCE(total_amount, gross_amount, 0) AS amount,
                                  payment_status,
                                  (adults + COALESCE(children, 0)) AS party_size
                           FROM accommodation_bookings
                           WHERE checkin_date < COALESCE(:date::date, CURRENT_DATE)
                             AND checkout_date > COALESCE(:date::date, CURRENT_DATE)
                             AND status IN ('confirmed','deposit_paid','paid','active')
                           ORDER BY room$sql$,
       param_schema = '{"date": {"type":"string","format":"date","optional":true}}'::jsonb,
       approved_at  = NOW(),
       notes        = COALESCE(notes, '') || E'\nV150 (U134 T2): accept :date param'
 WHERE slug = 'dashboard_stayovers_today';

-- dashboard_checkouts_today
UPDATE query_whitelist
   SET sql_template = $sql$SELECT guest_name, room,
                                  COALESCE(total_amount, gross_amount, 0) AS amount,
                                  payment_status,
                                  (adults + COALESCE(children, 0)) AS party_size
                           FROM accommodation_bookings
                           WHERE checkout_date = COALESCE(:date::date, CURRENT_DATE)
                             AND status IN ('confirmed','deposit_paid','paid','active')
                           ORDER BY room$sql$,
       param_schema = '{"date": {"type":"string","format":"date","optional":true}}'::jsonb,
       approved_at  = NOW(),
       notes        = COALESCE(notes, '') || E'\nV150 (U134 T2): accept :date param'
 WHERE slug = 'dashboard_checkouts_today';

COMMIT;
