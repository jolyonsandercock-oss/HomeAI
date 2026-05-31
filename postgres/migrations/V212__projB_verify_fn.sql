-- V212__projB_verify_fn.sql — controlled verify/categorise write for the /invoices
-- exception workflow. SECURITY DEFINER so homeai_readonly is NOT widened (EXECUTE only),
-- preserving the read-only boundary (mirrors home_ai.upsert_vendor_rule).
CREATE OR REPLACE FUNCTION home_ai.verify_purchase(p_id bigint, p_action text, p_category text DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, home_ai AS $$
DECLARE v_vendor text; v_affected int := 0;
BEGIN
  IF p_action = 'confirm' THEN
    UPDATE purchases SET verified=true, verified_by='dashboard', verified_at=now() WHERE id=p_id;
    GET DIAGNOSTICS v_affected = ROW_COUNT;
  ELSIF p_action = 'categorise' THEN
    IF p_category IS NULL OR NOT EXISTS (SELECT 1 FROM cogs_category_map WHERE purchase_category = p_category) THEN
      RAISE EXCEPTION 'invalid category %', p_category;
    END IF;
    SELECT vendor_name INTO v_vendor FROM purchases WHERE id = p_id;
    -- Learning effect: apply to every uncategorised work invoice from the same vendor
    -- (so categorising "Forest Produce" once clears the whole vendor), plus this one.
    UPDATE purchases SET category = p_category, verified = true, verified_by = 'dashboard', verified_at = now()
      WHERE realm = 'work' AND (id = p_id OR (vendor_name = v_vendor AND category IS NULL));
    GET DIAGNOSTICS v_affected = ROW_COUNT;
    UPDATE purchase_lines SET category = p_category
      WHERE category IS NULL
        AND purchase_id IN (SELECT id FROM purchases WHERE realm='work' AND (id = p_id OR vendor_name = v_vendor));
  ELSE
    RAISE EXCEPTION 'unknown action %', p_action;
  END IF;
  RETURN v_affected;
END $$;
GRANT EXECUTE ON FUNCTION home_ai.verify_purchase(bigint, text, text) TO homeai_readonly;
