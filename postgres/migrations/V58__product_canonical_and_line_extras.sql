-- ============================================================
-- U49 — Product canonical schema + line-item extras
-- ============================================================
-- Track 1 of U49. Lets us aggregate "all milk purchases across vendors"
-- via product_canonical + product_aliases mapping.
-- ============================================================

CREATE TABLE IF NOT EXISTS product_canonical (
  id                BIGSERIAL PRIMARY KEY,
  family            TEXT NOT NULL,
  name              TEXT NOT NULL,
  default_unit      TEXT,
  default_size      NUMERIC(10,3),
  default_size_unit TEXT,
  notes             TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (family, name)
);

CREATE INDEX IF NOT EXISTS idx_pc_family ON product_canonical(family);

GRANT SELECT, INSERT, UPDATE ON product_canonical TO homeai_pipeline;
GRANT SELECT ON product_canonical TO homeai_readonly, metabase_app;
GRANT USAGE, SELECT ON SEQUENCE product_canonical_id_seq TO homeai_pipeline;

CREATE TABLE IF NOT EXISTS product_aliases (
  id           BIGSERIAL PRIMARY KEY,
  canonical_id BIGINT REFERENCES product_canonical(id) ON DELETE CASCADE,
  raw_text     TEXT NOT NULL,
  vendor_name  TEXT,
  confidence   NUMERIC(3,2),
  confirmed_by TEXT NOT NULL DEFAULT 'ai'
                  CHECK (confirmed_by IN ('ai','jo','rule')),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (raw_text, vendor_name)
);

CREATE INDEX IF NOT EXISTS idx_pa_canonical ON product_aliases(canonical_id);
CREATE INDEX IF NOT EXISTS idx_pa_raw ON product_aliases USING gin (raw_text gin_trgm_ops);

GRANT SELECT, INSERT, UPDATE ON product_aliases TO homeai_pipeline;
GRANT SELECT ON product_aliases TO homeai_readonly, metabase_app;
GRANT USAGE, SELECT ON SEQUENCE product_aliases_id_seq TO homeai_pipeline;

-- Extend vendor_invoice_lines with canonical + extraction provenance
ALTER TABLE vendor_invoice_lines
  ADD COLUMN IF NOT EXISTS unit                  TEXT,
  ADD COLUMN IF NOT EXISTS canonical_id          BIGINT REFERENCES product_canonical(id),
  ADD COLUMN IF NOT EXISTS qty_canonical         NUMERIC(12,3),
  ADD COLUMN IF NOT EXISTS unit_canonical        TEXT,
  ADD COLUMN IF NOT EXISTS extracted_by          TEXT,
  ADD COLUMN IF NOT EXISTS extraction_confidence NUMERIC(3,2),
  ADD COLUMN IF NOT EXISTS suggested_family      TEXT;

CREATE INDEX IF NOT EXISTS idx_vil_canonical ON vendor_invoice_lines(canonical_id);
CREATE INDEX IF NOT EXISTS idx_vil_description ON vendor_invoice_lines USING gin (description gin_trgm_ops);

-- Seed common product families with placeholder canonicals.
-- Aliases attach to these over time as Haiku categorises each line.
INSERT INTO product_canonical (family, name, default_unit) VALUES
  ('milk',       'Whole milk',          'L'),
  ('milk',       'Semi-skimmed milk',   'L'),
  ('milk',       'Skimmed milk',        'L'),
  ('milk',       'Oat milk',            'L'),
  ('milk',       'Almond milk',         'L'),
  ('wine',       'Red wine',            'bottle'),
  ('wine',       'White wine',          'bottle'),
  ('wine',       'Rosé wine',           'bottle'),
  ('wine',       'Sparkling wine',      'bottle'),
  ('beer',       'Lager (keg)',         'L'),
  ('beer',       'Bitter/Ale (keg)',    'L'),
  ('beer',       'Cider (keg)',         'L'),
  ('beer',       'Lager (bottle)',      'bottle'),
  ('beer',       'Bitter/Ale (bottle)', 'bottle'),
  ('beer',       'Cider (bottle)',      'bottle'),
  ('spirits',    'Vodka',               'L'),
  ('spirits',    'Gin',                 'L'),
  ('spirits',    'Whisky',              'L'),
  ('spirits',    'Rum',                 'L'),
  ('spirits',    'Brandy/Cognac',       'L'),
  ('spirits',    'Liqueur',             'L'),
  ('soft_drink', 'Cola',                'L'),
  ('soft_drink', 'Lemonade',            'L'),
  ('soft_drink', 'Tonic water',         'L'),
  ('soft_drink', 'Juice',               'L'),
  ('coffee',     'Coffee beans',        'kg'),
  ('coffee',     'Ground coffee',       'kg'),
  ('tea',        'Tea',                 'kg'),
  ('meat',       'Beef',                'kg'),
  ('meat',       'Pork',                'kg'),
  ('meat',       'Lamb',                'kg'),
  ('meat',       'Chicken',             'kg'),
  ('meat',       'Bacon',               'kg'),
  ('meat',       'Sausage',             'kg'),
  ('fish',       'White fish',          'kg'),
  ('fish',       'Salmon',              'kg'),
  ('fish',       'Scampi/Prawns',       'kg'),
  ('fish',       'Shellfish',           'kg'),
  ('cheese',     'Cheddar',             'kg'),
  ('cheese',     'Soft cheese',         'kg'),
  ('cheese',     'Blue cheese',         'kg'),
  ('dairy_other','Butter',              'kg'),
  ('dairy_other','Cream',               'L'),
  ('dairy_other','Yoghurt',             'kg'),
  ('dairy_other','Eggs',                'each'),
  ('veg',        'Fresh vegetables',    'kg'),
  ('veg',        'Frozen vegetables',   'kg'),
  ('veg',        'Salad/herbs',         'kg'),
  ('fruit',      'Fresh fruit',         'kg'),
  ('bakery',     'Bread/rolls',         'each'),
  ('bakery',     'Pastry',              'each'),
  ('bakery',     'Cake',                'each'),
  ('condiment',  'Sauces/condiments',   'L'),
  ('condiment',  'Oil',                 'L'),
  ('condiment',  'Vinegar',             'L'),
  ('condiment',  'Salt/spices',         'kg'),
  ('packaging',  'Packaging — paper',   'each'),
  ('packaging',  'Packaging — plastic', 'each'),
  ('packaging',  'Cleaning supplies',   'L'),
  ('utility',    'Electricity',         'kWh'),
  ('utility',    'Gas',                 'kWh'),
  ('utility',    'Water',               'm3'),
  ('software',   'Software subscription','each'),
  ('service',    'Professional service','each'),
  ('service',    'Repairs/maintenance', 'each'),
  ('service',    'Marketing',           'each'),
  ('service',    'Delivery/freight',    'each'),
  ('sundry',     'Other',               'each')
ON CONFLICT (family, name) DO NOTHING;

-- Query helpers
CREATE OR REPLACE VIEW v_product_purchases AS
SELECT
  pc.family,
  pc.name AS canonical_name,
  pc.default_unit,
  vil.line_no,
  vil.description AS raw_description,
  vil.qty,
  vil.unit,
  vil.unit_price,
  vil.line_net,
  vil.line_gross,
  vil.qty_canonical,
  vil.extraction_confidence,
  vii.id   AS invoice_id,
  vii.vendor_name,
  vii.account,
  vii.site,
  COALESCE(vii.delivery_date, vii.invoice_date, vii.received_at::date) AS purchase_date,
  vii.received_at
FROM vendor_invoice_lines vil
LEFT JOIN product_canonical pc ON pc.id = vil.canonical_id
JOIN vendor_invoice_inbox vii  ON vii.id = vil.invoice_id
WHERE vii.is_statement = false
  AND vii.status NOT IN ('duplicate','ignored');

GRANT SELECT ON v_product_purchases
  TO homeai_pipeline, homeai_readonly, metabase_app;

COMMENT ON VIEW v_product_purchases IS
  'U49 — every purchased line item joined to its canonical product family. Drives the /products query UI.';
