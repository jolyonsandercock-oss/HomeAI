-- =============================================================================
-- V93 — Missing-data hunters (U72 T2)
-- =============================================================================
-- Cron-driven detectors that emit mart.exceptions rows when expected data
-- doesn't arrive. Idempotent: a hunter only inserts when no open exception
-- of the same kind+date already exists.
--
-- Hunters in this batch:
--   to_scrape_gap          — no touchoffice_scrapes row in N hours
--   dojo_settlement_gap    — no staging.payments row in N hours
--   till_recon_missing     — no till_reconciliation for yesterday (per site)
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

CREATE OR REPLACE FUNCTION mart.run_missing_data_hunters()
RETURNS TABLE(kind text, raised int)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    latest_to       timestamptz;
    latest_dojo     date;
    n_to_gap        int := 0;
    n_dojo_gap      int := 0;
    n_till_missing  int := 0;
BEGIN
    PERFORM set_config('app.current_entity', 'all', false);
    PERFORM home_ai.set_realm('work');

    -- 1. TouchOffice scrape gap: latest scrape > 26h ago.
    SELECT max(scraped_at) INTO latest_to FROM touchoffice_scrapes;
    IF latest_to IS NULL OR latest_to < now() - interval '26 hours' THEN
        INSERT INTO mart.exceptions
            (severity, kind, source, transaction_date, summary, detail, status, realm)
        SELECT 'high', 'to_scrape_gap', 'touchoffice', current_date,
               format('No TouchOffice scrape in %s — last was %s',
                      CASE WHEN latest_to IS NULL THEN 'history'
                           ELSE (age(now(), latest_to))::text END,
                      COALESCE(latest_to::text, 'never')),
               jsonb_build_object('latest_scrape_at', latest_to),
               'open', 'work'
        WHERE NOT EXISTS (
            SELECT 1 FROM mart.exceptions
             WHERE kind='to_scrape_gap' AND status='open'
               AND raised_at > now() - interval '12 hours'
        );
        GET DIAGNOSTICS n_to_gap = ROW_COUNT;
    END IF;

    -- 2. Dojo settlement gap: latest settlement > yesterday.
    SELECT max(transaction_date) INTO latest_dojo
      FROM staging.payments WHERE source = 'dojo';
    IF latest_dojo IS NULL OR latest_dojo < current_date - 1 THEN
        INSERT INTO mart.exceptions
            (severity, kind, source, transaction_date, summary, detail, status, realm)
        SELECT 'high', 'dojo_settlement_gap', 'dojo', current_date,
               format('Dojo settlement gap — last transaction_date %s',
                      COALESCE(latest_dojo::text, 'never')),
               jsonb_build_object('latest_settlement_date', latest_dojo),
               'open', 'work'
        WHERE NOT EXISTS (
            SELECT 1 FROM mart.exceptions
             WHERE kind='dojo_settlement_gap' AND status='open'
               AND raised_at > now() - interval '12 hours'
        );
        GET DIAGNOSTICS n_dojo_gap = ROW_COUNT;
    END IF;

    -- 3. Missing till_reconciliation for yesterday per site that traded.
    -- A site "traded" if it has a touchoffice_plu_sales row for yesterday.
    -- Open one exception per missing site/date pair, idempotent.
    INSERT INTO mart.exceptions
        (severity, kind, source, site, transaction_date, summary, detail, status, realm)
    SELECT 'medium',
           'till_recon_missing',
           'till+touchoffice',
           tps.site,
           current_date - 1,
           format('No till_reconciliation row for site=%s date=%s — manager '
                  'should record cashing-up via /m',
                  tps.site, current_date - 1),
           jsonb_build_object('plu_units', sum(tps.quantity),
                              'plu_value', sum(tps.value)),
           'open',
           'work'
      FROM touchoffice_plu_sales tps
     WHERE tps.report_date = current_date - 1
     GROUP BY tps.site
    HAVING NOT EXISTS (
         SELECT 1 FROM till_reconciliation tr
          WHERE tr.recon_date = current_date - 1 AND tr.site = tps.site
       )
       AND NOT EXISTS (
         SELECT 1 FROM mart.exceptions e
          WHERE e.kind='till_recon_missing' AND e.site = tps.site
            AND e.transaction_date = current_date - 1
       );
    GET DIAGNOSTICS n_till_missing = ROW_COUNT;

    RETURN QUERY VALUES
        ('to_scrape_gap',       n_to_gap),
        ('dojo_settlement_gap', n_dojo_gap),
        ('till_recon_missing',  n_till_missing);
END;
$$;

GRANT EXECUTE ON FUNCTION mart.run_missing_data_hunters() TO homeai_pipeline;

COMMIT;
