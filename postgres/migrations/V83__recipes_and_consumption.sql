-- =============================================================================
-- V83 — Recipe model + consumption-vs-purchase view (U66 T3)
-- =============================================================================
-- Maps EPoS PLU sales to ingredient-level consumption, then compares against
-- invoice-line purchases. First-cut framework: ~10 seed recipes covering the
-- highest-volume PLUs. Jo expands coverage iteratively.
--
-- Schema:
--   recipes              one row per menu item (PLU)
--   recipe_components    line items linking recipes → product_canonical
--                        with qty per portion in a base unit
--
-- product_canonical gains base_unit + base_size_in_base so we can compare
-- units consistently — e.g. "Cruzcampo 50L keg" has base_unit='ml',
-- base_size_in_base=50000 so 1 keg purchased = 50,000 ml.
--
-- View v_consumption_vs_purchase rolls both up per (week, canonical, site).
-- =============================================================================

BEGIN;

-- ── product_canonical: add base-unit columns for unit-consistent maths
ALTER TABLE product_canonical
    ADD COLUMN IF NOT EXISTS base_unit TEXT,                  -- 'ml','g','each','litre'
    ADD COLUMN IF NOT EXISTS base_size_in_base NUMERIC(14,4); -- one purchase-unit in base_unit

-- ── recipes
CREATE TABLE IF NOT EXISTS recipes (
    id            BIGSERIAL PRIMARY KEY,
    plu_number    TEXT,                             -- TouchOffice PLU; NULL = combo/non-PLU dish
    name          TEXT NOT NULL,
    menu_section  TEXT,                             -- 'drinks' | 'food' | 'ice_cream' | 'breakfast' | ...
    portion_unit  TEXT NOT NULL DEFAULT 'each',     -- 'pint' | 'scoop' | 'plate' | 'each'
    site          TEXT,                             -- 'pub' | 'cafe' | 'inn' | NULL = any
    notes         TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    realm         TEXT NOT NULL DEFAULT 'work'
                       CHECK (realm IN ('owner','work','family','shared'))
);
CREATE INDEX IF NOT EXISTS idx_recipes_plu ON recipes (plu_number) WHERE plu_number IS NOT NULL;

-- ── recipe_components
CREATE TABLE IF NOT EXISTS recipe_components (
    id                    BIGSERIAL PRIMARY KEY,
    recipe_id             BIGINT NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
    product_canonical_id  BIGINT NOT NULL REFERENCES product_canonical(id),
    quantity_per_portion  NUMERIC(12,4) NOT NULL,   -- in base_unit of product_canonical
    base_unit             TEXT NOT NULL,            -- must match product_canonical.base_unit
    notes                 TEXT,
    realm                 TEXT NOT NULL DEFAULT 'work'
                               CHECK (realm IN ('owner','work','family','shared'))
);
CREATE INDEX IF NOT EXISTS idx_rc_recipe  ON recipe_components (recipe_id);
CREATE INDEX IF NOT EXISTS idx_rc_product ON recipe_components (product_canonical_id);

-- ── product_canonical base-unit seeding for the existing rows
UPDATE product_canonical SET base_unit='ml',  base_size_in_base=50000 WHERE family='beer' AND name ILIKE '%50L%';
UPDATE product_canonical SET base_unit='ml',  base_size_in_base=1000  WHERE family='milk';
UPDATE product_canonical SET base_unit='g',   base_size_in_base=170   WHERE name ILIKE '%170g%';

-- ── Seed a handful of common product_canonical entries we'll need for recipes.
INSERT INTO product_canonical (family, name, default_unit, default_size, default_size_unit, base_unit, base_size_in_base, notes, realm) VALUES
    ('beer',       'Korev keg 50L',          'keg', 50,  'L', 'ml', 50000, 'Korev lager — top-3 pub draught', 'shared'),
    ('beer',       'Rattler keg 50L',        'keg', 50,  'L', 'ml', 50000, 'Rattler cider', 'shared'),
    ('beer',       'Harbour Special Ale keg 22L', 'keg', 22, 'L', 'ml', 22000, '', 'shared'),
    ('beer',       'Cornwalls Pride keg 22L', 'keg', 22, 'L', 'ml', 22000, '', 'shared'),
    ('beer',       'Tintagel Gold Ale keg 22L', 'keg', 22, 'L', 'ml', 22000, '', 'shared'),
    ('frozen',     'Vanilla ice cream tub 5L', 'tub', 5, 'L', 'ml', 5000, 'house-vanilla', 'shared'),
    ('frozen',     'Chocolate ice cream tub 5L','tub', 5, 'L', 'ml', 5000, '', 'shared'),
    ('bakery',     'Waffle cone case 50', 'case', 50, 'each', 'each', 50, '', 'shared'),
    ('fish',       'Cod fillet frozen 5kg case', 'case', 5, 'kg', 'g', 5000, 'fish & chips', 'shared'),
    ('soft_drink', 'Tonic water 200ml bottle', 'each', 200, 'ml', 'ml', 200, '', 'shared'),
    ('fruit',      'Lemon piece',  'each', 1,  'each', 'each', 1, '', 'shared')
ON CONFLICT DO NOTHING;

-- ── Seed recipes — top 10 PLUs by 30d volume
WITH new_recipes AS (
    INSERT INTO recipes (plu_number, name, menu_section, portion_unit, site, notes) VALUES
      ('3',    'Korev pint',                'drinks',    'pint',  'pub',  'PLU 3 — top draught'),
      ('5',    'Rattler pint',              'drinks',    'pint',  'pub',  'PLU 5'),
      ('9',    'Harbour Special Ale pint',  'drinks',    'pint',  'pub',  'PLU 9'),
      ('7',    'Cornwalls Pride pint',      'drinks',    'pint',  'pub',  'PLU 7'),
      ('8',    'Tintagel Gold Ale pint',    'drinks',    'pint',  'pub',  'PLU 8'),
      ('4',    'Cruzcampo pint',            'drinks',    'pint',  'pub',  'PLU 4'),
      ('1110', 'Single scoop ice cream',    'ice_cream', 'scoop', 'cafe', 'PLU 1110 — top cafe seller'),
      ('1111', 'Double scoop ice cream',    'ice_cream', 'scoop', 'cafe', 'PLU 1111'),
      ('1100', 'Single waffle',             'ice_cream', 'each',  'cafe', 'PLU 1100'),
      ('728',  'Fish and Chips',            'food',      'plate', 'pub',  'PLU 728 — pub kitchen')
    RETURNING id, plu_number
)
INSERT INTO recipe_components (recipe_id, product_canonical_id, quantity_per_portion, base_unit, notes)
SELECT r.id, pc.id, qty, pc.base_unit, note
  FROM new_recipes r
  JOIN LATERAL (VALUES
      -- Pints map to specific kegs. 1 UK pint = 568ml.
      ('3',    'Korev keg 50L',                568.0, 'one pint'),
      ('5',    'Rattler keg 50L',              568.0, 'one pint'),
      ('9',    'Harbour Special Ale keg 22L',  568.0, 'one pint'),
      ('7',    'Cornwalls Pride keg 22L',      568.0, 'one pint'),
      ('8',    'Tintagel Gold Ale keg 22L',    568.0, 'one pint'),
      ('4',    'Cruzcampo keg 50L',            568.0, 'one pint'),
      -- Ice cream: 80ml per scoop is industry-standard (~70g).
      ('1110', 'Vanilla ice cream tub 5L',     80.0,  'single scoop'),
      ('1111', 'Vanilla ice cream tub 5L',     160.0, 'double scoop'),
      -- Waffles: 1 waffle cone each
      ('1100', 'Waffle cone case 50',          1.0,   'one waffle'),
      -- Fish & chips
      ('728',  'Cod fillet frozen 5kg case',   180.0, 'one portion (180g)')
  ) AS rc(plu, prod_name, qty, note) ON rc.plu = r.plu_number
  JOIN product_canonical pc ON pc.name = rc.prod_name;

-- ── The view
CREATE OR REPLACE VIEW v_consumption_vs_purchase AS
WITH consumption AS (
    SELECT
        DATE_TRUNC('week', tps.report_date)::date           AS week,
        tps.site                                            AS site,
        rc.product_canonical_id                             AS product_canonical_id,
        rc.base_unit                                        AS base_unit,
        SUM(tps.quantity * rc.quantity_per_portion)::numeric(14,2) AS implied_consumption
      FROM touchoffice_plu_sales tps
      JOIN recipes           r  ON r.plu_number = tps.plu_number
                                AND (r.site IS NULL OR r.site = tps.site)
      JOIN recipe_components rc ON rc.recipe_id = r.id
     WHERE tps.report_date >= CURRENT_DATE - INTERVAL '180 days'
     GROUP BY 1, 2, 3, 4
),
purchase AS (
    SELECT
        DATE_TRUNC('week', COALESCE(vii.invoice_date, vii.received_at::date))::date AS week,
        vil.canonical_id                                    AS product_canonical_id,
        pc.base_unit                                        AS base_unit,
        SUM(COALESCE(vil.qty_canonical, vil.qty, 0) * pc.base_size_in_base)::numeric(14,2) AS purchased
      FROM vendor_invoice_lines vil
      JOIN vendor_invoice_inbox vii ON vii.id = vil.invoice_id
      JOIN product_canonical    pc  ON pc.id  = vil.canonical_id
     WHERE pc.base_unit IS NOT NULL
       AND COALESCE(vii.invoice_date, vii.received_at::date) >= CURRENT_DATE - INTERVAL '180 days'
     GROUP BY 1, 2, 3
),
joined AS (
    SELECT
        COALESCE(c.week, p.week)                            AS week,
        COALESCE(c.product_canonical_id, p.product_canonical_id) AS product_canonical_id,
        c.site                                              AS site,
        COALESCE(c.base_unit, p.base_unit)                  AS base_unit,
        COALESCE(c.implied_consumption, 0)::numeric(14,2)   AS implied_consumption,
        COALESCE(p.purchased,            0)::numeric(14,2)  AS purchased
      FROM consumption c
      FULL OUTER JOIN purchase p
        ON p.week = c.week AND p.product_canonical_id = c.product_canonical_id
)
SELECT j.*,
       pc.family,
       pc.name AS product_name,
       (j.purchased - j.implied_consumption)::numeric(14,2) AS gap,
       CASE
         WHEN j.implied_consumption = 0 THEN NULL
         ELSE ROUND(100.0 * (j.purchased - j.implied_consumption) / j.implied_consumption, 1)
       END AS gap_pct
  FROM joined j
  JOIN product_canonical pc ON pc.id = j.product_canonical_id;

COMMENT ON VIEW v_consumption_vs_purchase IS
    'U66 T3: weekly implied consumption (from PLU sales × recipe) vs invoice '
    'purchases per product_canonical. Negative gap = stock used faster than '
    'bought (waste? incorrect recipe?). Positive gap = over-purchasing or '
    'stocking up. First-cut — coverage limited by recipe seed (~10 PLUs).';

-- ── Verification
DO $$
DECLARE n_recipes INT; n_components INT;
BEGIN
    SELECT COUNT(*) INTO n_recipes FROM recipes;
    SELECT COUNT(*) INTO n_components FROM recipe_components;
    IF n_recipes < 5 OR n_components < 5 THEN
        RAISE EXCEPTION 'V83 verification failed: recipes=% components=%', n_recipes, n_components;
    END IF;
    RAISE NOTICE 'V83 PASS: % recipes / % components seeded.', n_recipes, n_components;
END $$;

COMMIT;
