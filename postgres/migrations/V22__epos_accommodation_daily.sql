-- V22: epos_daily + accommodation_daily tables for P5/P6
--
-- Phase 1 Pipelines 5 + 6: deterministic ingestion of TouchOffice ICRTouch
-- Z-reports + Caterbook accommodation reports. RLS-scoped to entity 1
-- (Atlantic Road Trading — pub).
--
-- Idempotency: (report_date, session) for EPOS, (report_date) for accommodation.
-- ON CONFLICT DO UPDATE so re-ingestion of the same report just refreshes values.

\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS epos_daily (
  id              BIGSERIAL PRIMARY KEY,
  entity_id       INTEGER NOT NULL DEFAULT 1,  -- always 1 (Trading)
  report_date     DATE    NOT NULL,
  session         TEXT    NOT NULL,             -- Lunch / Dinner / Breakfast / etc.
  gross           NUMERIC(10,2),
  net             NUMERIC(10,2),
  vat             NUMERIC(10,2),
  covers          INTEGER,
  email_id        BIGINT REFERENCES emails(id),
  source_event_id BIGINT,
  raw_text        TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT epos_daily_uq UNIQUE (entity_id, report_date, session)
);

CREATE INDEX IF NOT EXISTS idx_epos_daily_date ON epos_daily (report_date DESC);
CREATE INDEX IF NOT EXISTS idx_epos_daily_email ON epos_daily (email_id);

ALTER TABLE epos_daily ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS epos_daily_rls ON epos_daily;
CREATE POLICY epos_daily_rls ON epos_daily
  FOR ALL
  USING (current_setting('app.current_entity', true) IN ('all', entity_id::text));

GRANT SELECT, INSERT, UPDATE ON epos_daily TO homeai_pipeline;
GRANT USAGE  ON SEQUENCE epos_daily_id_seq TO homeai_pipeline;
GRANT SELECT ON epos_daily TO homeai_readonly;

CREATE TABLE IF NOT EXISTS accommodation_daily (
  id              BIGSERIAL PRIMARY KEY,
  entity_id       INTEGER NOT NULL DEFAULT 1,
  report_date     DATE    NOT NULL,
  occupancy_pct   NUMERIC(5,2),
  rooms_occupied  INTEGER,
  total_rooms     INTEGER,
  adr             NUMERIC(8,2),                  -- average daily rate
  revpar          NUMERIC(8,2),                  -- revenue per available room
  room_revenue    NUMERIC(10,2),
  email_id        BIGINT REFERENCES emails(id),
  source_event_id BIGINT,
  raw_text        TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT accommodation_daily_uq UNIQUE (entity_id, report_date)
);

CREATE INDEX IF NOT EXISTS idx_accom_daily_date ON accommodation_daily (report_date DESC);
CREATE INDEX IF NOT EXISTS idx_accom_daily_email ON accommodation_daily (email_id);

ALTER TABLE accommodation_daily ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS accommodation_daily_rls ON accommodation_daily;
CREATE POLICY accommodation_daily_rls ON accommodation_daily
  FOR ALL
  USING (current_setting('app.current_entity', true) IN ('all', entity_id::text));

GRANT SELECT, INSERT, UPDATE ON accommodation_daily TO homeai_pipeline;
GRANT USAGE  ON SEQUENCE accommodation_daily_id_seq TO homeai_pipeline;
GRANT SELECT ON accommodation_daily TO homeai_readonly;

SELECT 'V22 ready' AS check,
       (SELECT COUNT(*) FROM information_schema.tables
         WHERE table_name IN ('epos_daily','accommodation_daily')
           AND table_schema='public')::text || ' tables' AS detail;
