-- =============================================================================
-- V144 — U133 T2: tide_times table + dashboard_tides_next_7d slug
-- =============================================================================
-- Source: weekly Sunday-06:00 scrape of
-- https://www.tidetimes.org.uk/boscastle-tide-times.
-- Cafe trading correlates with low-tide windows on the beach.
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS tide_times (
    id BIGSERIAL PRIMARY KEY,
    tide_date     DATE NOT NULL,
    high_low      TEXT NOT NULL CHECK (high_low IN ('high','low')),
    tide_time     TIME NOT NULL,
    height_m      NUMERIC(4,2),
    location      TEXT NOT NULL DEFAULT 'boscastle',
    source        TEXT NOT NULL DEFAULT 'tidetimes.org.uk',
    scraped_at    TIMESTAMPTZ DEFAULT now(),
    realm         TEXT NOT NULL DEFAULT 'work',
    UNIQUE (location, tide_date, tide_time)
);
CREATE INDEX IF NOT EXISTS idx_tide_times_date ON tide_times (tide_date);

INSERT INTO query_whitelist
    (slug, display_name, description, sql_template, param_schema, result_format,
     active, created_by, approved_at, approved_by, notes, realm)
VALUES
    ('dashboard_tides_next_7d',
     'Tide times — next 7 days',
     'High and low tides for Boscastle, today through today+6. Driven by weekly Sunday scrape of tidetimes.org.uk.',
     'SELECT tide_date AS day, high_low, tide_time, height_m
        FROM tide_times
       WHERE location = ''boscastle''
         AND tide_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL ''6 days''
       ORDER BY tide_date, tide_time',
     '{}'::jsonb,
     'table',
     true,
     'V144-U133T2',
     NOW(),
     'V144-U133T2',
     'Per U133 T2 plan.',
     'work')
ON CONFLICT (slug) DO UPDATE
   SET sql_template = EXCLUDED.sql_template,
       description  = EXCLUDED.description,
       active       = true,
       approved_at  = NOW();

COMMIT;
