-- =============================================================================
-- V125 — U106: breakfast orders + email tokens + daily specials
-- =============================================================================
-- The 5pm guest breakfast email needs:
--   - A signed token in each email's submit URL (so we trust the response
--     comes from the right accommodation_booking)
--   - A table to record one row per guest's choice
--   - A daily-specials log so the 10am chef prompt + reply land somewhere
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- One row per (booking, guest_index) — for a 2-person booking we'll
-- have two rows on submit.
CREATE TABLE IF NOT EXISTS breakfast_orders (
  id                  BIGSERIAL PRIMARY KEY,
  accommodation_booking_id BIGINT NOT NULL REFERENCES accommodation_bookings(id) ON DELETE CASCADE,
  email_token         TEXT NOT NULL,                 -- ties the response back to a sent email
  guest_index         INTEGER NOT NULL DEFAULT 1,    -- 1, 2, 3 for multi-guest bookings
  service_date        DATE NOT NULL,                 -- which morning's breakfast
  service_time        TEXT,                          -- '08:00' '08:30' '09:00'
  hot_drink           TEXT,                          -- 'Tea' | 'Coffee' | 'Other' free text
  dish                TEXT,                          -- selected menu item label
  dish_category       TEXT,                          -- 'continental' | 'light' | 'full'
  allergies           TEXT,
  notes               TEXT,
  submitted_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  submitter_ip        INET,
  realm               TEXT NOT NULL DEFAULT 'work',
  UNIQUE (email_token, guest_index)
);
CREATE INDEX IF NOT EXISTS idx_breakfast_orders_service_date
  ON breakfast_orders (service_date, accommodation_booking_id);

COMMENT ON TABLE breakfast_orders IS
'U106 V125. One row per (booking, guest_index, service_date). Populated
by the public POST /api/breakfast/submit endpoint when a guest clicks
submit on the 5pm email.';

-- Track the email send so reminders/follow-ups don't spam
CREATE TABLE IF NOT EXISTS breakfast_email_sends (
  id                  BIGSERIAL PRIMARY KEY,
  accommodation_booking_id BIGINT NOT NULL REFERENCES accommodation_bookings(id) ON DELETE CASCADE,
  email_token         TEXT NOT NULL UNIQUE,          -- HMAC over (booking_id, service_date)
  service_date        DATE NOT NULL,
  guest_email         TEXT NOT NULL,
  guest_count         INTEGER NOT NULL DEFAULT 1,
  sent_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  gmail_message_id    TEXT,
  responded_at        TIMESTAMPTZ,
  realm               TEXT NOT NULL DEFAULT 'work',
  UNIQUE (accommodation_booking_id, service_date)
);

-- Chef daily specials prompt + reply log
CREATE TABLE IF NOT EXISTS kitchen_daily_specials (
  id                  BIGSERIAL PRIMARY KEY,
  service_date        DATE NOT NULL UNIQUE,
  prompt_sent_at      TIMESTAMPTZ,
  prompt_message_id   TEXT,
  reply_received_at   TIMESTAMPTZ,
  reply_message_id    TEXT,
  specials_text       TEXT,                          -- raw chef-supplied text
  wine_pairings_text  TEXT,
  parsed              JSONB,                         -- Haiku-extracted structured specials
  realm               TEXT NOT NULL DEFAULT 'work'
);

GRANT SELECT ON breakfast_orders, breakfast_email_sends, kitchen_daily_specials TO PUBLIC;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'homeai_pipeline') THEN
    EXECUTE 'GRANT INSERT, UPDATE, SELECT ON breakfast_orders, breakfast_email_sends, kitchen_daily_specials TO homeai_pipeline';
    EXECUTE 'GRANT USAGE, SELECT ON breakfast_orders_id_seq, breakfast_email_sends_id_seq, kitchen_daily_specials_id_seq TO homeai_pipeline';
  END IF;
END$$;

-- View: tomorrow's breakfast roster — surfaces in daily report
DROP VIEW IF EXISTS v_breakfast_tomorrow CASCADE;
CREATE VIEW v_breakfast_tomorrow AS
SELECT
  b.id              AS booking_id,
  b.guest_name,
  b.room,
  o.service_time,
  o.guest_index,
  o.hot_drink,
  o.dish,
  o.allergies,
  o.notes
FROM accommodation_bookings b
LEFT JOIN breakfast_orders o
       ON o.accommodation_booking_id = b.id
      AND o.service_date = CURRENT_DATE + 1
WHERE b.checkin_date <= CURRENT_DATE + 1
  AND b.checkout_date > CURRENT_DATE + 1
  AND b.status IN ('confirmed','deposit_paid','paid','active')
ORDER BY b.room, b.guest_name, o.guest_index;

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES (
  'breakfast_tomorrow',
  'U106 — tomorrow breakfast roster',
  'SELECT * FROM v_breakfast_tomorrow',
  'Guests staying tomorrow + their breakfast choices if submitted',
  'u106','owner',1, ARRAY['breakfast tomorrow','breakfast roster'],
  now(),'u106'
) ON CONFLICT (slug) DO UPDATE SET
  sql_template=EXCLUDED.sql_template, approved_at=now(), approved_by='u106';

COMMIT;
