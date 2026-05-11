-- V25: accommodation_bookings — per-reservation rows from Caterbook emails
--
-- Distinct from accommodation_daily (occupancy aggregate). One row per booking
-- reference. Status tracks New/Cancelled lifecycle so we can trend bookings
-- and compute net rooms-sold from cancellations.
--
-- Idempotency: (entity_id, source, source_ref) — the booking reference is
-- unique within a channel.
--
-- RLS-scoped to entity 1 (Atlantic Road Trading — pub).

\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS accommodation_bookings (
  id              BIGSERIAL PRIMARY KEY,
  entity_id       INTEGER NOT NULL DEFAULT 1,
  source          TEXT    NOT NULL,                    -- agoda / booking.com / ctrip / direct …
  source_ref      TEXT    NOT NULL,                    -- channel booking ID, e.g. 657887135_L-1420
  status          TEXT    NOT NULL,                    -- Confirmed / Cancelled / Modified
  guest_name      TEXT,
  room            TEXT,                                -- 'Room 7 - Twin Room'
  checkin_date    DATE,
  checkout_date   DATE,
  adults          INTEGER,
  children        INTEGER,
  meal_plan       TEXT,
  currency        TEXT,
  gross_amount    NUMERIC(10,2),
  commission      NUMERIC(10,2),
  tax             NUMERIC(10,2),
  total_amount    NUMERIC(10,2),
  email_id        BIGINT REFERENCES emails(id),
  source_event_id BIGINT,
  raw_text        TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT accommodation_bookings_uq UNIQUE (entity_id, source, source_ref)
);

CREATE INDEX IF NOT EXISTS idx_accom_bookings_checkin ON accommodation_bookings (checkin_date);
CREATE INDEX IF NOT EXISTS idx_accom_bookings_status  ON accommodation_bookings (status);
CREATE INDEX IF NOT EXISTS idx_accom_bookings_email   ON accommodation_bookings (email_id);

ALTER TABLE accommodation_bookings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS accommodation_bookings_rls ON accommodation_bookings;
CREATE POLICY accommodation_bookings_rls ON accommodation_bookings
  FOR ALL
  USING (current_setting('app.current_entity', true) IN ('all', entity_id::text));

GRANT SELECT, INSERT, UPDATE ON accommodation_bookings TO homeai_pipeline;
GRANT USAGE  ON SEQUENCE accommodation_bookings_id_seq TO homeai_pipeline;
GRANT SELECT ON accommodation_bookings TO homeai_readonly;

SELECT 'V25 ready' AS check,
       (SELECT COUNT(*) FROM information_schema.tables
         WHERE table_name='accommodation_bookings'
           AND table_schema='public')::text || ' table(s)' AS detail;
