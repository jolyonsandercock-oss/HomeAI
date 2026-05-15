-- =============================================================================
-- V92 — Ghost Shift Detector view + runner (U72 T1)
-- =============================================================================
-- A "ghost shift" is a date where TouchOffice records sales at a site but
-- no workforce_shifts exists. With per-ticket TO data this becomes
-- per-operator detection; today we can only do per-site/per-day.
--
-- To avoid false positives from the Tanda 7-day sync lag, we ONLY flag
-- dates that fall within `workforce_sync_log.confirmed_through` minus 1
-- day (last-confirmed sync horizon). Specifically the date must be <=
-- the most recent date for which any workforce_shifts row exists, minus
-- 1 (so we don't flag the actual sync edge).
--
-- Output: mart.v_ghost_shifts (read-only view) + mart.run_ghost_shift_detect()
-- function that inserts severity='medium' rows into mart.exceptions for the
-- last `window_days` of unflagged ghost shifts (idempotent on summary text).
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

CREATE OR REPLACE VIEW mart.v_ghost_shifts AS
WITH horizon AS (
    SELECT max(shift_date) - 1 AS confirmed_through
      FROM workforce_shifts
),
day_sales AS (
    SELECT s.site,
           s.report_date,
           sum(s.quantity) AS plu_units,
           sum(s.value)    AS plu_value
      FROM touchoffice_plu_sales s
     WHERE s.report_date >= current_date - 90
     GROUP BY s.site, s.report_date
)
SELECT d.site,
       d.report_date,
       d.plu_units,
       d.plu_value,
       (SELECT count(*) FROM workforce_shifts ws
         WHERE ws.shift_date = d.report_date) AS shift_count
  FROM day_sales d, horizon h
 WHERE d.report_date <= h.confirmed_through
   AND d.plu_value > 50
   AND (SELECT count(*) FROM workforce_shifts ws
         WHERE ws.shift_date = d.report_date) = 0
 ORDER BY d.report_date DESC, d.site;

GRANT SELECT ON mart.v_ghost_shifts TO homeai_pipeline;


CREATE OR REPLACE FUNCTION mart.run_ghost_shift_detect(window_days int DEFAULT 14)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    inserted int := 0;
BEGIN
    PERFORM set_config('app.current_entity', 'all', false);
    PERFORM home_ai.set_realm('work');

    WITH new_rows AS (
        INSERT INTO mart.exceptions
            (severity, kind, source, site, transaction_date,
             summary, detail, status, realm)
        SELECT 'medium',
               'ghost_shift_day',
               'workforce+touchoffice',
               g.site,
               g.report_date,
               format('Site %s sold £%s on %s but workforce_shifts has 0 rows '
                      '(within Tanda sync horizon)',
                      g.site, round(g.plu_value, 2), g.report_date),
               jsonb_build_object('plu_units', g.plu_units,
                                  'plu_value', g.plu_value,
                                  'shift_count', g.shift_count),
               'open',
               'work'
          FROM mart.v_ghost_shifts g
         WHERE g.report_date >= current_date - window_days
           AND NOT EXISTS (
               SELECT 1 FROM mart.exceptions e
                WHERE e.kind = 'ghost_shift_day'
                  AND e.site = g.site
                  AND e.transaction_date = g.report_date
           )
        RETURNING 1
    )
    SELECT count(*) INTO inserted FROM new_rows;
    RETURN inserted;
END;
$$;

GRANT EXECUTE ON FUNCTION mart.run_ghost_shift_detect(int) TO homeai_pipeline;

COMMIT;
