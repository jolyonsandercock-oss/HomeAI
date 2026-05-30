-- Companion SQL to /home_ai/docs/analysis-2026-05-30-sunset-vs-food.md
-- Run via: docker exec -i homeai-postgres psql -U postgres -d homeai < this-file.sql

-- Block 1: naïve Pearson correlation + slices + monthly stats.
WITH daily AS (
  SELECT
    s.report_date,
    EXTRACT(EPOCH FROM (w.sunset - date_trunc('day', w.sunset))) / 60.0 AS sunset_minutes,
    EXTRACT(DOW   FROM s.report_date) AS dow,
    EXTRACT(MONTH FROM s.report_date) AS month,
    w.rain_mm,
    w.peak_temp_c,
    SUM(s.value) FILTER (WHERE s.department = 'FOOD SALES') AS food_sales
  FROM touchoffice_department_sales s
  JOIN weather_daily w ON w.observation_date = s.report_date
  WHERE s.site = 'malthouse'
    AND w.sunset IS NOT NULL
  GROUP BY s.report_date, w.sunset, w.rain_mm, w.peak_temp_c
  HAVING SUM(s.value) FILTER (WHERE s.department = 'FOOD SALES') > 0
)
SELECT
  COUNT(*)                                                              AS n_days,
  ROUND(CORR(sunset_minutes, food_sales)::numeric, 4)                   AS pearson_overall,
  ROUND(CORR(sunset_minutes, food_sales) FILTER (WHERE dow IN (1,2,3,4))::numeric, 4) AS pearson_weekdays,
  ROUND(CORR(sunset_minutes, food_sales) FILTER (WHERE dow IN (0,5,6))::numeric, 4)   AS pearson_fri_sat_sun,
  ROUND(CORR(sunset_minutes, food_sales) FILTER (WHERE rain_mm < 1)::numeric, 4)      AS pearson_dry_days,
  ROUND(CORR(peak_temp_c,    food_sales)::numeric, 4)                   AS pearson_temp_vs_food,
  ROUND(AVG(food_sales)::numeric, 0)                                    AS mean_food_gbp,
  ROUND(STDDEV(food_sales)::numeric, 0)                                 AS sd_food_gbp,
  TO_CHAR(MIN(report_date),'YYYY-MM-DD')                                AS start_date,
  TO_CHAR(MAX(report_date),'YYYY-MM-DD')                                AS end_date
FROM daily;

-- Block 2: confounder control — subtract per-month means from BOTH sides,
-- then correlate the residuals.
WITH daily AS (
  SELECT
    s.report_date,
    EXTRACT(EPOCH FROM (w.sunset - date_trunc('day', w.sunset))) / 60.0 AS sunset_minutes,
    EXTRACT(MONTH FROM s.report_date) AS month,
    SUM(s.value) FILTER (WHERE s.department = 'FOOD SALES') AS food_sales
  FROM touchoffice_department_sales s
  JOIN weather_daily w ON w.observation_date = s.report_date
  WHERE s.site = 'malthouse' AND w.sunset IS NOT NULL
  GROUP BY s.report_date, w.sunset
  HAVING SUM(s.value) FILTER (WHERE s.department = 'FOOD SALES') > 0
), residuals AS (
  SELECT
    d.*,
    d.food_sales     - AVG(d.food_sales)     OVER (PARTITION BY d.month) AS food_resid_month,
    d.sunset_minutes - AVG(d.sunset_minutes) OVER (PARTITION BY d.month) AS sunset_resid_month
  FROM daily d
)
SELECT
  ROUND(CORR(sunset_resid_month, food_resid_month)::numeric, 4) AS within_month_correlation,
  COUNT(*)                                                      AS n
FROM residuals;
