-- ============================================================
-- U28 — Caterbook accommodation tables (Pipeline 6)
-- ============================================================
-- Approach: observation-then-derive.
-- Each "Arrivals and Departures" email is a SNAPSHOT of who's arriving/
-- in-residence/departing on its report_date. A single email never gives
-- both arrival_date AND departure_date for the same booking. To get the
-- "revenue per room per night" trend we want, we:
--   1. Persist each email's raw observations into caterbook_observations
--      (one row per (report_date, ref, room) appearing in the PDF).
--   2. Derive caterbook_bookings as a view/query: one row per (ref, room)
--      where arrival_date = MIN(observations.report_date WHERE
--      section='arrivals'), departure_date = MAX(stay_through.departure_date)
--      coalesced with MAX(report_date WHERE section='departures').
--   3. Derive caterbook_room_nights as a SQL view exploding bookings
--      by night (rate_per_night = total_amount / nights_in_stay).
--
-- entity_id defaults to 1 (Atlantic Road Trading Ltd). RLS mirrors the
-- pattern used by touchoffice_* and epos_daily_reports.
-- ============================================================

-- ── 1. caterbook_email_reports ─────────────────────────────
CREATE TABLE caterbook_email_reports (
  id                BIGSERIAL PRIMARY KEY,
  idempotency_key   TEXT NOT NULL UNIQUE,
  source_email_id   TEXT NOT NULL,           -- Gmail message id (e.g. 19a9a817bb0d4706)
  account           TEXT NOT NULL,           -- google-fetch account name (e.g. 'info')
  entity_id         INT NOT NULL DEFAULT 1,
  report_date       DATE NOT NULL,
  received_at       TIMESTAMPTZ NOT NULL,
  arrivals_count    INT,
  stayovers_count   INT,
  departures_count  INT,
  total_balance_seen NUMERIC(14,2),
  raw_pdf_path      TEXT,
  raw_text_path     TEXT,
  ingested_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (source_email_id)
);
CREATE INDEX idx_cb_reports_date ON caterbook_email_reports (report_date);

ALTER TABLE caterbook_email_reports ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON caterbook_email_reports
  USING (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'        THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'      THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END)
  WITH CHECK (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'        THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'      THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END);

-- ── 2. caterbook_observations ─────────────────────────────
-- One row per appearance of a (ref, room) in a daily snapshot.
CREATE TABLE caterbook_observations (
  id                BIGSERIAL PRIMARY KEY,
  idempotency_key   TEXT NOT NULL UNIQUE,    -- sha256(report_date+ref+room+section)
  email_report_id   BIGINT REFERENCES caterbook_email_reports(id) ON DELETE CASCADE,
  entity_id         INT NOT NULL DEFAULT 1,
  report_date       DATE NOT NULL,
  section           TEXT NOT NULL CHECK (section IN ('arrivals','stayovers','departures')),
  -- Row fields verbatim from the PDF (canonicalised but unjoined):
  guest_name        TEXT NOT NULL,
  room              TEXT NOT NULL,           -- e.g. 'Rm1', 'suite-9'
  ref               TEXT NOT NULL,           -- booking ref (e.g. '8106')
  room_type         TEXT,                    -- e.g. 'Suite', '1-dbl'
  rate_code         TEXT,                    -- e.g. 'bb' (B&B), 'ro'
  guests_code       TEXT,                    -- e.g. '2A', '3A' (Caterbook's adult-count notation)
  contact           TEXT,                    -- phone / email if present
  status            TEXT,                    -- e.g. 'To arrive', 'Checked in'
  balance           NUMERIC(12,2),           -- the £ amount shown in this row
  -- Only present for the stayovers section: when the guest leaves.
  departure_date_seen DATE,
  -- "Early check-in" / "Late check-out" flag column from arrivals/departures.
  early_or_late_flag TEXT,
  raw_cells         JSONB,                   -- safety net for unforeseen layouts
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (report_date, ref, room, section)
);
CREATE INDEX idx_cb_obs_ref_room  ON caterbook_observations (ref, room);
CREATE INDEX idx_cb_obs_date      ON caterbook_observations (report_date);
CREATE INDEX idx_cb_obs_room_date ON caterbook_observations (room, report_date);

ALTER TABLE caterbook_observations ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON caterbook_observations
  USING (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'        THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'      THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END)
  WITH CHECK (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'        THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'      THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END);

-- ── 3. Derived view: caterbook_bookings ─────────────────────
-- One row per unique (ref, room) collated across all observations.
CREATE VIEW caterbook_bookings AS
WITH per_obs AS (
  SELECT
    ref,
    room,
    MAX(CASE WHEN section = 'arrivals'   THEN guest_name END)  AS guest_name_at_arrival,
    MAX(CASE WHEN section = 'arrivals'   THEN room_type  END)  AS room_type,
    MAX(CASE WHEN section = 'arrivals'   THEN rate_code  END)  AS rate_code,
    MAX(CASE WHEN section = 'arrivals'   THEN guests_code END) AS guests_code,
    MAX(CASE WHEN section = 'arrivals'   THEN contact    END)  AS contact,
    MIN(CASE WHEN section = 'arrivals'   THEN report_date END) AS arrival_date,
    -- Departure: prefer the explicit date from a stayovers row; fall back to
    -- the day we last see them in the departures section.
    COALESCE(
      MAX(CASE WHEN section = 'stayovers'  THEN departure_date_seen END),
      MAX(CASE WHEN section = 'departures' THEN report_date END)
    ) AS departure_date,
    -- Latest non-null balance seen across observations.
    (ARRAY_AGG(balance ORDER BY report_date DESC) FILTER (WHERE balance IS NOT NULL))[1] AS latest_balance,
    MAX(entity_id) AS entity_id,
    MIN(report_date) AS first_seen,
    MAX(report_date) AS last_seen,
    COUNT(*) AS observation_count
  FROM caterbook_observations
  GROUP BY ref, room
)
SELECT
  ref,
  room,
  guest_name_at_arrival AS guest_name,
  room_type,
  rate_code,
  guests_code,
  contact,
  arrival_date,
  departure_date,
  latest_balance AS total_amount,
  CASE
    WHEN arrival_date IS NOT NULL AND departure_date IS NOT NULL
    THEN GREATEST((departure_date - arrival_date)::int, 1)
    ELSE NULL
  END AS nights_in_stay,
  CASE
    WHEN arrival_date IS NOT NULL AND departure_date IS NOT NULL AND latest_balance IS NOT NULL
    THEN ROUND(latest_balance / GREATEST((departure_date - arrival_date)::int, 1), 2)
    ELSE NULL
  END AS rate_per_night,
  entity_id,
  first_seen,
  last_seen,
  observation_count
FROM per_obs;

-- ── 4. Derived view: caterbook_room_nights ─────────────────
-- Explodes each booking into one row per occupied night.
CREATE VIEW caterbook_room_nights AS
SELECT
  b.ref,
  b.room,
  b.guest_name,
  b.room_type,
  b.rate_code,
  (b.arrival_date + gs)::date AS night_date,
  b.rate_per_night,
  b.nights_in_stay,
  b.arrival_date,
  b.departure_date,
  b.total_amount,
  b.entity_id
FROM caterbook_bookings b
CROSS JOIN LATERAL generate_series(0, GREATEST(b.nights_in_stay - 1, 0)) AS gs
WHERE b.arrival_date IS NOT NULL
  AND b.departure_date IS NOT NULL
  AND b.nights_in_stay > 0;

-- ── 5. Daily snapshot table — drives the dashboard cards ────
CREATE TABLE caterbook_daily_snapshots (
  id                BIGSERIAL PRIMARY KEY,
  idempotency_key   TEXT NOT NULL UNIQUE,    -- 'cb_snap_<report_date>'
  email_report_id   BIGINT REFERENCES caterbook_email_reports(id) ON DELETE CASCADE,
  entity_id         INT NOT NULL DEFAULT 1,
  report_date       DATE NOT NULL UNIQUE,
  arrivals          JSONB NOT NULL,
  stayovers         JSONB NOT NULL,
  departures        JSONB NOT NULL,
  arrivals_count    INT NOT NULL,
  stayovers_count   INT NOT NULL,
  departures_count  INT NOT NULL,
  in_house_count    INT,                     -- stayovers + arrivals
  revenue_in_house  NUMERIC(14,2),           -- sum of latest balance for in-house guests
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_cb_snap_date ON caterbook_daily_snapshots (report_date);

ALTER TABLE caterbook_daily_snapshots ENABLE ROW LEVEL SECURITY;
CREATE POLICY entity_isolation ON caterbook_daily_snapshots
  USING (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'        THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'      THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END)
  WITH CHECK (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all'        THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'      THEN entity_id = current_setting('app.current_entity', true)::int
      ELSE false
    END);

-- ── 6. Grants ────────────────────────────────────────────────
GRANT SELECT, INSERT, UPDATE, DELETE ON
  caterbook_email_reports,
  caterbook_observations,
  caterbook_daily_snapshots
TO homeai_pipeline;

GRANT USAGE, SELECT ON
  caterbook_email_reports_id_seq,
  caterbook_observations_id_seq,
  caterbook_daily_snapshots_id_seq
TO homeai_pipeline;

GRANT SELECT ON
  caterbook_email_reports,
  caterbook_observations,
  caterbook_bookings,
  caterbook_room_nights,
  caterbook_daily_snapshots
TO homeai_readonly;
