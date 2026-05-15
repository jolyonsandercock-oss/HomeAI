-- =============================================================================
-- V76 — Product canonical + alias tables for invoice line items
-- =============================================================================
-- vendor_invoice_lines already exists (V41). This sprint populates it (U61 T1)
-- with Haiku-extracted rows and joins them to a canonical product registry so
-- we can answer "how much milk last month" / "what flavours have I bought".
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. product_canonical — one row per distinct purchasable thing.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS product_canonical (
    id                BIGSERIAL PRIMARY KEY,
    family            TEXT NOT NULL,    -- 'milk','wine','beer','spirits','meat',
                                         -- 'fish','veg','dairy','packaging','cleaning',
                                         -- 'fuel','condiments','ice_cream_flavour','service','sundry'
    name              TEXT NOT NULL,    -- 'Whole milk 4L', 'Vanilla ice cream 5L'
    default_unit      TEXT,             -- 'L','kg','bottle','case','each','hour','mile'
    default_size      NUMERIC(12,3),
    default_size_unit TEXT,
    notes             TEXT,
    realm             TEXT NOT NULL DEFAULT 'owner',
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (family, name)
);

ALTER TABLE product_canonical DROP CONSTRAINT IF EXISTS product_canonical_realm_check;
ALTER TABLE product_canonical ADD CONSTRAINT product_canonical_realm_check
    CHECK (realm IN ('owner','work','family','shared'));

-- Family enum is a superset of what's already in the table (the pre-U61
-- seed used singular forms like 'condiment' and split 'dairy_other'/'cheese'
-- separately). We keep those rather than rewrite history, and add the new
-- families U61 needs: ice_cream_flavour, frozen, dry_goods, equipment, fuel,
-- cleaning, bread_bakery, tea_coffee.
ALTER TABLE product_canonical DROP CONSTRAINT IF EXISTS product_canonical_family_check;
ALTER TABLE product_canonical ADD CONSTRAINT product_canonical_family_check
    CHECK (family IN (
      'milk','wine','beer','spirits','soft_drink','tea','coffee','tea_coffee',
      'meat','fish','veg','fruit','dairy_other','cheese','bakery','bread_bakery',
      'packaging','cleaning','fuel','condiment','condiments','dry_goods','frozen',
      'ice_cream_flavour','utility','service','equipment','software','sundry'
    ));

CREATE INDEX IF NOT EXISTS idx_product_canonical_family ON product_canonical (family);
CREATE INDEX IF NOT EXISTS idx_product_canonical_name_trgm
    ON product_canonical USING gin (name gin_trgm_ops);

-- -----------------------------------------------------------------------------
-- 2. product_alias — every vendor-specific description that resolves to one
--    canonical product. The line-item extractor first tries an exact match,
--    then a trigram-similarity fallback against product_canonical.name.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS product_alias (
    id            BIGSERIAL PRIMARY KEY,
    canonical_id  BIGINT NOT NULL REFERENCES product_canonical(id) ON DELETE CASCADE,
    alias         TEXT NOT NULL,
    vendor_domain TEXT,                  -- nullable; vendor-specific alias
    confidence    NUMERIC(4,3) NOT NULL DEFAULT 1.0,
    created_by    TEXT NOT NULL DEFAULT 'system',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (canonical_id, alias, vendor_domain)
);

CREATE INDEX IF NOT EXISTS idx_product_alias_alias_trgm
    ON product_alias USING gin (alias gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_product_alias_canonical ON product_alias (canonical_id);

-- -----------------------------------------------------------------------------
-- 3. Seed: obvious families Jo will want to query immediately.
--    More products will be added as the extractor finds new descriptions and
--    Jo confirms canonical IDs via the /invoices UI (U61 T2).
-- -----------------------------------------------------------------------------

-- The U61 seed adds specific products visible in the bench-off invoices.
-- Existing rows ('Whole milk', 'Lager (keg)', etc.) stay untouched.
INSERT INTO product_canonical (family, name, default_unit, notes)
VALUES
    ('ice_cream_flavour', 'Vanilla',           'L', NULL),
    ('ice_cream_flavour', 'Chocolate',         'L', NULL),
    ('ice_cream_flavour', 'Strawberry',        'L', NULL),
    ('ice_cream_flavour', 'Mint Choc Chip',    'L', NULL),
    ('ice_cream_flavour', 'Salted Caramel',    'L', NULL),
    ('ice_cream_flavour', 'Cookies and Cream', 'L', NULL),
    ('ice_cream_flavour', 'Honeycomb',         'L', NULL),
    ('ice_cream_flavour', 'Rum and Raisin',    'L', NULL),

    ('beer', 'Cornwall''s Pride firkin', 'firkin', NULL),
    ('beer', 'Harbour Special firkin',   'firkin', NULL),
    ('beer', 'Korev 4.8% keg 50L',       'keg',    NULL),
    ('beer', 'Rattler 5.5% keg 50L',     'keg',    NULL),
    ('beer', 'Cruzcampo keg 50L',        'keg',    NULL),

    ('wine', 'Cuvee Prestige Rosé Badet Clement 12% 75cl x6', 'case', NULL),
    ('wine', 'Sauvignon Blanc Gravel & Loam 13% 75cl x6',     'case', NULL),
    ('wine', 'Pinot Grigio Soprano 10.5% 75cl x6',            'case', NULL),

    ('spirits', 'Tarquins Rhubarb & Raspberry Gin 70cl', 'bottle', NULL),

    ('soft_drink', 'Pepsi BIB 7L', 'each', NULL),

    ('service', 'Waste collection — mixed',    'each', 'skip hire mixed waste bin'),
    ('service', 'Waste collection — glass',    'each', NULL),
    ('service', 'Waste collection — cardboard','each', NULL),
    ('service', 'Engineer time (hourly)',      'hour', NULL),
    ('service', 'Travel time (hourly)',        'hour', NULL),
    ('service', 'Mileage',                     'mile', NULL)
ON CONFLICT (family, name) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 4. Helper view: line-items joined to canonical
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_invoice_lines_resolved AS
SELECT
    vil.id                         AS line_id,
    vil.invoice_id,
    vii.invoice_date,
    vii.entity_id,
    vii.realm,
    COALESCE(vii.vendor_name, vii.vendor_domain) AS vendor,
    vii.site,
    vil.line_no,
    vil.description                AS raw_description,
    vil.qty,
    vil.unit,
    vil.unit_price,
    vil.line_net,
    vil.line_vat,
    vil.line_gross,
    vil.canonical_id,
    pc.family                      AS canonical_family,
    pc.name                        AS canonical_name,
    vil.extracted_by,
    vil.extraction_confidence
  FROM vendor_invoice_lines vil
  JOIN vendor_invoice_inbox vii ON vii.id = vil.invoice_id
  LEFT JOIN product_canonical pc ON pc.id = vil.canonical_id;

COMMENT ON VIEW v_invoice_lines_resolved IS
    'Invoice line items joined to product_canonical for "how much X did I buy" queries.';

-- -----------------------------------------------------------------------------
-- 5. Verification
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    seed_count INT;
BEGIN
    SELECT COUNT(*) INTO seed_count FROM product_canonical;
    IF seed_count < 20 THEN
        RAISE EXCEPTION 'V76 verification failed: only % product_canonical rows (expected ≥ 20)', seed_count;
    END IF;
    RAISE NOTICE 'V76 verification PASS: % product_canonical seed rows.', seed_count;
END $$;

COMMIT;
