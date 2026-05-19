-- =============================================================================
-- V148 — U133 T8 (cont): review_listings config table
-- =============================================================================
-- Per-source/location URLs the reviews scraper iterates over. Empty by
-- default; Jo (or a maintenance script) populates rows like:
--   INSERT INTO review_listings (source, location, listing_url)
--   VALUES ('google',      'malthouse', 'https://www.google.com/maps/place/.../reviews'),
--          ('tripadvisor', 'malthouse', 'https://www.tripadvisor.co.uk/Restaurant_Review-g...'),
--          ('booking_com', 'malthouse', 'https://www.booking.com/hotel/gb/the-olde-malthouse-inn.html');
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS review_listings (
    id BIGSERIAL PRIMARY KEY,
    source         TEXT NOT NULL CHECK (source IN ('google','tripadvisor','booking_com')),
    location       TEXT NOT NULL,
    listing_url    TEXT NOT NULL,
    active         BOOLEAN NOT NULL DEFAULT true,
    last_scraped_at TIMESTAMPTZ,
    last_status     TEXT,           -- 'ok', 'blocked', 'fetch_fail', etc.
    notes          TEXT,
    created_at     TIMESTAMPTZ DEFAULT now(),
    realm          TEXT NOT NULL DEFAULT 'work',
    UNIQUE (source, location)
);

COMMIT;
