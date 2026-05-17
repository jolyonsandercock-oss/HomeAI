-- =============================================================================
-- V136 — U124-B: guest CRM (contacts + LTV + repeat-guest detection)
-- =============================================================================
-- accommodation_bookings is keyed by booking, not by person. Aggregating to
-- a guest_contacts table gives us LTV, visit count, last-stay date, and a
-- foundation for repeat-guest welcome-back automation.
--
-- Key: canonical_name first. Phone + email are sparse (extraction in U120
-- only just started) so we use canonical as primary identity.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- Drop any pre-existing stub (empty placeholder schema from a prior sprint)
DROP TABLE IF EXISTS guest_contacts CASCADE;

CREATE TABLE guest_contacts (
  id                BIGSERIAL PRIMARY KEY,
  canonical_name    TEXT NOT NULL,                        -- public.canonical_name(display_name)
  display_name      TEXT NOT NULL,                        -- preferred form (first booking spelling)
  phone_e164        TEXT,
  email             TEXT,
  first_seen_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_stay_date    DATE,
  total_stays       INTEGER NOT NULL DEFAULT 0,
  total_nights      INTEGER NOT NULL DEFAULT 0,
  total_revenue     NUMERIC(12,2) NOT NULL DEFAULT 0,
  preferred_room    TEXT,                                 -- most-booked room
  notes             TEXT,                                 -- free-text Jo can add via /comms
  segment           TEXT,                                 -- 'vip' | 'frequent' | 'regular' | 'one-off' | NULL
  realm             TEXT NOT NULL DEFAULT 'work',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (canonical_name)
);

CREATE INDEX IF NOT EXISTS idx_guest_contacts_phone ON guest_contacts (phone_e164)
  WHERE phone_e164 IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_guest_contacts_email ON guest_contacts (email)
  WHERE email IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_guest_contacts_segment ON guest_contacts (segment);

COMMENT ON TABLE guest_contacts IS
'U124-B V136. Person-level rollup of bookings. Keyed on canonical_name.
total_stays/nights/revenue are denormalised — refresh_guest_contacts()
recomputes from accommodation_bookings.';

-- ── Backfill function — call from cron or after big imports ────────────
CREATE OR REPLACE FUNCTION refresh_guest_contacts()
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
  rows_affected INTEGER;
BEGIN
  WITH stats AS (
    SELECT
      guest_name_canonical AS canonical_name,
      MIN(guest_name)      AS display_name,
      MIN(guest_phone)     AS phone_e164,
      MIN(guest_email)     AS email,
      MIN(checkin_date)    AS first_seen,
      MAX(checkout_date)   AS last_stay_date,
      COUNT(*)             AS total_stays,
      SUM(GREATEST((checkout_date - checkin_date), 0))::int AS total_nights,
      SUM(COALESCE(total_amount, gross_amount, 0))          AS total_revenue,
      MODE() WITHIN GROUP (ORDER BY room) AS preferred_room
      FROM accommodation_bookings
     WHERE status NOT IN ('superseded','duplicate','cancelled')
       AND guest_name_canonical IS NOT NULL
       AND guest_name_canonical <> ''
     GROUP BY guest_name_canonical
  )
  INSERT INTO guest_contacts
    (canonical_name, display_name, phone_e164, email,
     first_seen_at, last_stay_date, total_stays, total_nights, total_revenue,
     preferred_room, segment)
  SELECT
    s.canonical_name,
    s.display_name,
    s.phone_e164,
    s.email,
    COALESCE(s.first_seen::timestamptz, now()),
    s.last_stay_date,
    s.total_stays,
    s.total_nights,
    s.total_revenue,
    s.preferred_room,
    CASE
      WHEN s.total_stays >= 5 OR s.total_revenue >= 5000 THEN 'vip'
      WHEN s.total_stays >= 3 THEN 'frequent'
      WHEN s.total_stays = 2 THEN 'regular'
      ELSE 'one-off'
    END
  FROM stats s
  ON CONFLICT (canonical_name) DO UPDATE SET
     display_name   = COALESCE(guest_contacts.display_name, EXCLUDED.display_name),
     phone_e164     = COALESCE(EXCLUDED.phone_e164, guest_contacts.phone_e164),
     email          = COALESCE(EXCLUDED.email,      guest_contacts.email),
     last_stay_date = EXCLUDED.last_stay_date,
     total_stays    = EXCLUDED.total_stays,
     total_nights   = EXCLUDED.total_nights,
     total_revenue  = EXCLUDED.total_revenue,
     preferred_room = EXCLUDED.preferred_room,
     segment        = EXCLUDED.segment,
     updated_at     = now();
  GET DIAGNOSTICS rows_affected = ROW_COUNT;
  RETURN rows_affected;
END
$$;

COMMENT ON FUNCTION refresh_guest_contacts() IS
'U124-B V136. Idempotent: rebuilds guest_contacts from accommodation_bookings.
Run after each booking ingest, or on a daily cron.';

-- Initial backfill
SELECT refresh_guest_contacts() AS rows_inserted_or_updated;

-- ── Views for daily email + CRM page ───────────────────────────────────
DROP VIEW IF EXISTS v_guest_ltv CASCADE;
CREATE VIEW v_guest_ltv AS
SELECT
  canonical_name,
  display_name,
  total_stays,
  total_nights,
  total_revenue,
  ROUND(total_revenue / NULLIF(total_stays, 0), 2) AS avg_stay_value,
  ROUND(total_revenue / NULLIF(total_nights, 0), 2) AS revenue_per_night,
  last_stay_date,
  (CURRENT_DATE - last_stay_date) AS days_since_last_stay,
  preferred_room,
  segment,
  phone_e164, email
FROM guest_contacts
ORDER BY total_revenue DESC;

-- "Repeat guest detector" — guests arriving today/tomorrow who have a prior stay
DROP VIEW IF EXISTS v_repeat_arrivals CASCADE;
CREATE VIEW v_repeat_arrivals AS
SELECT
  ab.id AS booking_id,
  ab.guest_name AS booking_name,
  ab.room,
  ab.checkin_date,
  ab.checkout_date,
  gc.display_name AS known_as,
  gc.total_stays      AS prior_stays,    -- includes the current pending one
  gc.total_revenue    AS lifetime_revenue,
  gc.preferred_room,
  gc.segment,
  gc.last_stay_date,
  (gc.total_stays - 1) AS prior_visits_completed,
  gc.notes AS guest_notes
FROM accommodation_bookings ab
JOIN guest_contacts gc ON gc.canonical_name = ab.guest_name_canonical
WHERE ab.checkin_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 2
  AND ab.status IN ('confirmed','deposit_paid','paid','active')
  AND gc.total_stays > 1
ORDER BY ab.checkin_date, gc.total_revenue DESC;

INSERT INTO query_whitelist (slug, display_name, sql_template, description,
                              created_by, realm, entity_id, intent_examples,
                              approved_at, approved_by)
VALUES
  ('guest_ltv_top',
   'U124-B — top guests by LTV',
   'SELECT canonical_name, display_name, total_stays, total_nights, total_revenue, avg_stay_value, last_stay_date, segment FROM v_guest_ltv LIMIT 50',
   'Top 50 guests by lifetime revenue',
   'u124','owner',1, ARRAY['top guests','ltv','best customers'],
   now(),'u124'),
  ('repeat_arrivals_3d',
   'U124-B — repeat guests arriving ≤ 3d',
   'SELECT booking_name, known_as, room, checkin_date, prior_visits_completed, lifetime_revenue, segment, guest_notes FROM v_repeat_arrivals',
   'Guests arriving in the next 3 days who have stayed before',
   'u124','owner',1, ARRAY['repeat guests','welcome back','arriving'],
   now(),'u124'),
  ('guest_segments_summary',
   'U124-B — guest base by segment',
   'SELECT segment, COUNT(*) guests, SUM(total_stays) total_stays, SUM(total_revenue)::numeric(12,2) lifetime_revenue FROM guest_contacts GROUP BY segment ORDER BY lifetime_revenue DESC NULLS LAST',
   'Breakdown of guest base by VIP/frequent/regular/one-off',
   'u124','owner',1, ARRAY['guest segments','customer base'],
   now(),'u124')
ON CONFLICT (slug) DO UPDATE SET
  sql_template=EXCLUDED.sql_template, approved_at=now(), approved_by='u124';

COMMIT;
