-- =============================================================================
-- V108 — U84: cache PDF-extracted text on vendor_invoice_inbox
-- =============================================================================
-- Problem we're solving:
--   The V103 body-aware site classifier scans body_text. But body_text is the
--   email body — it doesn't contain MAL125/TOM106 account markers that live
--   inside the attached PDF. So 8,539 rows are still tagged 'shared' even
--   though many of their PDFs clearly contain MAL125 (cafe) or TOM106 (pub).
--
-- Fix:
--   Add pdf_text_extracted column. u61 will populate it going forward; a
--   one-shot backfill script (u84-bulk-reclassify-shared.sh) hits pdfplumber
--   for each existing shared row with a local PDF. The V103 trigger needs no
--   change because resolve_site_from_body() reads body_text; we cascade by
--   appending PDF text into body_text when we have it, or extending the
--   resolver to check both. Doing both for safety.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

ALTER TABLE vendor_invoice_inbox
  ADD COLUMN IF NOT EXISTS pdf_text_extracted     TEXT,
  ADD COLUMN IF NOT EXISTS pdf_text_extracted_at  TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_vii_pdf_text_trgm
  ON vendor_invoice_inbox USING gin (pdf_text_extracted gin_trgm_ops)
  WHERE pdf_text_extracted IS NOT NULL;

-- Extend the body-aware classifier to also peek at pdf_text_extracted.
CREATE OR REPLACE FUNCTION public.resolve_site_from_body(p_body_text text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $function$
DECLARE
  v_lower text;
BEGIN
  IF p_body_text IS NULL OR length(p_body_text) < 4 THEN
    RETURN NULL;
  END IF;
  v_lower := lower(p_body_text);
  IF v_lower LIKE '%mal125%' THEN
    RETURN 'cafe';
  END IF;
  IF v_lower LIKE '%tom106%' THEN
    RETURN 'pub';
  END IF;
  RETURN NULL;
END
$function$;

-- New helper that checks BOTH body_text AND pdf_text_extracted.
CREATE OR REPLACE FUNCTION public.resolve_site_from_body_and_pdf(
  p_body_text text, p_pdf_text text
) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $function$
DECLARE
  v_site text;
BEGIN
  v_site := resolve_site_from_body(p_body_text);
  IF v_site IS NOT NULL THEN
    RETURN v_site;
  END IF;
  RETURN resolve_site_from_body(p_pdf_text);
END
$function$;

-- Update the trigger to use the combined resolver.
CREATE OR REPLACE FUNCTION public.vendor_invoice_site_trigger()
RETURNS trigger
LANGUAGE plpgsql AS $function$
DECLARE
  v_canon TEXT;
  v_body_override TEXT;
BEGIN
  v_canon := vendor_category_canonical(NEW.vendor_category);

  -- 1. Body/PDF-aware override (deterministic — wins when it fires).
  v_body_override := resolve_site_from_body_and_pdf(NEW.body_text, NEW.pdf_text_extracted);
  IF v_body_override IS NOT NULL THEN
    NEW.site := v_body_override;
    RETURN NEW;
  END IF;

  -- 2. Fall through to the existing resolver (subject/vendor/category rules).
  NEW.site := resolve_invoice_site(
    NEW.vendor_domain, NEW.subject, NEW.account,
    NEW.vendor_name,   v_canon);
  RETURN NEW;
END
$function$;

-- Fire the trigger on pdf_text_extracted updates too, so when the bulk
-- backfill populates the column, sites re-classify automatically.
DROP TRIGGER IF EXISTS trg_vii_site ON vendor_invoice_inbox;
CREATE TRIGGER trg_vii_site
BEFORE INSERT OR UPDATE OF account, vendor_name, subject, category_canonical,
                          vendor_domain, body_text, pdf_text_extracted
ON vendor_invoice_inbox
FOR EACH ROW EXECUTE FUNCTION vendor_invoice_site_trigger();

COMMIT;
