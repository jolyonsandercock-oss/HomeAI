-- ============================================================
-- U46 — Weather integration for PL34 0DA (Tintagel)
-- ============================================================
-- Daily actuals + 5-day forecast. Source: Open-Meteo (free, no auth,
-- accurate for UK). Used as a forecasting/staffing input alongside
-- v_daily_unit_economics.
-- ============================================================

CREATE TABLE IF NOT EXISTS weather_daily (
  id                BIGSERIAL PRIMARY KEY,
  observation_date  DATE NOT NULL UNIQUE,
  hours_sunshine    NUMERIC(4,1),
  rain_mm           NUMERIC(6,2),
  avg_temp_c        NUMERIC(4,1),
  peak_temp_c       NUMERIC(4,1),
  min_temp_c        NUMERIC(4,1),
  max_wind_mph      INT,
  source            TEXT NOT NULL DEFAULT 'open-meteo',
  raw_payload       JSONB,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_weather_daily_date ON weather_daily (observation_date DESC);

GRANT SELECT, INSERT, UPDATE ON weather_daily TO homeai_pipeline;
GRANT SELECT ON weather_daily TO homeai_readonly;
GRANT SELECT ON weather_daily TO metabase_app;
GRANT USAGE, SELECT ON SEQUENCE weather_daily_id_seq TO homeai_pipeline;

CREATE TABLE IF NOT EXISTS weather_forecast (
  id                BIGSERIAL PRIMARY KEY,
  forecast_date     DATE NOT NULL,
  fetched_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  rain_mm           NUMERIC(6,2),
  max_temp_c        NUMERIC(4,1),
  min_temp_c        NUMERIC(4,1),
  max_wind_mph      INT,
  alert_categories  TEXT[],
  raw_payload       JSONB,
  UNIQUE (forecast_date, fetched_at)
);

CREATE INDEX IF NOT EXISTS idx_weather_forecast_date ON weather_forecast (forecast_date);

GRANT SELECT, INSERT ON weather_forecast TO homeai_pipeline;
GRANT SELECT ON weather_forecast TO homeai_readonly;
GRANT SELECT ON weather_forecast TO metabase_app;
GRANT USAGE, SELECT ON SEQUENCE weather_forecast_id_seq TO homeai_pipeline;

-- Latest 5-day forecast view
CREATE OR REPLACE VIEW v_weather_5day AS
SELECT DISTINCT ON (forecast_date)
  forecast_date, fetched_at::timestamp(0) AS fetched_at,
  rain_mm, max_temp_c, min_temp_c, max_wind_mph, alert_categories
FROM weather_forecast
WHERE forecast_date >= CURRENT_DATE AND forecast_date <= CURRENT_DATE + 5
ORDER BY forecast_date, fetched_at DESC;

GRANT SELECT ON v_weather_5day TO homeai_pipeline, homeai_readonly, metabase_app;

-- Sales × weather correlation view (joined to daily economics)
CREATE OR REPLACE VIEW v_weather_sales_correlation AS
SELECT
  e.report_date,
  e.pub_net_sales,
  e.sandwich_net_sales,
  e.total_revenue,
  e.total_covers,
  w.rain_mm,
  w.peak_temp_c,
  w.hours_sunshine,
  w.max_wind_mph
FROM v_daily_unit_economics e
LEFT JOIN weather_daily w ON w.observation_date = e.report_date
WHERE e.report_date <= CURRENT_DATE
ORDER BY e.report_date DESC;

GRANT SELECT ON v_weather_sales_correlation TO homeai_pipeline, homeai_readonly, metabase_app;
