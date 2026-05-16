-- =============================================================================
-- V132 — U120: guest contact columns + visitor message log
-- =============================================================================
-- accommodation_bookings is missing guest_phone + guest_email. raw_text
-- usually has them (Caterbook PDFs, direct booking emails). U120 backfills
-- via Haiku.
--
-- guest_msg_log records every visitor WA/email/SMS we've sent per booking
-- so the welcome / checkout / review drafters don't double-send.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

ALTER TABLE accommodation_bookings
  ADD COLUMN IF NOT EXISTS guest_phone     TEXT,
  ADD COLUMN IF NOT EXISTS guest_email     TEXT,
  ADD COLUMN IF NOT EXISTS contact_extracted_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS contact_extract_model TEXT;

CREATE INDEX IF NOT EXISTS idx_ab_guest_phone ON accommodation_bookings (guest_phone);
CREATE INDEX IF NOT EXISTS idx_ab_guest_email ON accommodation_bookings (guest_email);

CREATE TABLE IF NOT EXISTS guest_msg_log (
  id            BIGSERIAL PRIMARY KEY,
  booking_id    BIGINT NOT NULL REFERENCES accommodation_bookings(id) ON DELETE CASCADE,
  template_slug TEXT NOT NULL,                   -- e.g. guest.welcome
  channel       TEXT NOT NULL CHECK (channel IN ('wa','email','sms')),
  target        TEXT NOT NULL,                   -- phone or email used
  outbound_id   BIGINT,                          -- wa_outbound_queue.id when WA
  sent_at       TIMESTAMPTZ,                     -- NULL while pending approval
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  realm         TEXT NOT NULL DEFAULT 'work',
  UNIQUE (booking_id, template_slug)
);
COMMENT ON TABLE guest_msg_log IS
'U120 V132. One row per (booking, template) — UNIQUE constraint prevents
the welcome/checkout/review drafters from creating duplicate sends.';

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES (
  'guest_contact_coverage',
  'U120 — guest contact extraction coverage',
  'SELECT COUNT(*) total, COUNT(guest_phone) with_phone, COUNT(guest_email) with_email, ROUND(100.0 * COUNT(guest_phone) / NULLIF(COUNT(*),0), 1) pct_phone FROM accommodation_bookings WHERE status IN (''confirmed'',''deposit_paid'',''paid'',''active'') AND checkin_date >= CURRENT_DATE - 90',
  'How many bookings in the last 90 days have phone/email captured',
  'u120','owner',1, ARRAY['guest contact coverage','phone email coverage'],
  now(),'u120'
) ON CONFLICT (slug) DO UPDATE SET
  sql_template=EXCLUDED.sql_template, approved_at=now(), approved_by='u120';

COMMIT;
