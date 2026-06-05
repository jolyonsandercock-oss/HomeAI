-- V228 — U242 T2: counterparty registry (deterministic, no LLM).
-- org = email domain, person = address. Built by home_ai.build_counterparty_registry().
BEGIN;

CREATE TABLE IF NOT EXISTS counterparties (
  id                bigserial PRIMARY KEY,
  kind              text NOT NULL CHECK (kind IN ('org','person')),
  display_name      text NOT NULL,
  domain            text,
  primary_email     text,
  addresses         text[] NOT NULL DEFAULT '{}',
  parent_org_id     bigint REFERENCES counterparties(id) ON DELETE SET NULL,
  realms            text[] NOT NULL DEFAULT '{}',
  is_automated      boolean NOT NULL DEFAULT false,
  email_count       integer NOT NULL DEFAULT 0,
  first_seen        timestamptz,
  last_seen         timestamptz,
  linked_vendor     text,
  linked_confidence real,
  signal_score      real NOT NULL DEFAULT 0,
  on_watchlist      boolean NOT NULL DEFAULT false,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- Identity keys: an org is unique by domain, a person by primary_email.
CREATE UNIQUE INDEX IF NOT EXISTS counterparties_org_key
  ON counterparties (domain) WHERE kind = 'org';
CREATE UNIQUE INDEX IF NOT EXISTS counterparties_person_key
  ON counterparties (primary_email) WHERE kind = 'person';
CREATE INDEX IF NOT EXISTS counterparties_signal ON counterparties (signal_score DESC);
CREATE INDEX IF NOT EXISTS counterparties_realms ON counterparties USING gin (realms);

-- RLS: mirror V227 search_vectors — open base SELECT + restrictive realm narrow.
-- realms is an array here, so use overlap (&&) instead of equality.
ALTER TABLE counterparties ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS base_access ON counterparties;
CREATE POLICY base_access ON counterparties FOR SELECT USING (true);

DROP POLICY IF EXISTS realm_isolation ON counterparties;
CREATE POLICY realm_isolation ON counterparties AS RESTRICTIVE USING (
  CASE
    WHEN current_setting('app.current_realm', true) = 'owner'    THEN true
    WHEN current_setting('app.current_realm', true) = 'work'     THEN realms && ARRAY['work','shared']
    WHEN current_setting('app.current_realm', true) = 'personal' THEN realms && ARRAY['personal','shared']
    WHEN current_setting('app.current_realm', true) IS NULL
      OR current_setting('app.current_realm', true) = ''         THEN true
    ELSE false
  END);
GRANT SELECT ON counterparties TO homeai_readonly;

-- Idempotent registry builder. Re-runnable; upserts orgs then people.
-- Own/internal domains to exclude live in the EXCLUDED_DOMAINS array.
CREATE OR REPLACE FUNCTION home_ai.build_counterparty_registry()
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  excluded_domains text[] := ARRAY['malthousetintagel.com'];
BEGIN
  -- 1. Orgs (one row per sender domain).
  INSERT INTO counterparties (kind, display_name, domain, addresses, realms,
                              email_count, first_seen, last_seen)
  SELECT 'org',
         COALESCE((array_agg(from_name ORDER BY received_at DESC)
                   FILTER (WHERE COALESCE(from_name,'') <> ''))[1], domain),
         domain,
         array_agg(DISTINCT addr),
         COALESCE(array_agg(DISTINCT realm) FILTER (WHERE realm IS NOT NULL), '{}'),
         count(*), min(received_at), max(received_at)
  FROM (
    SELECT lower(split_part(from_address,'@',2)) AS domain,
           lower(from_address)                   AS addr,
           from_name, realm, received_at
    FROM emails
    WHERE from_address LIKE '%@%'
      AND split_part(from_address,'@',2) <> ''
      AND lower(split_part(from_address,'@',2)) <> ALL (excluded_domains)
  ) s
  GROUP BY domain
  ON CONFLICT (domain) WHERE kind='org' DO UPDATE SET
    addresses    = EXCLUDED.addresses,
    realms       = EXCLUDED.realms,
    email_count  = EXCLUDED.email_count,
    first_seen   = EXCLUDED.first_seen,
    last_seen    = EXCLUDED.last_seen,
    display_name = EXCLUDED.display_name,
    updated_at   = now();

  -- 2. People (one row per sender address), linked to their domain's org.
  INSERT INTO counterparties (kind, display_name, domain, primary_email, addresses,
                              parent_org_id, realms, email_count, first_seen, last_seen)
  SELECT 'person',
         COALESCE(p.name, p.addr), p.domain, p.addr, ARRAY[p.addr],
         o.id, p.realms, p.n, p.fs, p.ls
  FROM (
    SELECT lower(from_address) AS addr,
           lower(split_part(from_address,'@',2)) AS domain,
           (array_agg(from_name ORDER BY received_at DESC)
            FILTER (WHERE COALESCE(from_name,'') <> ''))[1] AS name,
           COALESCE(array_agg(DISTINCT realm) FILTER (WHERE realm IS NOT NULL), '{}') AS realms,
           count(*) AS n, min(received_at) AS fs, max(received_at) AS ls
    FROM emails
    WHERE from_address LIKE '%@%'
      AND split_part(from_address,'@',2) <> ''
      AND lower(split_part(from_address,'@',2)) <> ALL (excluded_domains)
    GROUP BY addr, domain
  ) p
  LEFT JOIN counterparties o ON o.kind='org' AND o.domain = p.domain
  ON CONFLICT (primary_email) WHERE kind='person' DO UPDATE SET
    parent_org_id = EXCLUDED.parent_org_id,
    realms        = EXCLUDED.realms,
    email_count   = EXCLUDED.email_count,
    first_seen    = EXCLUDED.first_seen,
    last_seen     = EXCLUDED.last_seen,
    display_name  = EXCLUDED.display_name,
    updated_at    = now();

  -- 3. Flag automated senders (heuristic; flagged, never deleted).
  UPDATE counterparties c SET is_automated = true, updated_at = now()
  WHERE NOT c.is_automated AND (
        -- noisy local-parts
        split_part(COALESCE(c.primary_email, ''), '@', 1) ~*
          '^(no-?reply|do-?not-?reply|notifications?|mailer|bounce|updates?|news|newsletter|marketing|alerts?|postmaster|mailer-daemon)$'
        -- single-address org pumping volume
     OR (c.kind='org' AND array_length(c.addresses,1) = 1 AND c.email_count > 50)
        -- known bulk ESP domains
     OR c.domain = ANY (ARRAY['sendgrid.net','mailchimp.com','mailgun.org','sparkpostmail.com',
                              'amazonses.com','sendgrid.com'])
  );

  -- 4. Best-effort fuzzy link orgs -> vendor_invoice_inbox.vendor_name (pg_trgm).
  --    Reviewable, not authoritative: store best match + similarity as confidence.
  WITH vendors AS (
    SELECT DISTINCT vendor_name FROM vendor_invoice_inbox
    WHERE COALESCE(vendor_name,'') <> ''
  ),
  best AS (
    SELECT c.id,
           v.vendor_name,
           similarity(lower(c.display_name), lower(v.vendor_name)) AS sim,
           row_number() OVER (PARTITION BY c.id
             ORDER BY similarity(lower(c.display_name), lower(v.vendor_name)) DESC) AS rn
    FROM counterparties c
    CROSS JOIN vendors v
    WHERE c.kind='org'
      AND similarity(lower(c.display_name), lower(v.vendor_name)) >= 0.35
  )
  UPDATE counterparties c
     SET linked_vendor = b.vendor_name,
         linked_confidence = b.sim,
         updated_at = now()
  FROM best b
  WHERE b.rn = 1 AND b.id = c.id;
END;
$fn$;

COMMIT;
