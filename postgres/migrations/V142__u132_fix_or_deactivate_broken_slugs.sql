-- =============================================================================
-- V142 — U132: fix / deactivate slugs that 500 when queried
-- =============================================================================
-- Audit on 2026-05-19 found 3 slugs in query_whitelist that error out:
--   1. frontend_seven_day_strip — ambiguous "d" column reference in SQL
--   2. frontend_pipeline_health — depends on v_pipeline_health (missing view)
--   3. table_reminder_candidates — depends on v_table_reminder_candidates
--      (missing view)
--
-- Strategy:
--   #1 has a clear correct rewrite (it's currently the only seven-day strip
--      view, useful for the homepage). Fix in place.
--   #2 and #3 reference views that were planned but never landed. The /backend
--      page already has a placeholder hint pointing at the missing view.
--      Deactivate the slugs so audits show 0 broken; re-activate when the
--      view is authored.
-- =============================================================================

BEGIN;

-- 1. frontend_seven_day_strip — restructured CTEs so each one keys off the
--    same `dates.day` column, no ambiguity, no group-then-correlate trick.
UPDATE query_whitelist
   SET sql_template = $sql$WITH dates AS (
                             SELECT generate_series(CURRENT_DATE - INTERVAL '3 days',
                                                    CURRENT_DATE + INTERVAL '3 days',
                                                    INTERVAL '1 day')::date AS day
                           ),
                           sales AS (
                             SELECT report_date, SUM(value)::numeric(12,2) AS gross
                             FROM touchoffice_department_sales
                             WHERE report_date BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE + 7
                             GROUP BY report_date
                           ),
                           occ AS (
                             SELECT d.day, COUNT(b.id) AS rooms_occupied
                             FROM dates d
                             LEFT JOIN accommodation_bookings b
                                    ON b.checkin_date <= d.day
                                   AND b.checkout_date > d.day
                                   AND b.status IN ('confirmed','deposit_paid','paid','active')
                             GROUP BY d.day
                           ),
                           reservations AS (
                             SELECT reservation_at::date AS day, COUNT(*) AS covers
                             FROM restaurant_reservations
                             WHERE reservation_at::date BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE + 7
                               AND status IN ('confirmed','enquiry','arrived')
                             GROUP BY reservation_at::date
                           )
                           SELECT dates.day,
                                  COALESCE(sales.gross, 0)             AS gross,
                                  COALESCE(occ.rooms_occupied, 0)      AS rooms,
                                  COALESCE(reservations.covers, 0)     AS covers
                           FROM dates
                           LEFT JOIN sales        ON sales.report_date = dates.day
                           LEFT JOIN occ          ON occ.day            = dates.day
                           LEFT JOIN reservations ON reservations.day   = dates.day
                           ORDER BY dates.day$sql$,
       approved_at = NOW(),
       notes       = COALESCE(notes, '') || E'\nV142 (U132): fix ambiguous d-column join, scope CTEs to ±7d window'
 WHERE slug = 'frontend_seven_day_strip';

-- 2. frontend_pipeline_health — deactivate until v_pipeline_health is authored.
--    The /backend page has a placeholder hint pointing at this dependency.
UPDATE query_whitelist
   SET active = false,
       notes  = COALESCE(notes, '') || E'\nV142 (U132): deactivated — v_pipeline_health view does not exist. Re-activate when the view is built (heartbeat per service / pipeline).'
 WHERE slug = 'frontend_pipeline_health';

-- 3. table_reminder_candidates — deactivate until v_table_reminder_candidates
--    is authored.
UPDATE query_whitelist
   SET active = false,
       notes  = COALESCE(notes, '') || E'\nV142 (U132): deactivated — v_table_reminder_candidates view does not exist. Re-activate when the view is built (T-24h restaurant reminder candidates).'
 WHERE slug = 'table_reminder_candidates';

COMMIT;
