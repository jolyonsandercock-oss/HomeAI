-- =============================================================================
-- V124 — U103+U104+U105 foundation: table reminders + marketing signals
-- =============================================================================
-- Goal: 3-day-ahead reminder to accommodation guests to book a restaurant
-- table. Plus a marketing-signals log so we can measure reminder → reply →
-- booking → arrival conversion.
--
-- DATA GAP DISCOVERED 2026-05-16:
--   - hotel_email source has NO guest email in body (263-char body, no
--     attachment). Affects ~96% of accommodation bookings.
--   - Direct Airbnb source has no email (Airbnb anonymises).
--   - Caterbook_airbnb similarly no email.
--   - Caterbook_ctrip DOES have masked forwarding emails.
--   - Caterbook_agoda partial coverage.
-- Implication: the reminder workflow only reaches a tiny fraction of
-- accommodation guests today. Foundation is built; activation needs Jo's
-- input on contact-channel strategy (manual entry / Caterbook scrape).
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- Optional manual guest contacts (Jo can add emails for VIPs)
CREATE TABLE IF NOT EXISTS guest_contacts (
  id                  BIGSERIAL PRIMARY KEY,
  accommodation_booking_id BIGINT REFERENCES accommodation_bookings(id) ON DELETE SET NULL,
  guest_name          TEXT NOT NULL,
  email               TEXT,
  phone               TEXT,
  source              TEXT NOT NULL DEFAULT 'manual',
  notes               TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by          TEXT NOT NULL DEFAULT 'jo',
  realm               TEXT NOT NULL DEFAULT 'work'
);
CREATE INDEX IF NOT EXISTS idx_guest_contacts_booking
  ON guest_contacts (accommodation_booking_id);
CREATE INDEX IF NOT EXISTS idx_guest_contacts_email
  ON guest_contacts (email) WHERE email IS NOT NULL;

-- Log every reminder send so we never double-email
CREATE TABLE IF NOT EXISTS table_reminder_sends (
  id                  BIGSERIAL PRIMARY KEY,
  accommodation_booking_id BIGINT NOT NULL REFERENCES accommodation_bookings(id) ON DELETE CASCADE,
  guest_name          TEXT NOT NULL,
  guest_email         TEXT NOT NULL,
  sent_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  gmail_message_id    TEXT,          -- the SENT message_id
  reply_received_at   TIMESTAMPTZ,   -- updated by reply harvester
  reply_message_id    TEXT,
  reply_summary       TEXT,          -- Haiku-extracted "date, time, party" or original text
  collins_reservation_id BIGINT REFERENCES restaurant_reservations(id),
  status              TEXT NOT NULL DEFAULT 'sent'
    CHECK (status IN ('sent','replied','confirmed','arrived','no_show','suppressed')),
  realm               TEXT NOT NULL DEFAULT 'work',
  UNIQUE (accommodation_booking_id)
);
CREATE INDEX IF NOT EXISTS idx_trs_sent_at
  ON table_reminder_sends (sent_at DESC);

-- Marketing success database. Wider scope than just table reminders —
-- any outbound marketing touch can log here. Cross-correlates with the
-- accommodation_booking → restaurant_reservation funnel.
CREATE TABLE IF NOT EXISTS marketing_signals (
  id                  BIGSERIAL PRIMARY KEY,
  channel             TEXT NOT NULL,            -- 'table_reminder_email' | 'rebook_nudge' | etc.
  kind                TEXT NOT NULL,            -- 'sent' | 'opened' | 'replied' | 'converted' | 'arrived' | 'no_show'
  signal_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  accommodation_booking_id BIGINT REFERENCES accommodation_bookings(id) ON DELETE SET NULL,
  restaurant_reservation_id BIGINT REFERENCES restaurant_reservations(id) ON DELETE SET NULL,
  guest_email         TEXT,
  detail              JSONB,
  realm               TEXT NOT NULL DEFAULT 'work'
);
CREATE INDEX IF NOT EXISTS idx_ms_channel_kind
  ON marketing_signals (channel, kind, signal_at DESC);

-- View: candidates for the 3-day-ahead reminder
DROP VIEW IF EXISTS v_table_reminder_candidates CASCADE;
CREATE VIEW v_table_reminder_candidates AS
WITH stay AS (
  SELECT b.id              AS booking_id,
         b.guest_name,
         b.source,
         b.source_ref,
         b.checkin_date,
         b.checkout_date,
         -- Coalesce a contact email: prefer manual guest_contacts, else
         -- mined from raw_text, else NULL.
         COALESCE(
           gc.email,
           (regexp_match(b.raw_text, '([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})'))[1]
         ) AS guest_email
    FROM accommodation_bookings b
    LEFT JOIN LATERAL (
      SELECT email FROM guest_contacts gc
       WHERE gc.accommodation_booking_id = b.id
       ORDER BY gc.created_at DESC LIMIT 1
    ) gc ON true
   WHERE b.status IN ('confirmed','deposit_paid','paid','active')
     AND b.checkin_date BETWEEN CURRENT_DATE + 2 AND CURRENT_DATE + 4
),
already_dining AS (
  -- Has the guest ALREADY booked a restaurant table during their stay?
  SELECT DISTINCT s.booking_id
    FROM stay s
    JOIN restaurant_reservations rr
      ON rr.reservation_at::date BETWEEN s.checkin_date AND s.checkout_date
     AND lower(rr.guest_name) = lower(s.guest_name)
),
already_reminded AS (
  SELECT accommodation_booking_id FROM table_reminder_sends
)
SELECT
  s.booking_id, s.guest_name, s.source, s.source_ref,
  s.checkin_date, s.checkout_date, s.guest_email,
  CASE
    WHEN s.guest_email IS NULL                    THEN 'no_email'
    WHEN s.guest_email LIKE '%@guest.ctrip.com'    THEN 'masked_ctrip'
    WHEN s.guest_email LIKE '%@guest.trip.com'     THEN 'masked_trip'
    WHEN s.guest_email LIKE 'noreply%'            THEN 'noreply'
    WHEN s.guest_email LIKE 'no-reply%'           THEN 'noreply'
    WHEN s.guest_email LIKE 'lodgingsupport%'     THEN 'platform_support'
    ELSE                                                'usable'
  END AS email_quality,
  CASE WHEN dn.booking_id IS NOT NULL THEN true ELSE false END AS already_dining,
  CASE WHEN rm.accommodation_booking_id IS NOT NULL THEN true ELSE false END AS already_reminded
FROM stay s
LEFT JOIN already_dining dn ON dn.booking_id = s.booking_id
LEFT JOIN already_reminded rm ON rm.accommodation_booking_id = s.booking_id
ORDER BY s.checkin_date, s.guest_name;

COMMENT ON VIEW v_table_reminder_candidates IS
'U103 V124. Accommodation guests checking in in 2-4 days. email_quality
column tells you whether we can actually reach them. Excludes guests
already dining + already reminded.';

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES (
  'table_reminder_candidates',
  'U103 — table-booking reminder candidates (3 days out)',
  'SELECT * FROM v_table_reminder_candidates',
  'Accommodation guests arriving in 2-4 days. email_quality shows reachable subset.',
  'u103','owner',1, ARRAY['reminder candidates'],
  now(),'u103'
) ON CONFLICT (slug) DO UPDATE SET
  sql_template=EXCLUDED.sql_template, approved_at=now(), approved_by='u103';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'homeai_pipeline') THEN
    EXECUTE 'GRANT INSERT, SELECT, UPDATE ON guest_contacts, table_reminder_sends, marketing_signals TO homeai_pipeline';
    EXECUTE 'GRANT USAGE, SELECT ON guest_contacts_id_seq, table_reminder_sends_id_seq, marketing_signals_id_seq TO homeai_pipeline';
  END IF;
END$$;

COMMIT;
