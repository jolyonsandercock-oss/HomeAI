-- V238 — H3 / review A6: reject a broken slug at write time.
-- home_ai.validate_slug() substitutes :named params with NULL (protecting :: casts)
-- and EXPLAINs the template; a trigger blocks INSERT/UPDATE of an ACTIVE slug whose
-- template fails to plan (the full_name/team/shift_cost class of runtime breakage).
-- Validated against all 209 current active slugs: 0 broken.
-- B4 (idempotency): N/A as specced — invoices key on a source-derived idempotency_key
-- (harvest:account:msgid / bgportal_<sha(vendor|invno)>), not (supplier, inv_no), so a
-- corrected re-import from a different source already gets a distinct key. No change.
-- Reversible: DROP TRIGGER validate_slug_before_write ON query_whitelist;
--             DROP FUNCTION home_ai.trg_validate_slug(); DROP FUNCTION home_ai.validate_slug(text);
BEGIN;

CREATE OR REPLACE FUNCTION home_ai.validate_slug(p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE q text;
BEGIN
  q := replace(p_sql, '::', chr(1));
  q := regexp_replace(q, ':[a-zA-Z_][a-zA-Z0-9_]*', 'NULL', 'g');
  q := replace(q, chr(1), '::');
  EXECUTE 'EXPLAIN ' || q;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END $f$;

CREATE OR REPLACE FUNCTION home_ai.trg_validate_slug() RETURNS trigger
LANGUAGE plpgsql AS $t$
DECLARE e text;
BEGIN
  IF NEW.active THEN
    e := home_ai.validate_slug(NEW.sql_template);
    IF e IS NOT NULL THEN
      RAISE EXCEPTION 'slug "%" sql_template does not plan: %', NEW.slug, e;
    END IF;
  END IF;
  RETURN NEW;
END $t$;

DROP TRIGGER IF EXISTS validate_slug_before_write ON query_whitelist;
CREATE TRIGGER validate_slug_before_write
  BEFORE INSERT OR UPDATE ON query_whitelist
  FOR EACH ROW EXECUTE FUNCTION home_ai.trg_validate_slug();

COMMIT;
