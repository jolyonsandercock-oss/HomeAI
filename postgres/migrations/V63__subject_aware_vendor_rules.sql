-- V63: Subject-aware vendor rules
--
-- vendor_category_rules previously matched on domain only. J&R Foodservice
-- (jrf.lls.com) uses two account codes appearing in the subject line:
-- MAL125 → cafe, TOM106 → pub kitchen. Same domain, different sites.
-- We now allow rules to optionally also gate on a subject regex.
--
-- The vendor_invoice_inbox.site trigger gets rewritten to:
--   1. consult vendor_category_rules for the highest-priority rule where
--      (domain_pattern matches AND (subject_pattern IS NULL OR subject_pattern matches))
--      AND site IS NOT NULL — take that rule's site
--   2. fall back to the existing hardcoded LIKE chain
--
-- Existing rows backfilled at end so the J&R Foodservice MAL125 invoices
-- start showing as cafe immediately.

BEGIN;

ALTER TABLE vendor_category_rules
  ADD COLUMN IF NOT EXISTS subject_pattern TEXT;

COMMENT ON COLUMN vendor_category_rules.subject_pattern IS
  'Optional case-insensitive regex against vendor_invoice_inbox.subject. When set, the rule only matches invoices whose subject also matches this pattern. NULL means domain-only match.';

-- The cafe-only rule per Jo''s feedback 2026-05-14: J&R Foodservice MAL125
-- account = cafe. Higher priority than the generic jrf.lls.com Food rule so
-- it wins for MAL125 subjects.
INSERT INTO vendor_category_rules
  (domain_pattern, subject_pattern, category, vendor_display, priority, site, notes)
VALUES
  ('jrf\.lls\.com', 'MAL125', 'Food', 'J&R Foodservice (cafe)', 10, 'cafe',
   'U51 — J&R MAL125 account routes to cafe. TOM106 stays on the generic jrf.lls.com rule (shared).')
ON CONFLICT (domain_pattern, site) DO UPDATE SET
  subject_pattern = EXCLUDED.subject_pattern,
  category        = EXCLUDED.category,
  vendor_display  = EXCLUDED.vendor_display,
  priority        = EXCLUDED.priority,
  notes           = EXCLUDED.notes;

-- ── Helper: pick the best site for an invoice, given (domain, subject) + fallbacks ──
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
  -- 1. Highest-priority data-driven rule that has site set + matches.
  SELECT site INTO v_site
    FROM vendor_category_rules
   WHERE site IS NOT NULL
     AND p_vendor_domain ~* domain_pattern
     AND (subject_pattern IS NULL OR p_subject ~* subject_pattern)
   ORDER BY priority ASC, (subject_pattern IS NOT NULL) DESC
   LIMIT 1;
  IF v_site IS NOT NULL THEN
    RETURN v_site;
  END IF;

  -- 2. Fall back to the existing hardcoded ladder (preserves U47a behaviour).
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

-- ── Rewire the trigger to use the helper ──
CREATE OR REPLACE FUNCTION vendor_invoice_site_trigger() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  NEW.site := resolve_invoice_site(
    NEW.vendor_domain, NEW.subject, NEW.account,
    NEW.vendor_name,   NEW.category_canonical);
  RETURN NEW;
END $$;

-- Expand the trigger's UPDATE-of column list so subject changes re-fire it.
DROP TRIGGER IF EXISTS trg_vii_site ON vendor_invoice_inbox;
CREATE TRIGGER trg_vii_site
BEFORE INSERT OR UPDATE OF account, vendor_name, subject, category_canonical, vendor_domain
ON vendor_invoice_inbox
FOR EACH ROW EXECUTE FUNCTION vendor_invoice_site_trigger();

-- ── Backfill existing rows by replaying the trigger ──
UPDATE vendor_invoice_inbox
   SET site = resolve_invoice_site(vendor_domain, subject, account,
                                    vendor_name, category_canonical);

COMMIT;
