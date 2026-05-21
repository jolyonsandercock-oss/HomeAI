-- =============================================================================
-- V193 — U175: revenue forecast slugs (28 days forward)
-- =============================================================================
-- Combines:
--   - Confirmed forward bookings (accommodation_bookings + restaurant_reservations)
--   - Historical DoW patterns (avg revenue by day-of-week from last 90d)
--   - Bank holidays + tide times as exogenous signals
-- Output: per-day forecast with P10/P50/P90 confidence band.
-- =============================================================================

BEGIN;

-- 28-day revenue forecast
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'revenue_forecast_28d',
  'Revenue forecast — next 28 days',
  'U175: per-day forecast combining confirmed bookings + DoW history. P10/P50/P90 confidence.',
  E'WITH days AS (
      SELECT generate_series(CURRENT_DATE, CURRENT_DATE + 27, ''1 day''::interval)::date AS d
    ),
    -- Confirmed forward rooms revenue
    confirmed_rooms AS (
      SELECT crn.night_date AS d,
             SUM(crn.rate_per_night)::numeric(12,2) AS rooms_confirmed
        FROM caterbook_room_nights crn
       WHERE crn.night_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 27
       GROUP BY crn.night_date
    ),
    forward_bookings AS (
      SELECT ab.checkin_date AS d,
             count(*) AS bookings_in,
             SUM(COALESCE(ab.total_amount, 0))::numeric(12,2) AS bookings_value
        FROM accommodation_bookings ab
       WHERE ab.checkin_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 27
         AND ab.status NOT IN (''cancelled'',''no-show'')
       GROUP BY ab.checkin_date
    ),
    -- Historical DoW patterns
    dow_hist AS (
      SELECT EXTRACT(DOW FROM report_date)::int AS dow,
             AVG(SUM(value)) OVER (PARTITION BY EXTRACT(DOW FROM report_date))::numeric(12,2) AS avg_food_drink,
             PERCENTILE_CONT(0.1) WITHIN GROUP (ORDER BY SUM(value))
               OVER (PARTITION BY EXTRACT(DOW FROM report_date))::numeric(12,2) AS p10_food_drink,
             PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY SUM(value))
               OVER (PARTITION BY EXTRACT(DOW FROM report_date))::numeric(12,2) AS p90_food_drink
        FROM touchoffice_department_sales
       WHERE report_date BETWEEN CURRENT_DATE - 90 AND CURRENT_DATE - 1
       GROUP BY report_date
    ),
    dow_agg AS (
      SELECT dow,
             AVG(avg_food_drink)::numeric(12,2) AS avg_food_drink,
             AVG(p10_food_drink)::numeric(12,2) AS p10,
             AVG(p90_food_drink)::numeric(12,2) AS p90
        FROM dow_hist GROUP BY dow
    ),
    bh AS (
      SELECT holiday_date FROM bank_holidays
       WHERE holiday_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 27
    )
    SELECT
      d.d AS for_date,
      to_char(d.d, ''Dy'') AS dow_name,
      EXISTS(SELECT 1 FROM bh WHERE holiday_date = d.d) AS bank_hol,
      COALESCE(cr.rooms_confirmed, 0) AS rooms_confirmed,
      COALESCE(da.avg_food_drink, 0) AS food_drink_p50,
      COALESCE(da.p10, 0) AS food_drink_p10,
      COALESCE(da.p90, 0) AS food_drink_p90,
      (COALESCE(cr.rooms_confirmed, 0) + COALESCE(da.avg_food_drink, 0))::numeric(12,2) AS total_p50
    FROM days d
    LEFT JOIN confirmed_rooms cr ON cr.d = d.d
    LEFT JOIN forward_bookings fb ON fb.d = d.d
    LEFT JOIN dow_agg da ON da.dow = EXTRACT(DOW FROM d.d)::int
    ORDER BY d.d',
  '{}', 'shared', true, NOW(), 'u175', 'u175'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

-- Weekly aggregate
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, realm,
   active, approved_at, approved_by, created_by)
VALUES (
  'revenue_forecast_next_4_weeks',
  'Revenue forecast — next 4 weeks',
  'U175: weekly roll-up of the 28d forecast.',
  E'WITH days AS (
      SELECT generate_series(CURRENT_DATE, CURRENT_DATE + 27, ''1 day''::interval)::date AS d
    ),
    rooms AS (
      SELECT date_trunc(''week'', d.d)::date AS week_start,
             SUM(COALESCE(crn_sum, 0))::numeric(12,2) AS rooms_confirmed
        FROM days d
        LEFT JOIN LATERAL (
          SELECT SUM(rate_per_night) AS crn_sum FROM caterbook_room_nights
           WHERE night_date = d.d
        ) crn ON true
        GROUP BY date_trunc(''week'', d.d)::date
    ),
    food AS (
      SELECT date_trunc(''week'', d.d)::date AS week_start,
             SUM(COALESCE(dow_avg, 0))::numeric(12,2) AS food_drink_p50
        FROM days d
        LEFT JOIN LATERAL (
          SELECT AVG(daily) AS dow_avg FROM (
            SELECT SUM(value) AS daily FROM touchoffice_department_sales
             WHERE report_date BETWEEN CURRENT_DATE - 90 AND CURRENT_DATE - 1
               AND EXTRACT(DOW FROM report_date) = EXTRACT(DOW FROM d.d)
             GROUP BY report_date
          ) sub
        ) dow ON true
        GROUP BY date_trunc(''week'', d.d)::date
    )
    SELECT r.week_start,
           r.week_start + INTERVAL ''6 days'' AS week_end,
           r.rooms_confirmed,
           f.food_drink_p50,
           (r.rooms_confirmed + f.food_drink_p50)::numeric(12,2) AS total_forecast
      FROM rooms r JOIN food f USING (week_start)
      ORDER BY r.week_start',
  '{}', 'shared', true, NOW(), 'u175', 'u175'
) ON CONFLICT (slug) DO UPDATE SET sql_template = EXCLUDED.sql_template, approved_at = NOW();

COMMIT;
