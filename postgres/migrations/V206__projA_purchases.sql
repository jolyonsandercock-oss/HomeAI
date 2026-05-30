-- V206__projA_purchases.sql
-- Project A (Invoice Intelligence) — canonical capture tables. ADDITIVE / SHADOW:
-- no drops, nothing existing touched. realm-tagged, RLS per the V65/V174 pattern.

CREATE TABLE IF NOT EXISTS purchases (
  id                  bigserial PRIMARY KEY,
  idempotency_key     text UNIQUE NOT NULL,
  source              text NOT NULL,              -- 'email' | 'scan'
  source_ref          text,
  account             text,
  pdf_path            text,
  ocr_text            text,
  vendor_id           bigint,
  vendor_name         text,
  invoice_number      text,
  invoice_date        date,
  due_date            date,
  net_amount          numeric(12,2),
  vat_amount          numeric(12,2),
  gross_amount        numeric(12,2),
  currency            text DEFAULT 'GBP',
  category            text,
  is_invoice          boolean,
  extraction_tier     text,                       -- local|haiku|sonnet|human
  confidence          numeric(4,3),
  gate_passed         boolean DEFAULT false,
  verified            boolean DEFAULT false,
  verified_by         text,
  verified_at         timestamptz,
  entity_id           int,
  realm               text NOT NULL DEFAULT 'work',
  created_at          timestamptz DEFAULT now(),
  updated_at          timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS purchase_lines (
  id                    bigserial PRIMARY KEY,
  purchase_id           bigint NOT NULL REFERENCES purchases(id) ON DELETE CASCADE,
  line_no               int,
  description           text,
  product_canonical_id  bigint,
  quantity              numeric(12,3),
  unit                  text,
  unit_price            numeric(12,4),
  line_net              numeric(12,2),
  vat_rate              numeric(5,2),
  category              text,
  realm                 text NOT NULL DEFAULT 'work'   -- denormalised from parent for clean RLS
);

CREATE TABLE IF NOT EXISTS cogs_category_map (
  purchase_category text PRIMARY KEY,
  sales_department  text,
  is_cogs           boolean DEFAULT true
);

CREATE INDEX IF NOT EXISTS idx_purchases_date    ON purchases(invoice_date);
CREATE INDEX IF NOT EXISTS idx_purchases_realm   ON purchases(realm);
CREATE INDEX IF NOT EXISTS idx_purchases_unverif ON purchases(verified) WHERE verified=false;
CREATE INDEX IF NOT EXISTS idx_plines_purchase   ON purchase_lines(purchase_id);

ALTER TABLE purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_lines ENABLE ROW LEVEL SECURITY;

CREATE POLICY realm_isolation ON purchases
USING (
  CASE
    WHEN current_setting('app.current_realm', true) = 'owner'    THEN TRUE
    WHEN current_setting('app.current_realm', true) = 'work'     THEN (realm = ANY (ARRAY['work','shared']))
    WHEN current_setting('app.current_realm', true) = 'personal' THEN (realm = ANY (ARRAY['family','personal','shared']))
    WHEN current_setting('app.current_realm', true) = 'family'   THEN (realm = ANY (ARRAY['family','personal','shared']))
    WHEN (current_setting('app.current_realm', true) IS NULL
       OR current_setting('app.current_realm', true) = '')       THEN TRUE
    ELSE FALSE
  END
);

CREATE POLICY realm_isolation ON purchase_lines
USING (
  CASE
    WHEN current_setting('app.current_realm', true) = 'owner'    THEN TRUE
    WHEN current_setting('app.current_realm', true) = 'work'     THEN (realm = ANY (ARRAY['work','shared']))
    WHEN current_setting('app.current_realm', true) = 'personal' THEN (realm = ANY (ARRAY['family','personal','shared']))
    WHEN current_setting('app.current_realm', true) = 'family'   THEN (realm = ANY (ARRAY['family','personal','shared']))
    WHEN (current_setting('app.current_realm', true) IS NULL
       OR current_setting('app.current_realm', true) = '')       THEN TRUE
    ELSE FALSE
  END
);

GRANT SELECT ON purchases, purchase_lines, cogs_category_map TO homeai_readonly;
GRANT INSERT, SELECT, UPDATE ON purchases, purchase_lines TO homeai_pipeline;
GRANT USAGE, SELECT ON SEQUENCE purchases_id_seq, purchase_lines_id_seq TO homeai_pipeline;

-- Seed the category → sales-department map (editable).
INSERT INTO cogs_category_map (purchase_category, sales_department, is_cogs) VALUES
  ('food',          'FOOD SALES',    true),
  ('drink_alcohol', 'ALCOHOL SALES', true),
  ('drink_soft',    'HOT DRINKS',    true),
  ('packaging',     NULL,            true),
  ('cleaning',      NULL,            false),
  ('utilities',     NULL,            false),
  ('services',      NULL,            false),
  ('repairs',       NULL,            false),
  ('capex',         NULL,            false),
  ('other',         NULL,            false)
ON CONFLICT (purchase_category) DO NOTHING;
