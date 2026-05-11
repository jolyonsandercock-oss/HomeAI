-- V21: Google Identity Foundation
--
-- Sprint U9. Establishes the multi-account Google identity layer:
--   - Normalises emails.account values that drifted across earlier renames
--     (account1 / personal1 / jolyon.sandercock@gmail.com → jo).
--   - Adds a CHECK constraint to ban future drift.
--   - Seeds static_context with the canonical account list, alias mapping,
--     and email-routing rules so the Gmail Poller and downstream pipelines
--     iterate from a single source of truth.
--   - Adds google_api_calls telemetry table for observability across all
--     Google API hits (Gmail/Calendar/Drive/Sheets/Docs) regardless of
--     which account or pipeline made the call.
--
-- Vault paths (set via start.sh / manual setup, not this migration):
--   secret/google/oauth-client    — OAuth2 client (id + secret)
--   secret/google/jo              — refresh_token for jolyon.sandercock@gmail.com
--   secret/google/pounana         — refresh_token for pounana@gmail.com
--   secret/google/bot             — refresh_token for jolyboxbot@gmail.com
--   secret/google/sa-malthouse    — service account JSON key (DWD)
--
-- Workspace addresses (info@, admin@, kitchen@, cafe@, work@, invoices@,
-- and any future alias on malthousetintagel.com) authenticate via
-- domain-wide delegation through sa-malthouse — NO per-address Vault entry.
--
-- Migration is idempotent — safe to re-run.

\set ON_ERROR_STOP on

BEGIN;
SET LOCAL app.current_entity = 'all';

-- ─── 1. Normalise emails.account drift ──────────────────────────
UPDATE emails
   SET account = 'jo'
 WHERE account IN ('account1', 'personal1', 'jolyon.sandercock@gmail.com');

-- ─── 2. CHECK constraint to ban future drift ───────────────────
-- Allowed values:
--   Consumer + bot accounts (canonical short names): jo, pounana, bot
--   Workspace primary mailboxes: info, admin
--   Workspace aliases (full email — kitchen@, cafe@, work@, invoices@,
--     and anything else added later on malthousetintagel.com)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'emails_account_check') THEN
    ALTER TABLE emails DROP CONSTRAINT emails_account_check;
  END IF;
END $$;

ALTER TABLE emails
  ADD CONSTRAINT emails_account_check
  CHECK (
    account IN ('jo', 'pounana', 'bot', 'info', 'admin')
    OR account ~ '^[a-z][a-z0-9._-]*@malthousetintagel\.com$'
  );

-- ─── 3. static_context.gmail.accounts — canonical account registry ──
-- The Gmail Poller iterates this list each cycle. Pipelines look up
-- per-account auth metadata here.
INSERT INTO static_context (key, value, updated_at)
VALUES (
  'gmail.accounts',
  jsonb_build_array(
    jsonb_build_object(
      'name', 'jo',
      'email', 'jolyon.sandercock@gmail.com',
      'type', 'consumer',
      'auth', 'oauth',
      'vault_path', 'secret/google/jo',
      'active', true,
      'is_bot', false,
      'role', 'primary_personal'
    ),
    jsonb_build_object(
      'name', 'pounana',
      'email', 'pounana@gmail.com',
      'type', 'consumer',
      'auth', 'oauth',
      'vault_path', 'secret/google/pounana',
      'active', true,
      'is_bot', false,
      'role', 'secondary_personal'
    ),
    jsonb_build_object(
      'name', 'bot',
      'email', 'jolyboxbot@gmail.com',
      'type', 'consumer',
      'auth', 'oauth',
      'vault_path', 'secret/google/bot',
      'active', true,
      'is_bot', true,
      'role', 'system_outbound'
    ),
    jsonb_build_object(
      'name', 'admin',
      'email', 'admin@malthousetintagel.com',
      'type', 'workspace',
      'auth', 'service_account',
      'vault_path', 'secret/google/sa-malthouse',
      'sa_subject', 'admin@malthousetintagel.com',
      'active', true,
      'is_bot', false,
      'role', 'pub_admin'
    ),
    jsonb_build_object(
      'name', 'info',
      'email', 'info@malthousetintagel.com',
      'type', 'workspace',
      'auth', 'service_account',
      'vault_path', 'secret/google/sa-malthouse',
      'sa_subject', 'info@malthousetintagel.com',
      'active', true,
      'is_bot', false,
      'role', 'pub_shared'
    )
  )::jsonb,
  NOW()
)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ─── 4. static_context.gmail.aliases — alias → primary mailbox ──────
-- Used for Gmail "sendAs" — when system emails as kitchen@ it actually
-- authenticates as info@ via the service account, then specifies sendAs.
INSERT INTO static_context (key, value, updated_at)
VALUES (
  'gmail.aliases',
  jsonb_build_object(
    'kitchen@malthousetintagel.com',  'info@malthousetintagel.com',
    'cafe@malthousetintagel.com',     'info@malthousetintagel.com',
    'work@malthousetintagel.com',     'admin@malthousetintagel.com',
    'invoices@malthousetintagel.com', 'admin@malthousetintagel.com'
  )::jsonb,
  NOW()
)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ─── 5. static_context.email_routing — sender pattern → typed event ─
-- Used by gmail-ingest-v1 to fork certain classified emails into specific
-- downstream pipeline events (e.g., TouchOffice → P5 EPOS pipeline).
-- Patterns are SQL LIKE-style; matched against from_address (lowercased).
-- Empty initially; populated as senders are confirmed.
INSERT INTO static_context (key, value, updated_at)
VALUES (
  'email_routing',
  jsonb_build_array(
    jsonb_build_object(
      'pattern', '%@touchoffice.%',
      'event_type', 'epos.report.received',
      'pipeline', 'epos-pipeline-v1',
      'note', 'ICRTouch Z-reports — daily takings'
    ),
    jsonb_build_object(
      'pattern', '%@icrtouch.%',
      'event_type', 'epos.report.received',
      'pipeline', 'epos-pipeline-v1',
      'note', 'ICRTouch alternate domain'
    ),
    jsonb_build_object(
      'pattern', '%@caterbook.%',
      'event_type', 'accommodation.received',
      'pipeline', 'caterbook-pipeline-v1',
      'note', 'Caterbook daily occupancy reports'
    )
  )::jsonb,
  NOW()
)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

-- ─── 6. google_api_calls — telemetry across all Google API hits ─────
-- Every Gmail/Calendar/Drive/Sheets/Docs call (whether from poller,
-- pipeline, or one-off probe) writes a row here. Lets us spot quota
-- pressure, slow endpoints, auth failures across the whole identity layer.
CREATE TABLE IF NOT EXISTS google_api_calls (
  id              BIGSERIAL PRIMARY KEY,
  ts              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  account         TEXT NOT NULL,                      -- jo|pounana|bot|info|admin|<alias>@…
  scope           TEXT NOT NULL,                      -- gmail|calendar|drive|sheets|docs
  endpoint        TEXT NOT NULL,                      -- e.g. 'gmail.users.messages.list'
  status          INTEGER,                            -- HTTP status
  duration_ms     INTEGER,
  caller          TEXT,                               -- workflow id or service name
  trace_id        UUID,
  idempotency_key TEXT,
  error_message   TEXT
);

CREATE INDEX IF NOT EXISTS idx_gac_ts        ON google_api_calls (ts DESC);
CREATE INDEX IF NOT EXISTS idx_gac_account   ON google_api_calls (account, ts DESC);
CREATE INDEX IF NOT EXISTS idx_gac_scope     ON google_api_calls (scope, status, ts DESC);

GRANT SELECT, INSERT ON google_api_calls TO homeai_pipeline;
GRANT USAGE ON SEQUENCE google_api_calls_id_seq TO homeai_pipeline;
GRANT SELECT ON google_api_calls TO homeai_readonly;

COMMIT;

-- ─── Verification ──────────────────────────────────────────────
SELECT 'V21 ready' AS check,
       (SELECT COUNT(*) FROM emails)::text || ' emails (account values normalised)' AS detail
UNION ALL
SELECT 'static_context entries',
       string_agg(key, ', ') FROM static_context
       WHERE key IN ('gmail.accounts', 'gmail.aliases', 'email_routing');

SELECT 'distinct emails.account values' AS check,
       string_agg(DISTINCT account, ', ') AS detail
  FROM emails;
