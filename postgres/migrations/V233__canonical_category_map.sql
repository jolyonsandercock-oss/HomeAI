-- V233 — U243 S4: canonical category mapping for invoices.
-- The AI extractor emits dry_purchase/wet_purchase/software/... while the rest of
-- the system uses Food/Beverage/Maintenance/... and ~9,000 invoices have a NULL
-- category_canonical. This maps the extractor vocab to one canonical set (pub
-- trade: wet=drinks, dry=food) — per the operator-confirmed mapping in
-- .claude/overnight-config.json. Read-only: does NOT mutate vendor_invoice_inbox.
BEGIN;

CREATE OR REPLACE FUNCTION home_ai.canonical_category(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE lower(btrim(coalesce(p,'')))
    WHEN 'wet_purchase'        THEN 'Beverage'
    WHEN 'dry_purchase'        THEN 'Food'
    WHEN 'software'            THEN 'Software'
    WHEN 'repairs_maintenance' THEN 'Maintenance'
    WHEN 'utilities'           THEN 'Utilities'
    WHEN 'other'               THEN 'Other'
    WHEN 'income'              THEN NULL   -- income is not a cost category
    ELSE NULL                             -- unknown/unmapped -> surfaced as Uncategorised in the view
  END;
$fn$;
COMMENT ON FUNCTION home_ai.canonical_category(text) IS
  'U243: map extractor category_canonical -> unified business categories (overnight-config.json).';

CREATE OR REPLACE VIEW v_invoice_categorised AS
  SELECT vii.*,
         COALESCE(home_ai.canonical_category(vii.category_canonical), 'Uncategorised') AS category_unified
    FROM vendor_invoice_inbox vii;

COMMIT;
