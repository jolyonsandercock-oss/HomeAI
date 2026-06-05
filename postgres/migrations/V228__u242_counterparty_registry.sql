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

COMMIT;
