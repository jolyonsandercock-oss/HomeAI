-- =============================================================================
-- V143 — U133 T1: week strip pivots to "today + 6 days forward"
-- =============================================================================
-- The strip used to be CURRENT_DATE ± 3 days. Past days are clutter — Jo's
-- planning value is forward-looking. Today is now always the leftmost tile.
-- All weather/rooms/covers windows widen to match.
-- =============================================================================

BEGIN;

UPDATE query_whitelist
   SET sql_template = $sql$WITH dates AS (
      SELECT generate_series(CURRENT_DATE, CURRENT_DATE + INTERVAL '6 days', INTERVAL '1 day')::date AS d
    ),
    wx AS (
      SELECT DISTINCT ON (forecast_date) forecast_date AS d,
             max_temp_c, min_temp_c, rain_mm, precipitation_probability,
             weather_code, max_wind_mph,
             sunrise AT TIME ZONE 'Europe/London' AS sunrise,
             sunset  AT TIME ZONE 'Europe/London' AS sunset
        FROM weather_forecast
       WHERE forecast_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '6 days'
       ORDER BY forecast_date, fetched_at DESC
    ),
    rooms AS (
      SELECT dates.d, COUNT(DISTINCT ab.id) AS booked
        FROM dates
        LEFT JOIN accommodation_bookings ab
          ON ab.checkin_date <= dates.d AND ab.checkout_date > dates.d
         AND ab.status IN ('confirmed','deposit_paid','paid','active')
       GROUP BY dates.d
    ),
    covers AS (
      SELECT dates.d,
             COUNT(*) FILTER (WHERE rr.booking_type = 'Lunch')   AS lunch_count,
             COUNT(*) FILTER (WHERE rr.booking_type = 'Dinner')  AS dinner_count,
             COUNT(*) FILTER (WHERE rr.booking_type = 'Sunday')  AS sunday_count
        FROM dates
        LEFT JOIN restaurant_reservations rr
          ON rr.reservation_at::date = dates.d
         AND rr.status IN ('confirmed','enquiry','arrived')
       GROUP BY dates.d
    )
    SELECT dates.d AS day,
           wx.max_temp_c::numeric AS max_temp,
           wx.rain_mm::numeric    AS rain_mm,
           wx.precipitation_probability,
           wx.weather_code,
           wx.sunrise, wx.sunset,
           rooms.booked AS rooms_booked,
           covers.lunch_count, covers.dinner_count, covers.sunday_count
      FROM dates
      LEFT JOIN wx     ON wx.d     = dates.d
      LEFT JOIN rooms  ON rooms.d  = dates.d
      LEFT JOIN covers ON covers.d = dates.d
     ORDER BY dates.d$sql$,
       approved_at = NOW(),
       notes       = COALESCE(notes, '') || E'\nV143 (U133 T1): pivot to today + 6 days forward; drop weather_daily backfill (forward-only window)'
 WHERE slug = 'dashboard_week_strip';

COMMIT;
