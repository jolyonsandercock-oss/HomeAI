-- ============================================================
-- U41 — Land Registry Price Paid API
-- SPEC §7.6
-- ============================================================
-- Free, no-auth UK Land Registry. Monthly comparable-sales report
-- for the Atlantic Road Estates properties.
--
-- Note: `properties` table already existed with a different schema
-- (address_line1, town, purchase_date, purchase_price, current_value).
-- This migration uses the existing columns rather than fighting it.
-- ============================================================

-- property_market_log — new table, idempotent
CREATE TABLE IF NOT EXISTS property_market_log (
  id           BIGSERIAL PRIMARY KEY,
  property_id  BIGINT NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  snapshot_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  sales        JSONB NOT NULL DEFAULT '[]'::jsonb,
  avg_price    NUMERIC(12,2),
  sample_n     INT NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_pml_property_snapshot
  ON property_market_log (property_id, snapshot_at DESC);

GRANT SELECT, INSERT ON property_market_log TO homeai_pipeline;
GRANT SELECT ON property_market_log TO homeai_readonly;
GRANT SELECT ON property_market_log TO metabase_app;
GRANT USAGE, SELECT ON SEQUENCE property_market_log_id_seq TO homeai_pipeline;

DROP VIEW IF EXISTS v_property_comparable_summary;
CREATE VIEW v_property_comparable_summary AS
SELECT
  p.id              AS property_id,
  p.postcode,
  COALESCE(p.address_line1 || COALESCE(', ' || p.town, ''), '') AS address,
  p.purchase_date,
  p.purchase_price  AS acquisition_price_gbp,
  pml.snapshot_at::date AS market_snapshot_date,
  pml.avg_price,
  pml.sample_n,
  CASE
    WHEN p.purchase_price IS NULL OR p.purchase_price = 0 OR pml.avg_price IS NULL THEN NULL
    ELSE ROUND(100.0 * (pml.avg_price - p.purchase_price) / p.purchase_price, 1)
  END AS pct_change_vs_acquisition
FROM properties p
LEFT JOIN LATERAL (
  SELECT snapshot_at, avg_price, sample_n
    FROM property_market_log
   WHERE property_id = p.id
   ORDER BY snapshot_at DESC LIMIT 1
) pml ON true;

GRANT SELECT ON v_property_comparable_summary TO homeai_pipeline;
GRANT SELECT ON v_property_comparable_summary TO homeai_readonly;
GRANT SELECT ON v_property_comparable_summary TO metabase_app;
