-- =============================================================================
-- V109 — U84 Item 2: vendor_site_rules + classifier extension
-- =============================================================================
-- Purpose: where MAL125/TOM106 markers can't be found in body or PDF text,
-- fall back to a default site by vendor_domain. Only for unambiguous
-- suppliers (a brewery is always pub, a fish supplier is always pub kitchen).
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

CREATE TABLE IF NOT EXISTS vendor_site_rules (
  id              BIGSERIAL PRIMARY KEY,
  vendor_domain   TEXT NOT NULL,
  site            TEXT NOT NULL CHECK (site IN ('pub','cafe','shared')),
  rationale       TEXT,
  priority        INT  NOT NULL DEFAULT 100,
  active          BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by      TEXT NOT NULL DEFAULT 'system',
  UNIQUE (vendor_domain)
);

COMMENT ON TABLE vendor_site_rules IS
'U84 V109. Vendor-default site mapping. Consulted by resolve_invoice_site
AFTER body/PDF MAL125/TOM106 markers (which always win) but BEFORE the
hardcoded fallback in the original resolver. Only seed unambiguous vendors.';

-- Seed unambiguous suppliers. Anything ambiguous (Amazon, Forest Produce
-- if cafe also orders from them, etc.) is left out for now — Jo can add via
-- /api/admin/vendor-rules in a later sprint.
INSERT INTO vendor_site_rules (vendor_domain, site, rationale, priority, created_by) VALUES
  ('staustellbrewery.co.uk',  'pub',  'Brewery — beer wholesale, pub-only', 10, 'u84-init'),
  ('bidfreshfinance.co.uk',   'pub',  'Bidfresh — fish supplier, pub kitchen', 10, 'u84-init'),
  ('cpnitro.com',             'pub',  'CO2 dispense gas — pub cellar only', 10, 'u84-init'),
  ('jrfoodservice.com',       'pub',  'J&R Foodservice (no -lls subdomain) — historically TOM106', 10, 'u84-init'),
  ('forestproduce.com',       'pub',  'Forest Produce — pub kitchen supplier per memory notes', 10, 'u84-init'),
  ('kingfisherbrixham.co.uk', 'pub',  'Kingfisher Brixham — fish, pub kitchen', 10, 'u84-init'),
  ('quatra.com',              'pub',  'Quatra — used cooking oil collection, pub kitchen', 10, 'u84-init')
ON CONFLICT (vendor_domain) DO NOTHING;

-- Extend the resolver chain. New order:
--   1. PDF/body MAL125 → cafe, TOM106 → pub (V108 logic — wins outright)
--   2. vendor_site_rules.site by vendor_domain match (this migration)
--   3. resolve_invoice_site fallback (subject/category/account patterns)
CREATE OR REPLACE FUNCTION public.vendor_invoice_site_trigger()
RETURNS trigger
LANGUAGE plpgsql AS $function$
DECLARE
  v_canon TEXT;
  v_body_override TEXT;
  v_vendor_rule TEXT;
BEGIN
  v_canon := vendor_category_canonical(NEW.vendor_category);

  -- 1. Body/PDF marker wins.
  v_body_override := resolve_site_from_body_and_pdf(NEW.body_text, NEW.pdf_text_extracted);
  IF v_body_override IS NOT NULL THEN
    NEW.site := v_body_override;
    RETURN NEW;
  END IF;

  -- 2. Vendor-default rule.
  SELECT site INTO v_vendor_rule
    FROM vendor_site_rules
   WHERE active = true
     AND lower(NEW.vendor_domain) = lower(vendor_domain)
   ORDER BY priority ASC
   LIMIT 1;
  IF v_vendor_rule IS NOT NULL THEN
    NEW.site := v_vendor_rule;
    RETURN NEW;
  END IF;

  -- 3. Fall through to the existing resolver.
  NEW.site := resolve_invoice_site(
    NEW.vendor_domain, NEW.subject, NEW.account,
    NEW.vendor_name,   v_canon);
  RETURN NEW;
END
$function$;

-- Backfill: re-fire the trigger on existing rows by touching vendor_domain.
-- Using a noop UPDATE that hits the trigger column list.
UPDATE vendor_invoice_inbox
   SET vendor_domain = vendor_domain
 WHERE (site IS NULL OR site = 'shared')
   AND vendor_domain IN (SELECT vendor_domain FROM vendor_site_rules WHERE active);

COMMIT;
