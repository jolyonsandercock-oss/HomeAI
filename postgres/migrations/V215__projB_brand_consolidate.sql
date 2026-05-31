-- V215__projB_brand_consolidate.sql — collapse generic-bucket lines onto brand
-- canonicals via a curated keyword table (extensible: add a row to fix more brands).
CREATE TABLE IF NOT EXISTS product_brand_keyword (
  keyword text PRIMARY KEY, family text NOT NULL, canonical_name text NOT NULL
);
INSERT INTO product_brand_keyword (keyword, family, canonical_name) VALUES
  ('guinness','beer','Guinness'), ('corona','beer','Corona'), ('heineken','beer','Heineken'),
  ('peroni','beer','Peroni'), ('san miguel','beer','San Miguel'), ('kingfisher','beer','Kingfisher'),
  ('castle gold','beer','Castle Gold'), ('madri','beer','Madri'), ('cruzcampo','beer','Cruzcampo'),
  ('coca-cola','soft_drink','Coca-Cola'), ('coca cola','soft_drink','Coca-Cola'), ('coke','soft_drink','Coca-Cola'),
  ('pepsi','soft_drink','Pepsi'), ('red bull','soft_drink','Red Bull'),
  ('j20','soft_drink','J2O'), ('j2o','soft_drink','J2O'), ('britvic','soft_drink','Britvic'),
  ('fruit shoot','soft_drink','Fruit Shoots')
ON CONFLICT (keyword) DO NOTHING;

CREATE OR REPLACE FUNCTION home_ai.consolidate_brands() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, home_ai AS $$
DECLARE r record; cid bigint; total integer := 0; n integer;
BEGIN
  FOR r IN SELECT * FROM product_brand_keyword LOOP
    SELECT id INTO cid FROM product_canonical WHERE lower(name) = lower(r.canonical_name) LIMIT 1;
    IF cid IS NULL THEN
      INSERT INTO product_canonical (family, name, realm) VALUES (r.family, r.canonical_name, 'shared') RETURNING id INTO cid;
    END IF;
    UPDATE purchase_lines SET product_canonical_id = cid
      WHERE description ILIKE '%'||r.keyword||'%' AND product_canonical_id IS DISTINCT FROM cid;
    GET DIAGNOSTICS n = ROW_COUNT; total := total + n;
  END LOOP;
  RETURN total;
END $$;
GRANT EXECUTE ON FUNCTION home_ai.consolidate_brands() TO homeai_readonly;
