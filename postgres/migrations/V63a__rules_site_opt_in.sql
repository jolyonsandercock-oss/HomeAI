-- V63a: tighten resolve_invoice_site so domain-only rules don't override
-- the hardcoded fallback ladder.
--
-- V63 over-applied: every rule defaulted to site='shared' in V59, so the
-- new helper picked them up first and never reached the wet_purchase/
-- dry_purchase → pub fallback. Net effect: 16 pub rows turned shared.
--
-- Correction: only consult vendor_category_rules when subject_pattern is
-- explicitly set. Domain-only rules go back to being purely category rules
-- with no influence on site. The MAL125 rule keeps working because it has
-- a subject_pattern.

BEGIN;

CREATE OR REPLACE FUNCTION resolve_invoice_site(
  p_vendor_domain  TEXT,
  p_subject        TEXT,
  p_account        TEXT,
  p_vendor_name    TEXT,
  p_category_canon TEXT
) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  v_site TEXT;
BEGIN
  -- 1. Subject-pattern rules only. A rule with no subject_pattern is a
  -- category rule, not a site rule, and must not pre-empt the fallback.
  SELECT site INTO v_site
    FROM vendor_category_rules
   WHERE site IS NOT NULL
     AND subject_pattern IS NOT NULL
     AND p_vendor_domain ~* domain_pattern
     AND p_subject ~* subject_pattern
   ORDER BY priority ASC
   LIMIT 1;
  IF v_site IS NOT NULL THEN
    RETURN v_site;
  END IF;

  -- 2. Hardcoded fallback (unchanged from U47a, plus MAL125-in-subject).
  RETURN CASE
    WHEN LOWER(COALESCE(p_subject,'')) LIKE '%mal125%'     THEN 'cafe'
    WHEN LOWER(COALESCE(p_account,'')) LIKE '%sandwich%'   THEN 'cafe'
    WHEN LOWER(COALESCE(p_account,'')) LIKE '%cafe%'       THEN 'cafe'
    WHEN LOWER(COALESCE(p_vendor_name,'')) LIKE '%cafe%'   THEN 'cafe'
    WHEN LOWER(COALESCE(p_account,'')) LIKE '%malthouse%'  THEN 'pub'
    WHEN LOWER(COALESCE(p_account,'')) LIKE '%pub%'        THEN 'pub'
    WHEN LOWER(COALESCE(p_account,'')) LIKE '%inn%'        THEN 'pub'
    WHEN p_category_canon IN ('wet_purchase','dry_purchase') THEN 'pub'
    WHEN p_category_canon = 'cafe_stock'                     THEN 'cafe'
    ELSE 'shared'
  END;
END $$;

-- Backfill again with the corrected helper
UPDATE vendor_invoice_inbox
   SET site = resolve_invoice_site(vendor_domain, subject, account,
                                    vendor_name, category_canonical);

COMMIT;
