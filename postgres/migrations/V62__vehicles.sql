-- V62: Vehicle / MOT / insurance / road tax tracker
--
-- Jo runs 4 vehicles across Trading + Personal. Currently tracked in
-- Obsidian markdown; this migration moves them into a queryable table
-- with daily expiry alerts.

BEGIN;

CREATE TABLE IF NOT EXISTS vehicles (
  id                BIGSERIAL PRIMARY KEY,
  registration      TEXT NOT NULL,
  make_model        TEXT NOT NULL,
  year_built        INTEGER,
  v5c_doc_ref       TEXT,
  mot_due           DATE,
  insurance_renewal DATE,
  road_tax_due      DATE,
  service_due_date  DATE,
  service_due_miles INTEGER,
  current_miles     INTEGER,
  entity_id         INTEGER NOT NULL DEFAULT 1,
  notes             TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_vehicles_reg
  ON vehicles (upper(replace(registration, ' ', '')));

ALTER TABLE vehicles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS entity_isolation ON vehicles;
CREATE POLICY entity_isolation ON vehicles
  USING (
    CASE
      WHEN current_setting('app.current_entity', true) = 'all' THEN true
      WHEN current_setting('app.current_entity', true) ~ '^\d+$'
        THEN entity_id = current_setting('app.current_entity', true)::integer
      ELSE false
    END);

CREATE OR REPLACE VIEW v_vehicle_alerts AS
WITH unpivoted AS (
  SELECT id, registration, make_model, entity_id, 'mot' AS kind, mot_due AS due
    FROM vehicles WHERE mot_due IS NOT NULL
  UNION ALL
  SELECT id, registration, make_model, entity_id, 'insurance', insurance_renewal
    FROM vehicles WHERE insurance_renewal IS NOT NULL
  UNION ALL
  SELECT id, registration, make_model, entity_id, 'road_tax', road_tax_due
    FROM vehicles WHERE road_tax_due IS NOT NULL
  UNION ALL
  SELECT id, registration, make_model, entity_id, 'service', service_due_date
    FROM vehicles WHERE service_due_date IS NOT NULL
)
SELECT id AS vehicle_id, registration, make_model, entity_id, kind, due,
       (due - CURRENT_DATE) AS days_until
  FROM unpivoted
 WHERE due <= CURRENT_DATE + INTERVAL '30 days'
 ORDER BY due ASC;

GRANT SELECT ON vehicles, v_vehicle_alerts TO homeai_readonly;
GRANT SELECT ON vehicles, v_vehicle_alerts TO homeai_pipeline;
GRANT SELECT ON vehicles, v_vehicle_alerts TO metabase_app;

COMMIT;
