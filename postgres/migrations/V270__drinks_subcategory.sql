-- V270: drinks sub-category classifier (beer/wine/spirits/minerals).
-- Deterministic rules layer over vendor_invoice_lines (mirrors vendor_category_rules).
-- Design: docs/superpowers/specs/2026-06-21-drinks-subcategory-classifier-design.md
-- NOTE: patterns use Postgres word-boundary \y (NOT \b, which is backspace in Postgres ARE).

ALTER TABLE vendor_invoice_lines
  ADD COLUMN IF NOT EXISTS drinks_subcategory text
  CHECK (drinks_subcategory IN ('beer','wine','spirits','minerals','other'));

CREATE TABLE IF NOT EXISTS drinks_category_rules (
  id          bigserial PRIMARY KEY,
  pattern     text NOT NULL,
  subcategory text NOT NULL CHECK (subcategory IN ('beer','wine','spirits','minerals','other')),
  priority    integer NOT NULL DEFAULT 100,
  notes       text,
  active      boolean NOT NULL DEFAULT true,
  realm       text NOT NULL DEFAULT 'work' CHECK (realm IN ('owner','work','personal','shared')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (pattern, subcategory)
);

ALTER TABLE drinks_category_rules ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS realm_isolation ON drinks_category_rules;
CREATE POLICY realm_isolation ON drinks_category_rules USING (
  CASE current_setting('app.current_realm', true)
    WHEN 'owner' THEN true
    WHEN 'work' THEN realm = ANY (ARRAY['work','shared'])
    WHEN 'personal' THEN realm = ANY (ARRAY['personal','shared'])
    ELSE (current_setting('app.current_realm', true) IS NULL
          OR current_setting('app.current_realm', true) = '')
  END);
GRANT SELECT ON drinks_category_rules TO homeai_readonly;

INSERT INTO drinks_category_rules (pattern, subcategory, priority, notes) VALUES
  ('vinegar','other',1,'wine/cider vinegar = kitchen'),
  ('cooking wine','other',1,'kitchen'),
  ('ale chutney','other',1,'condiment'),
  ('wine gum','other',1,'sweets'),
  ('beer batter','other',1,'kitchen'),
  ('sorbet','other',1,'dessert'),
  ('gateau','other',1,'dessert'),
  ('mousse','other',1,'dessert'),
  ('trifle','other',1,'dessert'),
  (E'\\ysauce\\y','other',1,'kitchen'),
  ('marinade','other',1,'kitchen'),
  (E'\\ycrisps?\\y','other',1,'snack'),
  ('butternut','other',1,'vegetable'),
  (E'crystal bar|\\yflute\\y|saucer|\\yglass\\y|tumbler|goblet|barware','other',1,'glassware'),
  (E'\\y(30|50) ?ltr?\\y','beer',100,'standard keg size'),
  (E'\\ykeg\\y','beer',100,NULL),
  (E'\\ycask\\y','beer',100,NULL),
  ('lager','beer',100,NULL),
  (E'\\yipa\\y','beer',100,NULL),
  (E'\\ystout\\y','beer',100,NULL),
  (E'\\ycider\\y','beer',100,NULL),
  (E'\\ybitter\\y','beer',100,NULL),
  ('pilsner','beer',100,NULL),
  ('helles','beer',100,NULL),
  ('korev','beer',100,NULL),
  ('tribute','beer',100,NULL),
  ('proper job','beer',100,NULL),
  ('doom','beer',100,NULL),
  ('harbour','beer',100,NULL),
  ('madri','beer',100,NULL),
  ('guinness','beer',100,NULL),
  ('carling','beer',100,NULL),
  ('heineken','beer',100,NULL),
  ('peroni','beer',100,NULL),
  ('cornish orchard','beer',100,NULL),
  (E'\\y\\d+ ?(gal|gallon)\\y','beer',100,'cask'),
  ('rattler|thatcher|aspall','beer',100,'cider brands'),
  (E'\\ycoke\\y|coca.?cola','minerals',100,NULL),
  ('pepsi','minerals',100,NULL),
  ('lemonade','minerals',100,NULL),
  (E'\\ytonic\\y','minerals',100,NULL),
  (E'\\yjuice\\y','minerals',100,NULL),
  ('squash','minerals',100,NULL),
  ('post.?mix','minerals',100,NULL),
  (E'\\ysoda\\y','minerals',100,NULL),
  ('still water|sparkling water|mineral water','minerals',100,NULL),
  (E'\\yj2o\\y','minerals',100,NULL),
  ('fanta|sprite|appletiser|fruit shoot','minerals',100,NULL),
  ('red bull|monster','minerals',100,NULL),
  ('vodka','spirits',100,NULL),
  (E'\\ygin\\y','spirits',100,NULL),
  ('whisky|whiskey','spirits',100,NULL),
  (E'\\yrum\\y','spirits',100,NULL),
  ('brandy','spirits',100,NULL),
  ('tequila','spirits',100,NULL),
  ('liqueur','spirits',100,NULL),
  ('bourbon','spirits',100,NULL),
  ('aperol','spirits',100,NULL),
  ('gordon|smirnoff|bacardi|jameson|jack daniel','spirits',100,'spirit brands'),
  (E'\\ywine\\y','wine',100,NULL),
  (E'\\y(75cl|175ml|187ml|250ml)\\y','wine',100,'wine measures'),
  ('prosecco','wine',100,NULL),
  ('champagne','wine',100,NULL),
  ('merlot','wine',100,NULL),
  ('malbec','wine',100,NULL),
  ('sauvignon','wine',100,NULL),
  ('pinot','wine',100,NULL),
  ('chardonnay','wine',100,NULL),
  ('rioja','wine',100,NULL),
  (E'ros[eé] wine|\\yros[eé]\\y','wine',100,NULL),
  ('hardys','wine',100,NULL),
  ('campo viejo','wine',100,NULL)
ON CONFLICT (pattern, subcategory) DO NOTHING;

CREATE OR REPLACE VIEW v_drinks_spend AS
SELECT date_trunc('month', COALESCE(v.invoice_date, v.received_at::date))::date AS month,
       l.drinks_subcategory,
       round(sum(l.line_net), 2) AS net_spend,
       count(*)                     AS line_items,
       count(DISTINCT l.invoice_id) AS invoices
FROM vendor_invoice_lines l
JOIN vendor_invoice_inbox v ON v.id = l.invoice_id
WHERE l.drinks_subcategory IN ('beer','wine','spirits','minerals')
  AND v.is_statement = false AND v.status NOT IN ('duplicate','ignored')
GROUP BY 1, 2;
