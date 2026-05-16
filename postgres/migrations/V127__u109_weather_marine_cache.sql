-- =============================================================================
-- V127 — U109: extend weather_forecast cache for marine + extra fields
-- =============================================================================
-- u109 daily reality v6 hit the open-meteo API on every run. Jo wants the
-- weather + marine + tide data polled once and read from cache. weather_daily
-- + weather_forecast already exist (u46-weather-daily.sh); we just need to
-- add the columns u109 uses so it can stop calling the API directly.
--
-- Adds:
--   weather_forecast.weather_code              (WMO classification 0-99)
--   weather_forecast.precipitation_probability (0-100 rain prob %)
--   weather_forecast.wave_height_m             (open-meteo marine)
--   weather_forecast.wave_period_s             (open-meteo marine)
--   weather_forecast.wave_direction_deg        (open-meteo marine, 0=N)
--   weather_forecast.tide_extremes             (JSONB — high/low pairs, when
--                                                we wire a tide source)
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

ALTER TABLE weather_forecast
  ADD COLUMN IF NOT EXISTS weather_code              INTEGER,
  ADD COLUMN IF NOT EXISTS precipitation_probability INTEGER,
  ADD COLUMN IF NOT EXISTS wave_height_m             NUMERIC(5,2),
  ADD COLUMN IF NOT EXISTS wave_period_s             NUMERIC(5,2),
  ADD COLUMN IF NOT EXISTS wave_direction_deg        INTEGER,
  ADD COLUMN IF NOT EXISTS tide_extremes             JSONB;

COMMENT ON COLUMN weather_forecast.weather_code IS
'U109 V127. WMO weather code (0-99). 0=clear, 61-65=rain, 80-82=showers,
95-99=thunderstorm. See https://open-meteo.com/en/docs#weathervariables';

COMMENT ON COLUMN weather_forecast.wave_height_m IS
'U109 V127. From open-meteo marine API — Trebarwith Strand approximation
(50.66 N, 4.75 W). Daily max significant wave height in metres.';

COMMENT ON COLUMN weather_forecast.tide_extremes IS
'U109 V127. JSONB array of {time, type, height} — high/low tides for the
day. Empty until a tide source is wired (no free API responded without auth).';

COMMIT;
