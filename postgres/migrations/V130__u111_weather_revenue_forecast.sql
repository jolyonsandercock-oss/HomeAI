-- =============================================================================
-- V130 — U111: weather-conditioned revenue forecast
-- =============================================================================
-- Jo asked for "trends against weather data (food, drink and ice cream
-- sales — intelligent forecasting)". This builds the simplest workable
-- predictor:
--
--   historical avg revenue per (category × weather_band × day-of-week)
--   over the trailing 90 days, joined to tomorrow's cached forecast →
--   predicted revenue tomorrow per category.
--
-- Bands are intentionally coarse — with ~3 months of dense data per band,
-- finer slicing would just add noise. As the historical archive grows
-- (V46 has been running since April) we can refine to (temp_bucket ×
-- rain_bucket × dow) without changing this view's downstream shape.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- Band classifier — IMMUTABLE so we can use it as a generated column or
-- across the join axis without re-evaluating per row.
CREATE OR REPLACE FUNCTION public.weather_band(rain_mm NUMERIC, peak_temp_c NUMERIC)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN peak_temp_c IS NULL OR rain_mm IS NULL THEN 'unknown'
    WHEN peak_temp_c >= 17 AND rain_mm < 2  THEN 'warm-dry'
    WHEN peak_temp_c >= 12 AND rain_mm < 2  THEN 'mild-dry'
    WHEN rain_mm     >= 5                   THEN 'wet'
    ELSE 'mid'
  END
$$;
COMMENT ON FUNCTION public.weather_band(numeric, numeric) IS
'U111 V130. Coarse-grained weather classifier: warm-dry / mild-dry / mid / wet.';

-- Bucketed category for revenue forecasting. Maps the touchoffice
-- department labels onto the buckets we actually surface in the daily
-- email (drinks / food / accom / ice cream / cafe-other).
DROP VIEW IF EXISTS v_category_band_baseline CASCADE;
CREATE VIEW v_category_band_baseline AS
WITH dept_to_cat AS (
  SELECT s.report_date,
         EXTRACT(DOW FROM s.report_date)::int AS dow,
         CASE
           WHEN s.site='malthouse' AND (s.department='ALCOHOL SALES' OR s.department='HOT DRINKS') THEN 'wet'
           WHEN s.site='malthouse' AND s.department='FOOD SALES'   THEN 'food'
           WHEN s.site='malthouse' AND s.department='ACCOM'        THEN 'accom'
           WHEN s.site='sandwich'  AND s.department='Cafe Ice Cream' THEN 'icecream'
           WHEN s.site='sandwich'                                  THEN 'cafe-other'
         END AS category,
         s.value,
         public.weather_band(w.rain_mm, w.peak_temp_c) AS band
    FROM touchoffice_department_sales s
    JOIN weather_daily w ON w.observation_date = s.report_date
   WHERE s.report_date BETWEEN CURRENT_DATE - 90 AND CURRENT_DATE - 1
),
agg AS (
  SELECT category, band, dow,
         COUNT(*) AS days,
         ROUND(AVG(value)::numeric, 2)            AS avg_value,
         ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY value))::numeric, 2) AS median_value
    FROM dept_to_cat
   WHERE category IS NOT NULL
   GROUP BY category, band, dow
)
SELECT * FROM agg;

COMMENT ON VIEW v_category_band_baseline IS
'U111 V130. Per (category × weather band × day-of-week) avg + median
revenue over trailing 90 days. Feeds v_revenue_forecast_tomorrow.';

-- Tomorrow's forecast → category predictions
DROP VIEW IF EXISTS v_revenue_forecast_tomorrow CASCADE;
CREATE VIEW v_revenue_forecast_tomorrow AS
WITH tom AS (
  SELECT DISTINCT ON (forecast_date)
    forecast_date,
    public.weather_band(rain_mm, max_temp_c) AS band,
    EXTRACT(DOW FROM forecast_date)::int AS dow,
    max_temp_c, rain_mm, precipitation_probability
    FROM weather_forecast
   WHERE forecast_date = CURRENT_DATE + 1
   ORDER BY forecast_date, fetched_at DESC
)
SELECT
  t.forecast_date,
  t.band,
  t.max_temp_c,
  t.rain_mm,
  t.precipitation_probability,
  c.category,
  c.avg_value    AS forecast_avg,
  c.median_value AS forecast_median,
  c.days         AS sample_days
FROM tom t
LEFT JOIN v_category_band_baseline c
  ON c.band = t.band AND c.dow = t.dow
ORDER BY c.category;

COMMENT ON VIEW v_revenue_forecast_tomorrow IS
'U111 V130. Tomorrow predicted revenue per category given forecast
weather band + day-of-week, looked up against last-90d baseline.';

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES (
  'revenue_forecast_tomorrow',
  'U111 — tomorrow revenue forecast',
  'SELECT * FROM v_revenue_forecast_tomorrow',
  'Predicted tomorrow revenue per category based on forecast weather + DOW',
  'u111','owner',1, ARRAY['forecast','tomorrow revenue','weather forecast'],
  now(),'u111'
) ON CONFLICT (slug) DO UPDATE SET
  sql_template=EXCLUDED.sql_template, approved_at=now(), approved_by='u111';

COMMIT;
