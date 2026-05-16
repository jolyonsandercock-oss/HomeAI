-- =============================================================================
-- V112 — U84: auto-ignore pure-notification senders
-- =============================================================================
-- Problem: vendor_invoice_inbox has 6,905 rows tagged 'shared' (or null).
-- Many aren't invoices at all — they're status notifications from
-- payment processors, accounting tools, delivery trackers. They inflate
-- the "needs classification" count and dilute the cost-centre split.
--
-- Fix: a small, conservative ignore-list table. Domains here mark inbound
-- rows as status='ignored' so they drop out of /work/docs counts and the
-- action queue without us deleting the row (Jo may still want to see them
-- under "All" search).
--
-- IMPORTANT: Xero, QuickBooks, Sidetrade ARE NOT in the ignore list —
-- those forward real supplier invoices and need to stay in the inbox.
-- Only PURE notification senders are listed.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

CREATE TABLE IF NOT EXISTS invoice_noise_senders (
  id              BIGSERIAL PRIMARY KEY,
  vendor_domain   TEXT NOT NULL UNIQUE,
  reason          TEXT NOT NULL,
  active          BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by      TEXT NOT NULL DEFAULT 'system'
);

COMMENT ON TABLE invoice_noise_senders IS
'U84 V112. Sender domains we trust to never carry real invoices —
purely notifications, alerts, status pings. Rows from these domains
get status=ignored on intake. Conservative list — only add when the
domain is 100% notifications.';

INSERT INTO invoice_noise_senders (vendor_domain, reason) VALUES
  ('notifications.app.dext.com', 'Dext processing-state notifications'),
  ('podfather.com',              'Delivery job-completion notifications'),
  ('updates.natwest.com',        'Bank balance/payment notifications'),
  ('google.com',                 'Google Play / Ads notifications'),
  ('googlemail.com',             'Individuals — not vendors'),
  ('gocardless.com',             'GoCardless mandate/payment notifications'),
  ('euronetworldwide.com',       'ATM transaction notifications'),
  ('hotmail.co.uk',              'Individuals — not vendors'),
  ('hotmail.com',                'Individuals — not vendors')
ON CONFLICT (vendor_domain) DO NOTHING;

-- One-shot update: mark currently 'new' or 'needs_review' rows from these
-- senders as 'ignored'. They won't appear in /work/docs counts or actions.
WITH bumped AS (
  UPDATE vendor_invoice_inbox
     SET status = 'ignored'
   WHERE status IN ('new', 'needs_review')
     AND vendor_domain IN (SELECT vendor_domain FROM invoice_noise_senders WHERE active)
   RETURNING id
)
SELECT 'V112 ignored ' || COUNT(*) || ' noise-sender rows' AS result FROM bumped;

COMMIT;
