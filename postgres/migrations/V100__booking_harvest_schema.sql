-- =============================================================================
-- V100 — booking harvest schema (U94 T1)
-- =============================================================================
-- Extends `accommodation_bookings` with the fields the harvester needs and
-- adds `booking_messages` for thread linkage.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- ── accommodation_bookings extensions ──────────────────────────────────────
ALTER TABLE accommodation_bookings
    ADD COLUMN IF NOT EXISTS booking_type        TEXT DEFAULT 'accommodation'
        CHECK (booking_type IN ('accommodation','restaurant','enquiry')),
    ADD COLUMN IF NOT EXISTS ingested_at         TIMESTAMPTZ DEFAULT now(),
    ADD COLUMN IF NOT EXISTS source_email_id     TEXT,
    ADD COLUMN IF NOT EXISTS source_account      TEXT,
    ADD COLUMN IF NOT EXISTS payment_status      TEXT DEFAULT 'unknown'
        CHECK (payment_status IN ('unknown','unpaid','deposit_paid','paid','refunded','cancelled')),
    ADD COLUMN IF NOT EXISTS payment_reference   TEXT,
    ADD COLUMN IF NOT EXISTS canonical_id        BIGINT,
    ADD COLUMN IF NOT EXISTS realm               TEXT NOT NULL DEFAULT 'work'
        CHECK (realm IN ('owner','work','family','shared'));

-- Backfill realm on existing rows
UPDATE accommodation_bookings SET realm='work' WHERE realm IS NULL;

-- Idempotency: (source, source_ref) should be UNIQUE.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'uq_accommodation_bookings_source_ref'
    ) THEN
        ALTER TABLE accommodation_bookings
            ADD CONSTRAINT uq_accommodation_bookings_source_ref UNIQUE (source, source_ref);
    END IF;
END$$;

CREATE INDEX IF NOT EXISTS idx_ab_checkin   ON accommodation_bookings (checkin_date);
CREATE INDEX IF NOT EXISTS idx_ab_guest_trgm ON accommodation_bookings USING gin (guest_name gin_trgm_ops);

ALTER TABLE accommodation_bookings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS realm_isolation ON accommodation_bookings;
CREATE POLICY realm_isolation ON accommodation_bookings
    USING (CASE
        WHEN COALESCE(current_setting('app.current_realm', true), '') IN ('', 'owner') THEN TRUE
        ELSE realm = current_setting('app.current_realm', true)
    END);

-- ── booking_messages — thread linkage ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS booking_messages (
    id                BIGSERIAL PRIMARY KEY,
    booking_id        BIGINT REFERENCES accommodation_bookings(id) ON DELETE CASCADE,
    gmail_account     TEXT NOT NULL,
    gmail_message_id  TEXT NOT NULL,
    received_at       TIMESTAMPTZ NOT NULL,
    from_address      TEXT,
    subject           TEXT,
    body_excerpt      TEXT,                       -- first ~1k chars for thread preview
    direction         TEXT DEFAULT 'inbound'
        CHECK (direction IN ('inbound','outbound')),
    realm             TEXT NOT NULL DEFAULT 'work'
        CHECK (realm IN ('owner','work','family','shared')),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (gmail_account, gmail_message_id)
);

CREATE INDEX IF NOT EXISTS idx_bm_booking ON booking_messages (booking_id);
CREATE INDEX IF NOT EXISTS idx_bm_received ON booking_messages (received_at DESC);

ALTER TABLE booking_messages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS realm_isolation ON booking_messages;
CREATE POLICY realm_isolation ON booking_messages
    USING (CASE
        WHEN COALESCE(current_setting('app.current_realm', true), '') IN ('', 'owner') THEN TRUE
        ELSE realm = current_setting('app.current_realm', true)
    END);

GRANT SELECT, INSERT, UPDATE ON accommodation_bookings, booking_messages TO homeai_pipeline;
GRANT USAGE, SELECT ON booking_messages_id_seq TO homeai_pipeline;

COMMIT;
