-- V214__projB_vendor_cat_propagate.sql — future-vendor auto-tag. Fills uncategorised
-- work purchases (+ lines) from each vendor's dominant (mostly Jo-verified) category,
-- so categorising a vendor once via the verify queue carries to its future invoices.
-- SECURITY DEFINER (homeai_readonly not widened; EXECUTE only).
CREATE OR REPLACE FUNCTION home_ai.propagate_vendor_categories() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, home_ai AS $$
DECLARE v_n integer;
BEGIN
  WITH ranked AS (
    SELECT vendor_name, category,
           row_number() OVER (PARTITION BY vendor_name
             ORDER BY count(*) FILTER (WHERE verified) DESC, count(*) DESC) AS rn
    FROM purchases
    WHERE realm='work' AND category IS NOT NULL AND vendor_name IS NOT NULL
    GROUP BY vendor_name, category
  ), best AS (SELECT vendor_name, category FROM ranked WHERE rn=1)
  UPDATE purchases p SET category = b.category
  FROM best b
  WHERE p.realm='work' AND p.category IS NULL AND p.vendor_name = b.vendor_name;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE purchase_lines pl SET category = p.category
  FROM purchases p
  WHERE pl.purchase_id = p.id AND pl.category IS NULL AND p.category IS NOT NULL AND p.realm='work';
  RETURN v_n;
END $$;
GRANT EXECUTE ON FUNCTION home_ai.propagate_vendor_categories() TO homeai_readonly;
