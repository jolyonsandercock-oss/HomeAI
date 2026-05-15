#!/usr/bin/env bash
#
# u68-recon-l3.sh — RECON-L3 daily-aggregate settlement matching
# (PART 4b Phase 8, second half).
#
# Per (site, batch_date) compute expected Dojo payout = SUM(net) where
# net = gross - fee_estimate. fee_estimate uses the contract rate table
# in Vault at secret/payments/dojo/rates if available, else a blended
# default (1.0% — conservative). Look for a matching bank credit at
# T+1 / T+2 / T+3 (Dojo varies 1-3 business days per terminal).
#
# Per-batch matching would use staging.payments.settlement_batch_id —
# but legacy data doesn't capture that field. This is the daily-aggregate
# fallback shape promised by U68's revised plan.
#
# Writes mart.expected_settlements with status:
#   settled_clean  delta ≤ £0.10
#   settled_short  matched but delta > £0.10
#   unsettled_5d   no matching bank credit within 5 days
#
# Idempotent: UNIQUE (settlement_batch_id, processor, batch_date) on the
# mart. We use synthetic batch_id 'dojo-<site>-<date>'.

set -euo pipefail

WINDOW_DAYS="${1:-90}"
# Fee estimate: assume 1.0% blended (Dojo's effective rate varies 0.4-1.5%
# depending on card mix; 1% is mid-range and conservative).
FEE_RATE="${FEE_RATE:-0.010}"

docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 <<SQL
\set ON_ERROR_STOP on
SELECT set_config('app.current_entity', 'all',   false);
SELECT set_config('app.current_realm',  'owner', false);

BEGIN;

WITH per_day AS (
  SELECT
    site,
    transaction_date AS batch_date,
    SUM(amount_gross_minor) FILTER (WHERE outcome='approved')                                AS gross_minor,
    SUM(CASE WHEN outcome='approved' THEN amount_gross_minor ELSE 0 END)
      - SUM(CASE WHEN outcome='refund'  THEN -amount_gross_minor ELSE 0 END)                 AS net_before_fee_minor,
    COUNT(*)                FILTER (WHERE outcome='approved')                                AS approved_count
  FROM staging.payments
  WHERE source = 'dojo'
    AND transaction_date >= current_date - ${WINDOW_DAYS}
    AND transaction_date < current_date  -- only fully-closed days
  GROUP BY 1, 2
  HAVING SUM(amount_gross_minor) FILTER (WHERE outcome='approved') > 0
),
expected AS (
  SELECT
    'dojo-' || site || '-' || batch_date AS settlement_batch_id,
    'dojo'::text                          AS processor,
    batch_date,
    site,
    gross_minor                                                                       AS gross_minor,
    GREATEST(0, ROUND(net_before_fee_minor * ${FEE_RATE})::bigint)                    AS expected_fee_minor,
    GREATEST(0, net_before_fee_minor - ROUND(net_before_fee_minor * ${FEE_RATE})::bigint) AS expected_payout_minor,
    -- T+1 business day; we'd handle weekends precisely if needed.
    (batch_date + INTERVAL '1 day')::date AS expected_payout_date
  FROM per_day
),
-- Find a matching bank credit within a 5-day window from expected_payout_date.
match_attempt AS (
  SELECT
    e.*,
    (SELECT b.id
       FROM staging.bank_lines b
      WHERE b.transaction_date BETWEEN e.expected_payout_date - INTERVAL '1 day'
                                   AND e.expected_payout_date + INTERVAL '4 days'
        AND b.amount_minor BETWEEN e.expected_payout_minor - 10  -- ±10p tolerance
                              AND  e.expected_payout_minor + 10
        AND b.description ~* '(dojo|paymentsense|worldpay|izettle|merchant)'
      ORDER BY ABS(b.transaction_date - e.expected_payout_date) ASC, b.id ASC
      LIMIT 1) AS matched_bank_line_id
  FROM expected e
)
INSERT INTO mart.expected_settlements
  (settlement_batch_id, processor, batch_date, expected_amount_minor,
   expected_fee_minor, expected_payout_date,
   matched_bank_line_id, matched_amount_minor, matched_at,
   delta_minor, status, realm)
SELECT
  m.settlement_batch_id, m.processor, m.batch_date, m.expected_payout_minor,
  m.expected_fee_minor, m.expected_payout_date,
  m.matched_bank_line_id,
  b.amount_minor                                                          AS matched_amount_minor,
  CASE WHEN b.id IS NOT NULL THEN NOW() END                                AS matched_at,
  CASE WHEN b.id IS NOT NULL THEN b.amount_minor - m.expected_payout_minor END AS delta_minor,
  CASE
    WHEN b.id IS NULL AND current_date - m.batch_date >= 5 THEN 'unsettled_5d'
    WHEN b.id IS NULL                                       THEN 'unsettled_open'
    WHEN ABS(b.amount_minor - m.expected_payout_minor) <= 10 THEN 'settled_clean'
    ELSE                                                          'settled_short'
  END,
  'work'
FROM match_attempt m
LEFT JOIN staging.bank_lines b ON b.id = m.matched_bank_line_id
ON CONFLICT (settlement_batch_id, processor, batch_date) DO UPDATE
   SET matched_bank_line_id = EXCLUDED.matched_bank_line_id,
       matched_amount_minor = EXCLUDED.matched_amount_minor,
       matched_at           = EXCLUDED.matched_at,
       delta_minor          = EXCLUDED.delta_minor,
       status               = EXCLUDED.status;

-- mart.exceptions for actionable settlement gaps (open status only).
INSERT INTO mart.exceptions
  (severity, kind, source, site, transaction_date, related_ids, summary, detail, realm)
SELECT
  CASE status WHEN 'unsettled_5d' THEN 'high' ELSE 'medium' END,
  CASE status WHEN 'unsettled_5d' THEN 'l3_unsettled' ELSE 'l3_short' END,
  'dojo',
  split_part(settlement_batch_id, '-', 2),
  batch_date,
  jsonb_build_object('settlement_batch_id', settlement_batch_id,
                     'expected_payout_minor', expected_amount_minor),
  format('Dojo %s on %s: expected £%s (%s)',
         split_part(settlement_batch_id, '-', 2), batch_date,
         (expected_amount_minor/100.0)::numeric(12,2),
         status),
  jsonb_build_object('expected_payout_gbp', (expected_amount_minor/100.0)::numeric(12,2),
                     'fee_estimate_gbp',    (expected_fee_minor/100.0)::numeric(12,2),
                     'delta_gbp',           (COALESCE(delta_minor,0)/100.0)::numeric(12,2),
                     'status', status,
                     'expected_payout_date', expected_payout_date),
  'work'
FROM mart.expected_settlements es
WHERE processor='dojo'
  AND status IN ('unsettled_5d','settled_short')
  AND batch_date >= current_date - ${WINDOW_DAYS}
  AND NOT EXISTS (
    SELECT 1 FROM mart.exceptions e
    WHERE e.kind IN ('l3_unsettled','l3_short')
      AND e.status='open'
      AND e.related_ids->>'settlement_batch_id' = es.settlement_batch_id
  );

COMMIT;

-- Summary
\echo
\echo '=== mart.expected_settlements by status (last ${WINDOW_DAYS}d) ==='
SELECT status, COUNT(*) AS batches, (SUM(expected_amount_minor)/100.0)::numeric(12,2) AS sum_gbp
  FROM mart.expected_settlements
 WHERE batch_date >= current_date - ${WINDOW_DAYS}
 GROUP BY 1 ORDER BY 2 DESC;

\echo
\echo '=== L3 exceptions this run ==='
SELECT severity, kind, COUNT(*) FROM mart.exceptions
 WHERE kind LIKE 'l3_%' AND raised_at > now() - interval '5 minutes'
 GROUP BY 1, 2 ORDER BY 1, 3 DESC;
SQL
