-- =============================================================================
-- V122 — U101: restaurant_reservations table for Collins/DesignMyNight
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

CREATE TABLE IF NOT EXISTS restaurant_reservations (
  id                  BIGSERIAL PRIMARY KEY,
  entity_id           INTEGER NOT NULL DEFAULT 1,
  source              TEXT NOT NULL DEFAULT 'collins',
  source_ref          TEXT NOT NULL,                     -- DMN-16950863730
  status              TEXT NOT NULL DEFAULT 'confirmed'
    CHECK (status IN ('confirmed','enquiry','cancelled','no_show','arrived','superseded')),
  reservation_at      TIMESTAMPTZ,                       -- when they're coming
  party_size          INTEGER,
  guest_name          TEXT,
  guest_email         TEXT,
  guest_phone         TEXT,
  booking_type        TEXT,                              -- dinner / lunch / drinks
  collins_url         TEXT,
  source_email_id     TEXT,
  source_account      TEXT,
  raw_text            TEXT,
  ingested_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  realm               TEXT NOT NULL DEFAULT 'work'
    CHECK (realm IN ('owner','work','family','shared')),
  UNIQUE (source, source_ref)
);

CREATE INDEX IF NOT EXISTS idx_rest_res_at
  ON restaurant_reservations (reservation_at);
CREATE INDEX IF NOT EXISTS idx_rest_res_status
  ON restaurant_reservations (status);

ALTER TABLE restaurant_reservations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS realm_isolation ON restaurant_reservations;
CREATE POLICY realm_isolation ON restaurant_reservations
  USING (CASE
    WHEN COALESCE(current_setting('app.current_realm', true), '') IN ('', 'owner') THEN TRUE
    ELSE realm = current_setting('app.current_realm', true)
  END);

GRANT SELECT ON restaurant_reservations TO PUBLIC;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'homeai_pipeline') THEN
    EXECUTE 'GRANT INSERT, UPDATE, SELECT ON restaurant_reservations TO homeai_pipeline';
    EXECUTE 'GRANT USAGE, SELECT ON restaurant_reservations_id_seq TO homeai_pipeline';
  END IF;
END$$;

-- View: today's restaurant reservations
DROP VIEW IF EXISTS v_today_restaurant CASCADE;
CREATE VIEW v_today_restaurant AS
SELECT id, source_ref, status, reservation_at, party_size,
       guest_name, booking_type, collins_url
FROM restaurant_reservations
WHERE reservation_at::date = CURRENT_DATE
  AND status IN ('confirmed','enquiry','arrived')
ORDER BY reservation_at;

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES (
  'today_restaurant',
  'U101 — today restaurant reservations',
  'SELECT * FROM v_today_restaurant',
  'Today restaurant reservations from Collins/DesignMyNight',
  'u101','owner',1, ARRAY['restaurant tonight','tonight covers'],
  now(),'u101'
) ON CONFLICT (slug) DO UPDATE
  SET sql_template=EXCLUDED.sql_template, approved_at=now(), approved_by='u101';

COMMIT;
