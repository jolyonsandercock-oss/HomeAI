-- V291 (2026-07-04) — data-driven invoice-sender routing rules.
-- Replaces the hardcoded denylist in the gmail-ingest classifier (u293) with a
-- table the derivation cron (u294) maintains and the node reads via
-- static_context['invoice.sender_denylist']. Safety model below.

CREATE TABLE IF NOT EXISTS invoice_sender_rules (
  id           bigserial PRIMARY KEY,
  sender       text NOT NULL,                                   -- lowercased email address OR domain
  match_type   text NOT NULL CHECK (match_type IN ('address','domain')),
  action       text NOT NULL CHECK (action IN ('deny','allow','review')),
  -- deny   : classifier downgrades 'invoice' -> 'fyi' for this sender.
  -- allow  : NEVER auto-denied (manual protection escape hatch).
  -- review : flagged candidate (has PDF attachments but 0 captured) — NOT
  --          enforced; a human decides deny/allow. This is the guard that
  --          stops a real supplier with broken capture being silently dropped.
  source       text NOT NULL CHECK (source IN ('auto','manual','seed')),
  reason       text,
  evidence     jsonb,                                            -- {classified, with_attachment, real_captured, window_days}
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (sender, match_type)
);

COMMENT ON TABLE invoice_sender_rules IS
  'Invoice-sender routing rules (V291). Auto-deny = derived by u294 from senders classified invoice >=N with 0 attachments AND 0 captured invoices (body-only notifications, nothing to lose). PDF-bearing-but-uncaptured senders go to action=review, never auto-denied.';

-- Seed the u293 hardcoded denylist as source='seed' so behaviour is preserved
-- the instant the node switches to reading the table.
INSERT INTO invoice_sender_rules (sender, match_type, action, source, reason) VALUES
  ('no-reply@notifications.app.dext.com','address','deny','seed','u293 seed: Dext system notification'),
  ('shipment-tracking@amazon.co.uk','address','deny','seed','u293 seed: Amazon dispatch'),
  ('order-update@amazon.co.uk','address','deny','seed','u293 seed: Amazon order notification'),
  ('auto-confirm@amazon.co.uk','address','deny','seed','u293 seed: Amazon order confirmation'),
  ('payments-update@amazon.co.uk','address','deny','seed','u293 seed: Amazon payment notification'),
  ('no-reply@amazon.co.uk','address','deny','seed','u293 seed: Amazon no-reply'),
  ('return@amazon.co.uk','address','deny','seed','u293 seed: Amazon returns'),
  ('marketplace-messages@amazon.co.uk','address','deny','seed','u293 seed: Amazon marketplace'),
  ('automated@airbnb.com','address','deny','seed','u293 seed: Airbnb automated'),
  ('express@airbnb.com','address','deny','seed','u293 seed: Airbnb express'),
  ('community@airbnb.com','address','deny','seed','u293 seed: Airbnb community'),
  ('accounts@gohenry.com','address','deny','seed','u293 seed: GoHenry notification'),
  ('notifications.app.dext.com','domain','deny','seed','u293 seed: Dext notification domain'),
  ('healthchecks.io','domain','deny','seed','u293 seed: healthchecks monitoring'),
  ('mathacademy.com','domain','deny','seed','u293 seed: MathAcademy notification')
ON CONFLICT (sender, match_type) DO NOTHING;

-- Manual allow escape hatch for owner/internal identities that FORWARD real
-- invoices (never auto-deny even though they are generic mail domains).
INSERT INTO invoice_sender_rules (sender, match_type, action, source, reason) VALUES
  ('jolyon.sandercock@gmail.com','address','allow','manual','owner — forwards real invoices'),
  ('jolyboxbot@gmail.com','address','allow','manual','internal bot — forwards real invoices'),
  ('admin@malthousetintagel.com','address','allow','manual','internal — real invoices'),
  ('info@malthousetintagel.com','address','allow','manual','internal — real invoices')
ON CONFLICT (sender, match_type) DO NOTHING;
