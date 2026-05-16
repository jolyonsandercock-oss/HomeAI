-- =============================================================================
-- V103 — U84: body-aware invoice site classifier + MAL125/TOM106 backfill
-- =============================================================================
-- Bug Jo flagged 2026-05-16:
--   resolve_invoice_site() checks only `subject` for MAL125. But J&R invoice
--   emails have subjects like "J&R Foodservice Credit 313175 Copy" — MAL125
--   appears only inside the body. Result: 19 cafe (MAL125) invoices were
--   classified site='shared'. Same problem for pub-kitchen TOM106 (67 rows).
--
-- Fix:
--   1. Add a body-aware classifier helper that overrides site when the
--      body contains an unambiguous account marker (MAL125 → cafe,
--      TOM106 → pub).
--   2. Run it in a trigger on insert/update of body_text.
--   3. One-shot UPDATE to backfill existing rows.
--
-- Sources of truth (per /home/joly/.claude memory project_dext_no_api +
-- feedback_cafe_vendor_truth): cafe sources only from J&R on account MAL125;
-- TOM106 is the pub kitchen account.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- ── Helper: body-aware site override ───────────────────────────────────────
-- Returns the override site for a given body_text, or NULL if no rule fires.
-- Kept simple: a few unambiguous account-code markers. Add more here as
-- new patterns surface.
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

  -- Cafe: J&R MAL125 account is the cafe's only food supplier.
  IF v_lower LIKE '%mal125%' THEN
    RETURN 'cafe';
  END IF;

  -- Pub kitchen: J&R TOM106 is the pub's account.
  IF v_lower LIKE '%tom106%' THEN
    RETURN 'pub';
  END IF;

  RETURN NULL;
END
$function$;

COMMENT ON FUNCTION public.resolve_site_from_body(text) IS
'U84 V103. Returns site override based on body_text markers: MAL125 → cafe,
TOM106 → pub. NULL if no rule fires.';


-- ── Replace the existing site trigger to consult body_text ─────────────────
-- The old vendor_invoice_site_trigger called resolve_invoice_site() which
-- only checks subject + vendor fields. We now layer a body-aware override
-- on top: if the body says MAL125/TOM106, that wins.
CREATE OR REPLACE FUNCTION public.vendor_invoice_site_trigger()
RETURNS trigger
LANGUAGE plpgsql AS $function$
DECLARE
  v_canon TEXT;
  v_site  TEXT;
  v_body_override TEXT;
BEGIN
  v_canon := vendor_category_canonical(NEW.vendor_category);

  -- 1. Body-aware override (deterministic — wins when it fires).
  v_body_override := resolve_site_from_body(NEW.body_text);
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

-- The trigger declaration already lists `body_text` is NOT in the trigger
-- WHEN list. Drop + recreate so it fires when body_text changes too.
DROP TRIGGER IF EXISTS trg_vii_site ON vendor_invoice_inbox;
CREATE TRIGGER trg_vii_site
BEFORE INSERT OR UPDATE OF account, vendor_name, subject, category_canonical,
                          vendor_domain, body_text
ON vendor_invoice_inbox
FOR EACH ROW EXECUTE FUNCTION vendor_invoice_site_trigger();


-- ── Backfill existing rows ────────────────────────────────────────────────
-- Disable RLS for this UPDATE since we're as 'owner' realm anyway.
-- 19 MAL125 + 67 TOM106 expected (per audit pre-V103).
DO $$
DECLARE
  n_cafe int;
  n_pub  int;
BEGIN
  UPDATE vendor_invoice_inbox
     SET site = 'cafe'
   WHERE body_text ILIKE '%mal125%'
     AND (site IS DISTINCT FROM 'cafe');
  GET DIAGNOSTICS n_cafe = ROW_COUNT;

  UPDATE vendor_invoice_inbox
     SET site = 'pub'
   WHERE body_text ILIKE '%tom106%'
     AND (site IS DISTINCT FROM 'pub');
  GET DIAGNOSTICS n_pub = ROW_COUNT;

  RAISE NOTICE 'V103 backfill: MAL125→cafe = % rows; TOM106→pub = % rows', n_cafe, n_pub;
END $$;

COMMIT;
