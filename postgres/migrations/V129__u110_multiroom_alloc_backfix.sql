-- =============================================================================
-- V129 — U110: back-fix multi-room hotel_email gross/total allocation
-- =============================================================================
-- The Brother-scan / Gmail-pipeline parser for booking confirmation emails
-- stores the FULL booking total on every sibling room row when one
-- confirmation covers multiple rooms (e.g. Michelle Carlin × 4 rooms,
-- £656 each → £656 × 4 = £2,624 logged when the actual total was £656).
--
-- Fix: when N sibling rows (same canonical_name + checkin + checkout)
-- all carry an IDENTICAL gross_amount, divide both gross_amount and
-- total_amount by N. Sibling groups with already-distinct per-row prices
-- (where the parser handled them correctly) pass through untouched.
--
-- Audit table records every change so we can spot-check + roll back if a
-- specific group turns out to have been correct.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

CREATE TABLE IF NOT EXISTS accom_alloc_audit (
  id                BIGSERIAL PRIMARY KEY,
  booking_id        BIGINT NOT NULL,
  guest_name        TEXT,
  checkin_date      DATE,
  checkout_date     DATE,
  sibling_count     INTEGER,
  gross_before      NUMERIC(12,2),
  gross_after       NUMERIC(12,2),
  total_before      NUMERIC(12,2),
  total_after       NUMERIC(12,2),
  applied_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  realm             TEXT NOT NULL DEFAULT 'owner'
);
COMMENT ON TABLE accom_alloc_audit IS
'U110 V129. One row per accommodation_bookings row whose gross/total
amount was reduced by V129 multi-room dedup back-fix.';

WITH groups AS (
  SELECT guest_name_canonical, checkin_date, checkout_date,
         COUNT(*) AS sib_count,
         COUNT(DISTINCT gross_amount) AS distinct_amts
    FROM accommodation_bookings
   WHERE source = 'hotel_email'
     AND status IN ('confirmed','deposit_paid','paid','active')
   GROUP BY guest_name_canonical, checkin_date, checkout_date
),
targets AS (
  SELECT b.id, b.guest_name, b.checkin_date, b.checkout_date,
         g.sib_count,
         b.gross_amount AS gross_before,
         b.total_amount AS total_before,
         ROUND((b.gross_amount / g.sib_count)::numeric, 2) AS gross_after,
         ROUND((b.total_amount / g.sib_count)::numeric, 2) AS total_after
    FROM accommodation_bookings b
    JOIN groups g
      ON g.guest_name_canonical = b.guest_name_canonical
     AND g.checkin_date = b.checkin_date
     AND g.checkout_date = b.checkout_date
   WHERE b.source = 'hotel_email'
     AND b.status IN ('confirmed','deposit_paid','paid','active')
     AND g.sib_count > 1
     AND g.distinct_amts = 1
),
upd AS (
  UPDATE accommodation_bookings ab
     SET gross_amount = t.gross_after,
         total_amount = t.total_after
    FROM targets t
   WHERE ab.id = t.id
   RETURNING ab.id, t.sib_count,
             t.gross_before, t.gross_after,
             t.total_before, t.total_after,
             t.guest_name, t.checkin_date, t.checkout_date
),
aud AS (
  INSERT INTO accom_alloc_audit
    (booking_id, guest_name, checkin_date, checkout_date, sibling_count,
     gross_before, gross_after, total_before, total_after)
  SELECT id, guest_name, checkin_date, checkout_date, sib_count,
         gross_before, gross_after, total_before, total_after
    FROM upd
  RETURNING id
)
SELECT (SELECT COUNT(*) FROM upd) AS rows_updated,
       (SELECT COUNT(*) FROM aud) AS rows_audited,
       (SELECT SUM(gross_before - gross_after) FROM upd)::numeric(14,2)
         AS gross_corrected_total;

COMMIT;
