-- V251 — P0 (refactor plan 2026-06-09): financial_counterparty identity layer.
-- The canonical attribution key for the anchor-first resolver. Grain = invoice
-- vendor_domain (decision B); Xero (xero_bills) enrichment is deferred to the
-- P1 resolver (no clean name->domain join exists to merge safely at seed time).
-- Email-derived `counterparties` link TO this layer (not the reverse).
-- Additive + reversible. RLS is DEFAULT-DENY (review #6): unset realm => no rows.
BEGIN;

CREATE TABLE IF NOT EXISTS financial_counterparty (
  id                bigserial PRIMARY KEY,
  display_name      text NOT NULL,
  domain            text,                          -- grain B key (invoice suppliers); NULL allowed for future bank payees
  kind              text NOT NULL DEFAULT 'supplier'
                       CHECK (kind IN ('supplier','customer','bank_payee','internal','hmrc','other')),
  xero_contact_name text,                          -- ledger enrichment, populated by the P1 resolver/review
  vat_number        text,
  realms            text[] NOT NULL DEFAULT '{}',
  default_entity_id integer,
  status            text NOT NULL DEFAULT 'active'
                       CHECK (status IN ('active','merged','disabled')),
  merged_into       bigint REFERENCES financial_counterparty(id) ON DELETE SET NULL,
  source_seed       text NOT NULL DEFAULT 'manual'
                       CHECK (source_seed IN ('invoice_domain','xero_bill','vendor_rule','resolver','manual')),
  first_seen        timestamptz,
  last_seen         timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- One active identity per domain (grain B). NULL-domain rows (future bank payees) are unconstrained here.
CREATE UNIQUE INDEX IF NOT EXISTS financial_counterparty_domain_key
  ON financial_counterparty (domain) WHERE domain IS NOT NULL;
CREATE INDEX IF NOT EXISTS financial_counterparty_realms
  ON financial_counterparty USING gin (realms);
CREATE INDEX IF NOT EXISTS financial_counterparty_name_trgm
  ON financial_counterparty USING gin (lower(display_name) gin_trgm_ops);
CREATE INDEX IF NOT EXISTS financial_counterparty_status
  ON financial_counterparty (status);

-- DEFAULT-DENY realm RLS: unset / unknown realm returns NO rows (no permissive-null branch).
ALTER TABLE financial_counterparty ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS realm_isolation ON financial_counterparty;
CREATE POLICY realm_isolation ON financial_counterparty USING (
  CASE current_setting('app.current_realm', true)
    WHEN 'owner'    THEN true
    WHEN 'work'     THEN realms && ARRAY['work','shared']
    WHEN 'personal' THEN realms && ARRAY['personal','shared']
    ELSE false
  END);
GRANT SELECT ON financial_counterparty TO homeai_readonly;
GRANT SELECT, INSERT, UPDATE ON financial_counterparty TO homeai_pipeline;
GRANT USAGE, SELECT ON SEQUENCE financial_counterparty_id_seq TO homeai_pipeline;

-- Link email-derived counterparties TO the financial identity (curated; distinct from the fuzzy linked_vendor).
ALTER TABLE counterparties
  ADD COLUMN IF NOT EXISTS financial_counterparty_id bigint
    REFERENCES financial_counterparty(id) ON DELETE SET NULL;

-- Idempotent seed: one identity per invoice vendor_domain (grain B). Re-runnable
-- in value, not just row count. No fuzzy merging — distinct domains stay distinct.
CREATE OR REPLACE FUNCTION home_ai.seed_financial_counterparty()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  INSERT INTO financial_counterparty
    (display_name, domain, kind, realms, default_entity_id, source_seed, first_seen, last_seen)
  SELECT
    -- best display name: most-recent non-empty cleaned vendor_name, else the domain itself
    COALESCE(
      (array_agg(btrim(regexp_replace(vendor_name, '\s*<[^>]*>', '', 'g'), ' "''')
                 ORDER BY received_at DESC)
       FILTER (WHERE COALESCE(btrim(regexp_replace(vendor_name,'\s*<[^>]*>','','g'),' "'''),'') <> ''))[1],
      vendor_domain),
    vendor_domain,
    'supplier',
    COALESCE(array_agg(DISTINCT realm) FILTER (WHERE realm IS NOT NULL), '{}'),
    mode() WITHIN GROUP (ORDER BY entity_id),
    'invoice_domain',
    min(received_at), max(received_at)
  FROM vendor_invoice_inbox
  WHERE COALESCE(vendor_domain,'') <> ''
  GROUP BY vendor_domain
  ON CONFLICT (domain) WHERE domain IS NOT NULL DO UPDATE SET
    realms            = EXCLUDED.realms,
    default_entity_id = EXCLUDED.default_entity_id,
    last_seen         = EXCLUDED.last_seen,
    display_name      = EXCLUDED.display_name,
    updated_at        = now();
END;
$fn$;

COMMIT;
