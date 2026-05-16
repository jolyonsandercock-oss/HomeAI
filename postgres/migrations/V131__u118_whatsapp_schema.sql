-- =============================================================================
-- V131 — U118: WhatsApp message + contact schema
-- =============================================================================
-- Backs the WhatsApp Web bridge for both personal and pub phones.
-- Schema is shared; rows are tagged by `account` (personal | pub).
--
-- Realm rules:
--   personal account → realm='family'
--   pub account      → realm='work'
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

CREATE TABLE IF NOT EXISTS wa_contacts (
  id              BIGSERIAL PRIMARY KEY,
  account         TEXT NOT NULL CHECK (account IN ('personal','pub')),
  phone_e164      TEXT,                          -- +447… canonical when known
  wa_jid          TEXT,                          -- 4477…@s.whatsapp.net or group@g.us
  display_name    TEXT,
  is_group        BOOLEAN NOT NULL DEFAULT false,
  staff_id        BIGINT,                        -- workforce_users.id when matched
  guest_booking_id BIGINT,                       -- accommodation_bookings.id when matched
  first_seen_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_msg_at     TIMESTAMPTZ,
  realm           TEXT NOT NULL,
  UNIQUE (account, wa_jid)
);
CREATE INDEX IF NOT EXISTS idx_wa_contacts_phone ON wa_contacts (phone_e164);
COMMENT ON TABLE wa_contacts IS
'U118 V131. One row per WhatsApp peer per account. staff_id / guest_booking_id
populated once we match the phone number to a known person.';

CREATE TABLE IF NOT EXISTS wa_messages (
  id              BIGSERIAL PRIMARY KEY,
  account         TEXT NOT NULL CHECK (account IN ('personal','pub')),
  wa_msg_id       TEXT,                          -- WhatsApp's own message id when scrapable
  thread_jid      TEXT NOT NULL,                 -- 4477…@s.whatsapp.net or group@g.us
  contact_id      BIGINT REFERENCES wa_contacts(id) ON DELETE SET NULL,
  direction       TEXT NOT NULL CHECK (direction IN ('inbound','outbound')),
  sender_jid      TEXT,
  body            TEXT,
  body_hash       TEXT,                          -- dedup key (sha256 of body + ts + thread)
  has_media       BOOLEAN NOT NULL DEFAULT false,
  media_kind      TEXT,                          -- image | audio | video | doc
  sent_at         TIMESTAMPTZ NOT NULL,
  ingested_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  raw             JSONB,                         -- full scrape payload for debugging
  realm           TEXT NOT NULL,
  UNIQUE (account, body_hash)
);
CREATE INDEX IF NOT EXISTS idx_wa_messages_thread_sent ON wa_messages (thread_jid, sent_at DESC);
CREATE INDEX IF NOT EXISTS idx_wa_messages_unmatched
  ON wa_messages (account, ingested_at DESC) WHERE contact_id IS NULL;
COMMENT ON TABLE wa_messages IS
'U118 V131. Both inbound and outbound WhatsApp messages. body_hash =
sha256(body || thread_jid || sent_at_second) dedupes the inevitable
re-scrapes when the Playwright loop replays the same thread.';

-- Outbound send queue — bot drafts go here, owner approves via Telegram,
-- worker picks them up and ships. Avoids the "AI auto-sent something embarrassing"
-- failure mode entirely.
CREATE TABLE IF NOT EXISTS wa_outbound_queue (
  id              BIGSERIAL PRIMARY KEY,
  account         TEXT NOT NULL CHECK (account IN ('personal','pub')),
  target_jid      TEXT NOT NULL,
  target_label    TEXT,                          -- "Freja Martyn-Leeds" — for the approval msg
  body            TEXT NOT NULL,
  template_id     BIGINT,                        -- wa_templates.id when produced from template
  drafted_by      TEXT,                          -- which bot/cron/manual
  draft_reason    TEXT,                          -- "checkin reminder" / "cover request"
  status          TEXT NOT NULL DEFAULT 'pending_approval'
                    CHECK (status IN ('pending_approval','approved','sent','failed','cancelled')),
  approval_msg_id TEXT,                          -- Telegram message id where Jo sees draft
  approved_at     TIMESTAMPTZ,
  approved_by     TEXT,
  sent_at         TIMESTAMPTZ,
  sent_msg_id     BIGINT REFERENCES wa_messages(id) ON DELETE SET NULL,
  realm           TEXT NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_wa_outbound_pending
  ON wa_outbound_queue (account, status) WHERE status IN ('pending_approval','approved');
COMMENT ON TABLE wa_outbound_queue IS
'U118 V131. Owner-approval-gated outbound. status flow:
pending_approval → approved (after Jo OK in Telegram) → sent (after worker
ships it) → optional failed. Anything ≥ pending_approval lives in the daily
reality email "Outbound waiting" section.';

CREATE TABLE IF NOT EXISTS wa_templates (
  id              BIGSERIAL PRIMARY KEY,
  slug            TEXT NOT NULL UNIQUE,
  description     TEXT,
  body            TEXT NOT NULL,                 -- Jinja-style {{var}} placeholders
  realm           TEXT NOT NULL DEFAULT 'work',
  approved_at     TIMESTAMPTZ,
  approved_by     TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE wa_templates IS
'U118 V131. Approved message templates the bot may draft. Templates with
approved_at IS NULL cannot be drafted from.';

-- Seed a few templates so U119 has something to draw on
INSERT INTO wa_templates (slug, description, body, realm, approved_at, approved_by)
VALUES
  ('staff.cover_request',
   'Ask staff to cover a shift',
   'Hi {{name}}, could you cover {{shift_date}} {{shift_start}}-{{shift_end}} at the {{site}}? Reply YES/NO. Thanks — Jo',
   'work', now(), 'u118-seed'),
  ('staff.rota_published',
   'Notify staff the new rota is up',
   'Hi {{name}}, this week''s rota is published in Tanda. Reply if any clashes. Thanks — Jo',
   'work', now(), 'u118-seed'),
  ('guest.welcome',
   'Pre-arrival welcome (24h before)',
   'Hi {{guest_name}}, welcome to The Olde Malthouse Inn for tomorrow. Check-in from 3pm. The breakfast email arrives at 5pm — please let us know your choices then. Any questions, reply here. Safe travels — Olde Malthouse',
   'work', now(), 'u118-seed'),
  ('guest.checkout_reminder',
   'Morning of checkout — quick thanks',
   'Hi {{guest_name}}, thanks for staying with us — checkout is by 11am. Hope you had a lovely time. If you have a moment, a review on Google or TripAdvisor genuinely helps us. Safe travels — Olde Malthouse',
   'work', now(), 'u118-seed'),
  ('guest.review_nudge_day2',
   'Day after checkout — review request',
   'Hi {{guest_name}}, hope you got home safely. If you''d enjoyed your stay, a one-minute review here would mean the world: {{review_url}}. Hope to see you again — Olde Malthouse',
   'work', now(), 'u118-seed')
ON CONFLICT (slug) DO NOTHING;

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES
  ('wa_outbound_pending',
   'U118 — WhatsApp outbound awaiting approval',
   'SELECT id, account, target_label, body, draft_reason, created_at FROM wa_outbound_queue WHERE status = ''pending_approval'' ORDER BY created_at',
   'WhatsApp drafts queued for owner approval',
   'u118','owner',1, ARRAY['whatsapp pending','outbound drafts'],
   now(),'u118'),
  ('wa_recent_inbound',
   'U118 — WhatsApp inbound last 24h',
   'SELECT account, thread_jid, sender_jid, body, sent_at FROM wa_messages WHERE direction = ''inbound'' AND sent_at >= NOW() - INTERVAL ''24 hours'' ORDER BY sent_at DESC LIMIT 50',
   'Last 24h of inbound WhatsApp across personal + pub',
   'u118','owner',1, ARRAY['whatsapp inbound','recent whatsapp'],
   now(),'u118')
ON CONFLICT (slug) DO UPDATE SET sql_template=EXCLUDED.sql_template, approved_at=now(), approved_by='u118';

COMMIT;
