-- =============================================================================
-- V111 — U84 Item 4: till variance findings + auto-surface as exceptions
-- =============================================================================
-- Two problems Jo's data showed:
--   1. 249 future-dated all-zero pre-seeded rows pollute aggregate views.
--   2. Real variances (£220 on 2026-05-14, £80 on 2026-05-07) don't surface
--      anywhere; Jo only sees them if he opens /recon directly.
--
-- Fix:
--   - DELETE the future-dated junk rows (they have NULL z_reading + 0
--     cash_counted and were pre-seeded by an earlier script, never used).
--   - Add v_till_variance_findings view for variances >= £20.
--   - Trigger writes to mart.exceptions on insert/update when the variance
--     crosses the threshold, so /work/actions surfaces them automatically.
-- =============================================================================

BEGIN;

SELECT set_config('app.current_entity', 'all', false);
SELECT home_ai.set_realm('owner');

-- 1. Clean the future-dated all-zero junk.
DELETE FROM till_reconciliation
 WHERE recon_date > CURRENT_DATE
   AND z_reading IS NULL
   AND COALESCE(cash_counted, 0) = 0
   AND COALESCE(card_total, 0) = 0;

-- 2. Findings view.
DROP VIEW IF EXISTS v_till_variance_findings CASCADE;
CREATE VIEW v_till_variance_findings AS
SELECT
  tr.id,
  tr.recon_date,
  tr.site,
  tr.session,
  tr.z_reading,
  tr.expected_cash,
  tr.cash_counted,
  tr.variance,
  tr.variance_pct,
  ABS(COALESCE(tr.variance, 0))                   AS abs_variance,
  CASE
    WHEN ABS(COALESCE(tr.variance, 0)) >= 100 THEN 'high'
    WHEN ABS(COALESCE(tr.variance, 0)) >=  20 THEN 'medium'
    ELSE                                              'low'
  END                                              AS severity,
  tr.realm
FROM till_reconciliation tr
WHERE tr.variance IS NOT NULL
  AND ABS(tr.variance) >= 20
  AND tr.recon_date <= CURRENT_DATE
  AND tr.recon_date >= CURRENT_DATE - 60;

COMMENT ON VIEW v_till_variance_findings IS
'U84 V111. Till-reconciliation rows with abs variance >= £20 in last 60 days.';

-- 3. Trigger: surface significant variances as exceptions automatically.
CREATE OR REPLACE FUNCTION public.till_variance_to_exception()
RETURNS trigger
LANGUAGE plpgsql AS $function$
DECLARE
  v_severity text;
  v_summary  text;
BEGIN
  -- Only fire when we have a real variance.
  IF NEW.variance IS NULL OR ABS(NEW.variance) < 20 THEN
    RETURN NEW;
  END IF;
  IF NEW.recon_date > CURRENT_DATE THEN
    RETURN NEW;  -- future-dated rows are junk
  END IF;

  v_severity := CASE
    WHEN ABS(NEW.variance) >= 100 THEN 'high'
    ELSE                               'medium'
  END;
  v_summary := format(
    'Till variance %sGBP%s at %s on %s (expected %s, counted %s)',
    CASE WHEN NEW.variance < 0 THEN '-' ELSE '+' END,
    ABS(NEW.variance),
    NEW.site,
    NEW.recon_date,
    COALESCE(NEW.expected_cash, 0),
    COALESCE(NEW.cash_counted, 0)
  );

  -- Use the existing UNIQUE on (kind, COALESCE(site), COALESCE(transaction_date))
  -- (idx uq_mart_exceptions_hunters_kind_site_date) when status='open' to
  -- avoid duplicate spam if the row is updated multiple times.
  INSERT INTO mart.exceptions
    (severity, kind, source, site, transaction_date, summary, detail, status, realm)
  VALUES
    (v_severity, 'till_variance_high', 'till_reconciliation',
     NEW.site, NEW.recon_date, v_summary,
     jsonb_build_object(
       'recon_id', NEW.id,
       'variance', NEW.variance,
       'expected_cash', NEW.expected_cash,
       'cash_counted',  NEW.cash_counted,
       'z_reading',     NEW.z_reading),
     'open', COALESCE(NEW.realm, 'work'))
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS trg_till_variance_exception ON till_reconciliation;
CREATE TRIGGER trg_till_variance_exception
AFTER INSERT OR UPDATE OF variance, expected_cash, cash_counted
ON till_reconciliation
FOR EACH ROW EXECUTE FUNCTION till_variance_to_exception();

-- 4. Backfill: surface the existing findings as open exceptions.
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN SELECT * FROM v_till_variance_findings
           WHERE NOT EXISTS (
             SELECT 1 FROM mart.exceptions e
              WHERE e.kind = 'till_variance_high'
                AND e.transaction_date = v_till_variance_findings.recon_date
                AND e.site = v_till_variance_findings.site
                AND e.status = 'open'
           )
  LOOP
    INSERT INTO mart.exceptions
      (severity, kind, source, site, transaction_date, summary, detail, status, realm)
    VALUES (
      r.severity, 'till_variance_high', 'till_reconciliation',
      r.site, r.recon_date,
      format('Till variance %sGBP%s at %s on %s',
        CASE WHEN r.variance < 0 THEN '-' ELSE '+' END,
        ABS(r.variance), r.site, r.recon_date),
      jsonb_build_object(
        'recon_id', r.id, 'variance', r.variance,
        'expected_cash', r.expected_cash, 'cash_counted', r.cash_counted),
      'open', r.realm
    ) ON CONFLICT DO NOTHING;
  END LOOP;
END $$;

COMMIT;
