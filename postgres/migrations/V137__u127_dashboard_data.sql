-- =============================================================================
-- V137 — U127: dashboard rebuild data sources
-- =============================================================================
-- Adds sunrise/sunset to weather_forecast + new slugs for the rebuilt
-- Dashboard page (combined revenue tile, week strip with sun/temp/rain,
-- room/cover counts, checkin/checkout name lists, etc).
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

ALTER TABLE weather_forecast
  ADD COLUMN IF NOT EXISTS sunrise TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS sunset  TIMESTAMPTZ;

COMMENT ON COLUMN weather_forecast.sunrise IS 'U127 V137. From open-meteo daily sunrise[]';
COMMENT ON COLUMN weather_forecast.sunset  IS 'U127 V137. From open-meteo daily sunset[]';

-- Combined revenue (yesterday — used for the "Labour" tile)
INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES
  -- Labour + sales yesterday: per-centre + combined, with 7d/30d rolling avg ratios
  ('dashboard_labour_yesterday',
   'U127 — labour vs sales yesterday + rolling',
   'WITH params AS (SELECT generate_series(1, 30) AS d), windows AS (SELECT 1 AS w UNION SELECT 7 UNION SELECT 30), labour AS (SELECT (CURRENT_DATE - p.d) AS d, team, SUM(cost_with_oncost) c FROM params p JOIN v_daily_labour_by_team l ON l.report_date = (CURRENT_DATE - p.d) GROUP BY p.d, team), sales AS (SELECT (CURRENT_DATE - p.d) AS d, site, SUM(value) s FROM params p JOIN touchoffice_department_sales t ON t.report_date = (CURRENT_DATE - p.d) GROUP BY p.d, site) SELECT w.w AS window_days, SUM(labour.c) FILTER (WHERE labour.team IN (''kitchen'',''front_of_house'',''accommodation'')) / NULLIF(w.w,0) AS pub_labour_avg, SUM(sales.s) FILTER (WHERE sales.site=''malthouse'') / NULLIF(w.w,0) AS pub_sales_avg, SUM(labour.c) FILTER (WHERE labour.team=''cafe'') / NULLIF(w.w,0) AS cafe_labour_avg, SUM(sales.s) FILTER (WHERE sales.site=''sandwich'') / NULLIF(w.w,0) AS cafe_sales_avg FROM windows w LEFT JOIN labour ON labour.d >= CURRENT_DATE - w.w AND labour.d < CURRENT_DATE LEFT JOIN sales ON sales.d >= CURRENT_DATE - w.w AND sales.d < CURRENT_DATE GROUP BY w.w ORDER BY w.w',
   'Labour cost vs sales yesterday + 7d/30d rolling — pub/cafe split',
   'u127','owner',1, ARRAY['labour vs sales','wage pct rolling','dashboard labour'],
   now(),'u127'),

  -- Week strip: 7 days with weather + occupancy + covers
  ('dashboard_week_strip',
   'U127 — 7-day strip with weather + bookings',
   'WITH dates AS (SELECT generate_series(CURRENT_DATE - INTERVAL ''3 days'', CURRENT_DATE + INTERVAL ''3 days'', INTERVAL ''1 day'')::date AS d), wx AS (SELECT DISTINCT ON (forecast_date) forecast_date, max_temp_c, min_temp_c, rain_mm, precipitation_probability, weather_code, max_wind_mph, sunrise AT TIME ZONE ''Europe/London'' AS sunrise, sunset AT TIME ZONE ''Europe/London'' AS sunset, wave_height_m FROM weather_forecast WHERE forecast_date BETWEEN CURRENT_DATE - INTERVAL ''3 days'' AND CURRENT_DATE + INTERVAL ''3 days'' ORDER BY forecast_date, fetched_at DESC), wd AS (SELECT observation_date AS d, peak_temp_c, rain_mm, max_wind_mph FROM weather_daily WHERE observation_date BETWEEN CURRENT_DATE - INTERVAL ''3 days'' AND CURRENT_DATE - INTERVAL ''1 day''), rooms AS (SELECT dates.d AS d, COUNT(DISTINCT id) AS booked FROM dates LEFT JOIN accommodation_bookings ab ON ab.checkin_date <= dates.d AND ab.checkout_date > dates.d AND ab.status IN (''confirmed'',''deposit_paid'',''paid'',''active'') GROUP BY dates.d), covers AS (SELECT dates.d, COUNT(*) FILTER (WHERE rr.booking_type=''Lunch'')   AS lunch_count, COUNT(*) FILTER (WHERE rr.booking_type=''Dinner'') AS dinner_count, COUNT(*) FILTER (WHERE rr.booking_type=''Sunday'') AS sunday_count FROM dates LEFT JOIN restaurant_reservations rr ON rr.reservation_at::date = dates.d AND rr.status IN (''confirmed'',''enquiry'',''arrived'') GROUP BY dates.d) SELECT dates.d AS day, COALESCE(wx.max_temp_c, wd.peak_temp_c) AS max_temp, COALESCE(wx.rain_mm, wd.rain_mm) AS rain_mm, wx.precipitation_probability, wx.weather_code, wx.sunrise, wx.sunset, rooms.booked AS rooms_booked, covers.lunch_count, covers.dinner_count, covers.sunday_count FROM dates LEFT JOIN wx ON wx.forecast_date = dates.d LEFT JOIN wd ON wd.d = dates.d LEFT JOIN rooms USING (d) LEFT JOIN covers USING (d) ORDER BY dates.d',
   'Dashboard 7-day strip with weather + room/cover counts',
   'u127','owner',1, ARRAY['week strip','7 day forecast'],
   now(),'u127'),

  -- Today's checkins with name + room
  ('dashboard_checkins_today',
   'U127 — checkins today (names+rooms)',
   'SELECT guest_name, room, COALESCE(total_amount, gross_amount, 0) AS amount, payment_status, party_size FROM accommodation_bookings WHERE checkin_date = CURRENT_DATE AND status IN (''confirmed'',''deposit_paid'',''paid'',''active'') ORDER BY room',
   'Tonight arrivals: name + room',
   'u127','owner',1, ARRAY['checkins today','arrivals today'],
   now(),'u127'),

  -- Today's checkouts
  ('dashboard_checkouts_today',
   'U127 — checkouts today (names+rooms)',
   'SELECT guest_name, room, COALESCE(total_amount, gross_amount, 0) AS amount, payment_status FROM accommodation_bookings WHERE checkout_date = CURRENT_DATE AND status IN (''confirmed'',''deposit_paid'',''paid'',''active'') ORDER BY room',
   'Today departures: name + room',
   'u127','owner',1, ARRAY['checkouts today','departures today'],
   now(),'u127'),

  -- Lunch/dinner cover counts today
  ('dashboard_covers_today',
   'U127 — lunch/dinner covers today',
   'SELECT COUNT(*) FILTER (WHERE booking_type=''Lunch'')  AS lunch_count, COUNT(*) FILTER (WHERE booking_type=''Dinner'') AS dinner_count, COUNT(*) FILTER (WHERE booking_type=''Sunday'') AS sunday_count, SUM(party_size) FILTER (WHERE booking_type=''Lunch'')  AS lunch_pax, SUM(party_size) FILTER (WHERE booking_type=''Dinner'') AS dinner_pax, COUNT(*) FILTER (WHERE party_size >= 8) AS group_count FROM restaurant_reservations WHERE reservation_at::date = CURRENT_DATE AND status IN (''confirmed'',''enquiry'',''arrived'')',
   'Restaurant covers today by service + group count',
   'u127','owner',1, ARRAY['covers today','dinner count'],
   now(),'u127'),

  -- Special occasions — bank holiday + group bookings + restaurant party >= 8
  ('dashboard_special_today',
   'U127 — special occasions today',
   'SELECT ''group_booking''::text AS kind, guest_name AS label, party_size AS detail, reservation_at::text AS notes FROM restaurant_reservations WHERE reservation_at::date = CURRENT_DATE AND party_size >= 8 AND status IN (''confirmed'',''enquiry'',''arrived'') UNION ALL SELECT ''group_stay''::text, guest_name, adults + COALESCE(children, 0), checkin_date::text || '' to '' || checkout_date::text FROM accommodation_bookings WHERE checkin_date <= CURRENT_DATE AND checkout_date > CURRENT_DATE AND status IN (''confirmed'',''deposit_paid'',''paid'',''active'') AND adults + COALESCE(children, 0) >= 4 ORDER BY 1',
   'Special occasions: large reservations + group stays',
   'u127','owner',1, ARRAY['special occasions','group bookings'],
   now(),'u127')

ON CONFLICT (slug) DO UPDATE SET
  sql_template=EXCLUDED.sql_template, approved_at=now(), approved_by='u127';

COMMIT;
