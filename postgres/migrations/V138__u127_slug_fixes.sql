-- V138 — U127: fix the three slug bugs in V137
--   - labour: cartesian-product blow-up (labour × sales rows)
--   - week_strip: USING(d) conflict from common column name
--   - checkins_today: party_size doesn't exist on accommodation_bookings
BEGIN;
SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES
  ('dashboard_labour_yesterday',
   'U127 — labour vs sales yesterday + rolling',
   'WITH windows(w) AS (VALUES (1),(7),(30)),
    labour_by_day AS (
      SELECT report_date AS d,
             SUM(cost_with_oncost) FILTER (WHERE team IN (''kitchen'',''front_of_house'',''accommodation'')) AS pub_labour,
             SUM(cost_with_oncost) FILTER (WHERE team = ''cafe'') AS cafe_labour
        FROM v_daily_labour_by_team
       WHERE report_date BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE - 1
       GROUP BY report_date
    ),
    sales_by_day AS (
      SELECT report_date AS d,
             SUM(value) FILTER (WHERE site = ''malthouse'') AS pub_sales,
             SUM(value) FILTER (WHERE site = ''sandwich'')  AS cafe_sales
        FROM touchoffice_department_sales
       WHERE report_date BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE - 1
       GROUP BY report_date
    )
    SELECT w.w AS window_days,
           ROUND(AVG(l.pub_labour)::numeric, 2)  AS pub_labour_avg,
           ROUND(AVG(s.pub_sales)::numeric,  2)  AS pub_sales_avg,
           ROUND(AVG(l.cafe_labour)::numeric, 2) AS cafe_labour_avg,
           ROUND(AVG(s.cafe_sales)::numeric,  2) AS cafe_sales_avg
      FROM windows w
      LEFT JOIN labour_by_day l ON l.d >= CURRENT_DATE - w.w AND l.d < CURRENT_DATE
      LEFT JOIN sales_by_day  s ON s.d = l.d
     GROUP BY w.w
     ORDER BY w.w',
   'Labour cost vs sales yesterday + 7d/30d rolling — pub/cafe split',
   'u127','owner',1, ARRAY['labour vs sales','wage pct rolling'],
   now(),'u127'),

  ('dashboard_week_strip',
   'U127 — 7-day strip with weather + bookings',
   'WITH dates AS (
      SELECT generate_series(CURRENT_DATE - INTERVAL ''3 days'', CURRENT_DATE + INTERVAL ''3 days'', INTERVAL ''1 day'')::date AS d
    ),
    wx AS (
      SELECT DISTINCT ON (forecast_date) forecast_date AS d,
             max_temp_c, min_temp_c, rain_mm, precipitation_probability,
             weather_code, max_wind_mph,
             sunrise AT TIME ZONE ''Europe/London'' AS sunrise,
             sunset  AT TIME ZONE ''Europe/London'' AS sunset
        FROM weather_forecast
       WHERE forecast_date BETWEEN CURRENT_DATE - INTERVAL ''3 days'' AND CURRENT_DATE + INTERVAL ''3 days''
       ORDER BY forecast_date, fetched_at DESC
    ),
    wd AS (
      SELECT observation_date AS d, peak_temp_c, rain_mm, max_wind_mph
        FROM weather_daily
       WHERE observation_date BETWEEN CURRENT_DATE - INTERVAL ''3 days'' AND CURRENT_DATE - INTERVAL ''1 day''
    ),
    rooms AS (
      SELECT dates.d, COUNT(DISTINCT ab.id) AS booked
        FROM dates
        LEFT JOIN accommodation_bookings ab
          ON ab.checkin_date <= dates.d AND ab.checkout_date > dates.d
         AND ab.status IN (''confirmed'',''deposit_paid'',''paid'',''active'')
       GROUP BY dates.d
    ),
    covers AS (
      SELECT dates.d,
             COUNT(*) FILTER (WHERE rr.booking_type = ''Lunch'')   AS lunch_count,
             COUNT(*) FILTER (WHERE rr.booking_type = ''Dinner'')  AS dinner_count,
             COUNT(*) FILTER (WHERE rr.booking_type = ''Sunday'')  AS sunday_count
        FROM dates
        LEFT JOIN restaurant_reservations rr
          ON rr.reservation_at::date = dates.d
         AND rr.status IN (''confirmed'',''enquiry'',''arrived'')
       GROUP BY dates.d
    )
    SELECT dates.d AS day,
           COALESCE(wx.max_temp_c, wd.peak_temp_c)::numeric AS max_temp,
           COALESCE(wx.rain_mm,   wd.rain_mm)::numeric     AS rain_mm,
           wx.precipitation_probability,
           wx.weather_code,
           wx.sunrise, wx.sunset,
           rooms.booked AS rooms_booked,
           covers.lunch_count, covers.dinner_count, covers.sunday_count
      FROM dates
      LEFT JOIN wx     ON wx.d     = dates.d
      LEFT JOIN wd     ON wd.d     = dates.d
      LEFT JOIN rooms  ON rooms.d  = dates.d
      LEFT JOIN covers ON covers.d = dates.d
     ORDER BY dates.d',
   'Dashboard 7-day strip with weather + room/cover counts',
   'u127','owner',1, ARRAY['week strip','7 day forecast'],
   now(),'u127'),

  ('dashboard_checkins_today',
   'U127 — checkins today (names+rooms)',
   'SELECT guest_name, room,
           COALESCE(total_amount, gross_amount, 0) AS amount,
           payment_status,
           (adults + COALESCE(children, 0)) AS party_size
      FROM accommodation_bookings
     WHERE checkin_date = CURRENT_DATE
       AND status IN (''confirmed'',''deposit_paid'',''paid'',''active'')
     ORDER BY room',
   'Tonight arrivals: name + room',
   'u127','owner',1, ARRAY['checkins today','arrivals today'],
   now(),'u127')

ON CONFLICT (slug) DO UPDATE SET
  sql_template = EXCLUDED.sql_template, approved_at = now(), approved_by = 'u127';

COMMIT;
