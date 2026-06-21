-- test_drinks_classify.sql — seeds fixture lines, runs the classify UPDATE, asserts, ROLLBACK.
\set ON_ERROR_STOP on
BEGIN;
SET app.current_entity='all'; SET app.current_realm='owner';

INSERT INTO vendor_invoice_inbox (idempotency_key, source_email_id, account, vendor_domain, subject, received_at, is_statement, status, realm)
VALUES ('drinktest1','dm1','info','staustellbrewery.co.uk','s',now(),false,'new','work')
RETURNING id \gset inv_

INSERT INTO vendor_invoice_lines (invoice_id, line_no, description, line_net, realm) VALUES
  (:inv_id, 1, '50LTR KOREV 4.8%',            342.54, 'work'),
  (:inv_id, 2, 'Campo Viejo Rioja 750ml',      8.99,  'work'),
  (:inv_id, 3, 'Smirnoff Vodka 70cl',         14.50,  'work'),
  (:inv_id, 4, 'Coca-Cola post-mix BIB',      42.00,  'work'),
  (:inv_id, 5, 'Chef''s Kitchen White Wine Vinegar', 2.96, 'work'),
  (:inv_id, 6, 'Hogs Jail Ale Chutney',       10.89,  'work'),
  (:inv_id, 7, 'Semi Skimmed Milk 2L',         1.20,  'work');   -- not a drink → stays NULL

-- the classify UPDATE (identical to the sweep)
UPDATE vendor_invoice_lines l
SET drinks_subcategory = (
  SELECT r.subcategory FROM drinks_category_rules r
  WHERE r.active AND l.description ~* r.pattern
  ORDER BY r.priority ASC, length(r.pattern) DESC LIMIT 1)
WHERE l.invoice_id = :inv_id AND l.drinks_subcategory IS NULL
  AND EXISTS (SELECT 1 FROM drinks_category_rules r WHERE r.active AND l.description ~* r.pattern);

DO $$
DECLARE fid bigint;
BEGIN
  SELECT id INTO fid FROM vendor_invoice_inbox WHERE idempotency_key='drinktest1';
  ASSERT (SELECT drinks_subcategory FROM vendor_invoice_lines WHERE invoice_id=fid AND line_no=1)='beer','KOREV should be beer';
  ASSERT (SELECT drinks_subcategory FROM vendor_invoice_lines WHERE invoice_id=fid AND line_no=2)='wine','Rioja should be wine';
  ASSERT (SELECT drinks_subcategory FROM vendor_invoice_lines WHERE invoice_id=fid AND line_no=3)='spirits','Smirnoff should be spirits';
  ASSERT (SELECT drinks_subcategory FROM vendor_invoice_lines WHERE invoice_id=fid AND line_no=4)='minerals','Coke should be minerals';
  ASSERT (SELECT drinks_subcategory FROM vendor_invoice_lines WHERE invoice_id=fid AND line_no=5)='other','wine vinegar must be other, NOT wine';
  ASSERT (SELECT drinks_subcategory FROM vendor_invoice_lines WHERE invoice_id=fid AND line_no=6)='other','ale chutney must be other, NOT beer';
  ASSERT (SELECT drinks_subcategory FROM vendor_invoice_lines WHERE invoice_id=fid AND line_no=7) IS NULL,'milk is not a drink subcategory → NULL';
END $$;
ROLLBACK;
