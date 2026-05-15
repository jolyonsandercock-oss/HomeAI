-- V63b: trigger reads vendor_category (the source), not the generated
-- category_canonical, because PostgreSQL doesn't populate STORED generated
-- columns in NEW for a BEFORE trigger when the generating column isn't
-- touched in the UPDATE — they come through as NULL. That made every
-- wet_purchase/dry_purchase row fall through to the 'shared' default.
--
-- Resolution: the trigger calls vendor_category_canonical(NEW.vendor_category)
-- directly (the same function the generated column uses) so it always sees
-- a fresh value.

BEGIN;

CREATE OR REPLACE FUNCTION vendor_invoice_site_trigger() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
  v_canon TEXT;
BEGIN
  v_canon := vendor_category_canonical(NEW.vendor_category);
  NEW.site := resolve_invoice_site(
    NEW.vendor_domain, NEW.subject, NEW.account,
    NEW.vendor_name,   v_canon);
  RETURN NEW;
END $$;

-- Backfill again now that the trigger sees real canonical values.
-- Force-fire the trigger via subject=subject (subject is in watch list).
UPDATE vendor_invoice_inbox SET subject = subject;

COMMIT;
