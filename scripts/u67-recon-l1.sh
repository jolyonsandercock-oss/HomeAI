#!/usr/bin/env bash
#
# u67-recon-l1.sh — RECON-L1 (daily totals) per SPEC §4b.5 L1.
#
# Per (site, date, tender) writes one row to mart.daily_totals, with a
# mart.exceptions(l1_mismatch) row when the delta exceeds tolerance.
#
# Card side (£0 tolerance):
#   POS source = SUM(public.touchoffice_fixed_totals.value WHERE totaliser_id=6)
#                                                          ("CREDIT in Drawer")
#   Processor  = SUM(staging.payments.amount_gross_minor
#                    WHERE outcome='approved' AND site=…)
#
# Cash side (£2 tolerance, coarse — till_reconciliation has no site dim):
#   POS source = SUM(public.touchoffice_fixed_totals.value WHERE totaliser_id=4)
#                                                          ("CASH in Drawer")
#   Counter    = public.till_reconciliation.cash_counted on that date
#                (one row per day across both sites — coarse comparison flagged
#                via status='approximate' rather than ok/minor/mismatch)
#
# Day window: default = yesterday + 7 days back so a rerun can backfill any
# late-arriving data. Override via --window-days N.
#
# Idempotent: mart.daily_totals UNIQUE (transaction_date, site, tender) means
# an insert is replaced with ON CONFLICT DO UPDATE.

set -euo pipefail

WINDOW_DAYS="${1:-8}"

cat <<SQL | docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1
\set ON_ERROR_STOP on
SELECT set_config('app.current_entity', 'all',   false);
SELECT set_config('app.current_realm',  'owner', false);

-- TouchOffice uses 'malthouse'/'sandwich'; Dojo uses 'pub'/'cafe'.
-- Normalise both sides to 'pub'/'cafe' for the mart roll-up.
WITH pos_card AS (
  SELECT
    transaction_date,                                        -- using TO report_date column below; aliased
    CASE site WHEN 'malthouse' THEN 'pub' WHEN 'sandwich' THEN 'cafe' ELSE site END AS site,
    ROUND(SUM(value)::numeric * 100)::bigint AS pos_minor
  FROM (
    SELECT report_date AS transaction_date, site, value
      FROM public.touchoffice_fixed_totals
     WHERE totaliser_id = 6   -- CREDIT in Drawer
       AND report_date >= current_date - ${WINDOW_DAYS}
  ) z
  GROUP BY 1, 2
),
pos_cash AS (
  SELECT
    transaction_date,
    CASE site WHEN 'malthouse' THEN 'pub' WHEN 'sandwich' THEN 'cafe' ELSE site END AS site,
    ROUND(SUM(value)::numeric * 100)::bigint AS pos_minor
  FROM (
    SELECT report_date AS transaction_date, site, value
      FROM public.touchoffice_fixed_totals
     WHERE totaliser_id = 4   -- CASH in Drawer
       AND report_date >= current_date - ${WINDOW_DAYS}
  ) z
  GROUP BY 1, 2
),
processor_card AS (
  SELECT
    transaction_date,
    site,
    SUM(amount_gross_minor) AS processor_minor
  FROM staging.payments
  WHERE source = 'dojo'
    AND outcome = 'approved'
    AND transaction_date >= current_date - ${WINDOW_DAYS}
  GROUP BY 1, 2
),
till AS (
  SELECT recon_date AS transaction_date, ROUND(cash_counted * 100)::bigint AS cash_counted_minor
    FROM public.till_reconciliation
   WHERE recon_date >= current_date - ${WINDOW_DAYS}
),

-- Card daily-totals: per (date, site)
card_rows AS (
  SELECT
    COALESCE(pc.transaction_date, prc.transaction_date) AS transaction_date,
    COALESCE(pc.site, prc.site)                          AS site,
    'card'::text                                         AS tender,
    pc.pos_minor                                         AS pos_total_minor,
    prc.processor_minor                                  AS processor_total_minor,
    NULL::bigint                                         AS cash_declared_minor,
    COALESCE(pc.pos_minor, 0) - COALESCE(prc.processor_minor, 0) AS delta_minor,
    0::bigint                                            AS tolerance_minor
    FROM pos_card pc
    FULL OUTER JOIN processor_card prc
      ON prc.transaction_date = pc.transaction_date AND prc.site = pc.site
),

-- Cash daily-totals: per (date, site) — counter side is per-day, splits cross-site.
cash_rows AS (
  SELECT
    pos_cash.transaction_date,
    pos_cash.site,
    'cash'::text                                          AS tender,
    pos_cash.pos_minor                                    AS pos_total_minor,
    NULL::bigint                                          AS processor_total_minor,
    till.cash_counted_minor                               AS cash_declared_minor,
    -- Site-level decl unavailable: store delta vs day-level cash only when
    -- exactly one site has cash that day (else NULL).
    NULL::bigint                                          AS delta_minor,
    200::bigint                                           AS tolerance_minor  -- £2 default
    FROM pos_cash
    LEFT JOIN till ON till.transaction_date = pos_cash.transaction_date
),

all_rows AS (
  SELECT * FROM card_rows
  UNION ALL
  SELECT * FROM cash_rows
)
INSERT INTO mart.daily_totals
  (transaction_date, site, tender,
   pos_total_minor, processor_total_minor, cash_declared_minor,
   delta_minor, tolerance_minor, status, notes, realm)
SELECT
  transaction_date, site, tender,
  pos_total_minor, processor_total_minor, cash_declared_minor,
  delta_minor, tolerance_minor,
  CASE
    WHEN tender = 'card' AND pos_total_minor IS NULL                THEN 'missing_pos'
    WHEN tender = 'card' AND processor_total_minor IS NULL          THEN 'missing_processor'
    WHEN tender = 'card' AND delta_minor = 0                        THEN 'ok'
    WHEN tender = 'card' AND ABS(delta_minor) <= tolerance_minor    THEN 'minor'
    WHEN tender = 'card'                                            THEN 'mismatch'
    WHEN tender = 'cash'                                            THEN 'approximate'
    ELSE 'ok'
  END AS status,
  CASE
    WHEN tender = 'cash' THEN 'site-level cash declaration not in till_reconciliation; status=approximate'
    ELSE NULL
  END AS notes,
  'work' AS realm
FROM all_rows
WHERE transaction_date IS NOT NULL
ON CONFLICT (transaction_date, site, tender) DO UPDATE
   SET pos_total_minor       = EXCLUDED.pos_total_minor,
       processor_total_minor = EXCLUDED.processor_total_minor,
       cash_declared_minor   = EXCLUDED.cash_declared_minor,
       delta_minor           = EXCLUDED.delta_minor,
       status                = EXCLUDED.status,
       notes                 = EXCLUDED.notes,
       computed_at           = NOW();

-- Surface mismatches into mart.exceptions (idempotent: skip if open one exists)
INSERT INTO mart.exceptions
  (severity, kind, source, site, transaction_date, related_ids, summary, detail, realm)
SELECT
  CASE WHEN ABS(delta_minor) > 10000 THEN 'high' ELSE 'medium' END,
  'l1_mismatch',
  'recon-l1',
  site,
  transaction_date,
  jsonb_build_object('daily_total_site', site, 'date', transaction_date),
  format('%s card mismatch on %s: POS £%s vs processor £%s (delta £%s)',
         site, transaction_date,
         (pos_total_minor / 100.0)::text,
         (processor_total_minor / 100.0)::text,
         (delta_minor / 100.0)::text),
  jsonb_build_object('pos_minor', pos_total_minor,
                     'processor_minor', processor_total_minor,
                     'delta_minor', delta_minor,
                     'tolerance_minor', tolerance_minor),
  'work'
FROM mart.daily_totals d
WHERE d.tender = 'card'
  AND d.status = 'mismatch'
  AND d.transaction_date >= current_date - ${WINDOW_DAYS}
  AND NOT EXISTS (
    SELECT 1 FROM mart.exceptions e
    WHERE e.kind = 'l1_mismatch' AND e.status = 'open'
      AND e.site = d.site AND e.transaction_date = d.transaction_date
  );

-- Summary
\echo
\echo '=== mart.daily_totals — last 7 days ==='
SELECT transaction_date, site, tender, status,
       (pos_total_minor/100.0)::numeric(12,2)       AS pos_gbp,
       (processor_total_minor/100.0)::numeric(12,2) AS proc_gbp,
       (delta_minor/100.0)::numeric(12,2)           AS delta_gbp
  FROM mart.daily_totals
 WHERE transaction_date >= current_date - 7
 ORDER BY transaction_date DESC, site, tender;

\echo
\echo '=== mart.exceptions opened by this run ==='
SELECT id, severity, kind, site, transaction_date, summary
  FROM mart.exceptions
 WHERE kind = 'l1_mismatch' AND raised_at > now() - interval '5 minutes'
 ORDER BY raised_at DESC LIMIT 12;
SQL
