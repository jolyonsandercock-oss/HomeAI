-- V276: add Expedia as a review source (per Jo's instruction + Hermes finding #36).
-- Review notifications arrive from noreply@expediapartnercentral.com / subject "You have a
-- new review"; the u163 email parser is extended to ingest them. Read-only on Expedia itself
-- (email-notification source, not a scraper) — no account/rate/payment touch.
BEGIN;

ALTER TABLE guest_reviews DROP CONSTRAINT IF EXISTS guest_reviews_source_check;
ALTER TABLE guest_reviews
  ADD CONSTRAINT guest_reviews_source_check
  CHECK (source IN ('google', 'tripadvisor', 'booking_com', 'expedia'));

ALTER TABLE review_listings DROP CONSTRAINT IF EXISTS review_listings_source_check;
ALTER TABLE review_listings
  ADD CONSTRAINT review_listings_source_check
  CHECK (source IN ('google', 'tripadvisor', 'booking_com', 'expedia'));

-- Tracker row for the reviews section/aggregator.
INSERT INTO review_listings (source, location, listing_url, active, notes, realm)
VALUES (
  'expedia', 'malthouse', 'https://apps.expediapartnercentral.com/', true,
  'Expedia review notifications ingested from noreply@expediapartnercentral.com / subject "You have a new review" via u163-reviews-from-email.py. Email-notification source, not a scraper; listing_url is the Partner Central root.',
  'work')
ON CONFLICT (source, location) DO UPDATE
  SET active = true, notes = EXCLUDED.notes;

COMMIT;
