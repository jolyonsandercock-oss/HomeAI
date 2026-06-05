-- V229 — U242 T2 P2: counterparty dossiers (distilled, LLM summary + DB financials).
BEGIN;

-- Shared vendor-name cleaner (same expression P1 inlined for linking; financials
-- must use it too so they match counterparties.linked_vendor).
CREATE OR REPLACE FUNCTION home_ai.clean_vendor_name(v text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT btrim(regexp_replace(COALESCE(v,''), '\s*<[^>]*>', '', 'g'), ' "''');
$fn$;

CREATE TABLE IF NOT EXISTS counterparty_dossier (
  id                bigserial PRIMARY KEY,
  counterparty_id   bigint NOT NULL UNIQUE REFERENCES counterparties(id) ON DELETE CASCADE,
  summary           text,
  key_facts         jsonb NOT NULL DEFAULT '[]'::jsonb,
  financials        jsonb NOT NULL DEFAULT '{}'::jsonb,
  open_threads      jsonb NOT NULL DEFAULT '[]'::jsonb,
  people            jsonb NOT NULL DEFAULT '[]'::jsonb,
  citations         bigint[] NOT NULL DEFAULT '{}',
  model             text,
  realms            text[] NOT NULL DEFAULT '{}',
  distilled_through timestamptz,
  generated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS counterparty_dossier_cp ON counterparty_dossier (counterparty_id);

-- RLS mirrors counterparties (array-overlap realm narrow).
ALTER TABLE counterparty_dossier ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS base_access ON counterparty_dossier;
CREATE POLICY base_access ON counterparty_dossier FOR SELECT USING (true);
DROP POLICY IF EXISTS realm_isolation ON counterparty_dossier;
CREATE POLICY realm_isolation ON counterparty_dossier AS RESTRICTIVE USING (
  CASE
    WHEN current_setting('app.current_realm', true) = 'owner'    THEN true
    WHEN current_setting('app.current_realm', true) = 'work'     THEN realms && ARRAY['work','shared']
    WHEN current_setting('app.current_realm', true) = 'personal' THEN realms && ARRAY['personal','shared']
    WHEN current_setting('app.current_realm', true) IS NULL
      OR current_setting('app.current_realm', true) = ''         THEN true
    ELSE false
  END);
GRANT SELECT ON counterparty_dossier TO homeai_readonly;

-- DB-derived financials for a counterparty, matched via the cleaned vendor name.
-- DISTINCT invoice ids so multi-line invoices don't inflate n_invoices; gross sum
-- over lines. Returns {} when the counterparty has no vendor link.
CREATE OR REPLACE FUNCTION home_ai.counterparty_financials(cp_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
  SELECT COALESCE(
    (SELECT jsonb_build_object(
        'total_invoiced', COALESCE(sum(vil.line_gross), 0),
        'n_invoices',     count(DISTINCT vii.id),
        'last_invoice_date', max(vii.invoice_date),
        'currency', 'GBP')
       FROM counterparties c
       JOIN vendor_invoice_inbox vii
         ON home_ai.clean_vendor_name(vii.vendor_name) = c.linked_vendor
       JOIN vendor_invoice_lines vil ON vil.invoice_id = vii.id
      WHERE c.id = cp_id AND c.linked_vendor IS NOT NULL),
    '{}'::jsonb);
$fn$;

COMMIT;
