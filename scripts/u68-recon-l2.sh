#!/usr/bin/env bash
#
# u68-recon-l2.sh — RECON-L2-light (PART 4b Phase 8, first half).
#
# Full L2 transaction matching needs per-ticket POS data (deferred —
# TouchOffice per-ticket scrape awaits Jo-supervised exploration). Until
# then this ships the processor-side fraud signals that don't need a POS
# counterpart:
#
#   1. Phantom refund: refund_of points at a missing sale.
#   2. Unlinked refund: refund_of NULL — operator/legacy didn't record
#      the original sale. Attempts fuzzy match on (site, amount, ±10d).
#   3. Elevated-risk transactions: entry_mode IN ('keyed','vt').
#   4. Outsized amount: single approved txn > 5σ above site's 90d mean.
#
# Writes mart.transaction_matches + mart.exceptions; idempotent on
# (kind, related_ids->>'staging_payment_id', status='open').

set -euo pipefail

WINDOW_DAYS="${1:-30}"

docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 <<SQL
\set ON_ERROR_STOP on
SELECT set_config('app.current_entity', 'all',   false);
SELECT set_config('app.current_realm',  'owner', false);

BEGIN;

-- Build a temp table for refund-side checks so both INSERTs share state.
-- (Inside the txn so it survives until COMMIT below.)
CREATE TEMP TABLE _l2_phantom ON COMMIT DROP AS
WITH refunds AS (
  SELECT id, source, source_transaction_id, transaction_date, site, terminal_id,
         amount_gross_minor, refund_of
    FROM staging.payments
   WHERE outcome = 'refund'
     AND transaction_date >= current_date - ${WINDOW_DAYS}
)
SELECT
  r.id, r.source, r.source_transaction_id, r.transaction_date, r.site,
  r.amount_gross_minor, r.refund_of,
  CASE
    WHEN r.refund_of IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM staging.payments p2
       WHERE p2.source = r.source
         AND p2.source_transaction_id = r.refund_of
    ) THEN 'phantom_refund'
    WHEN r.refund_of IS NULL THEN 'unlinked_refund'
    ELSE 'matched_refund'
  END AS outcome,
  COALESCE((
    SELECT COUNT(*) FROM staging.payments c
     WHERE c.outcome='approved' AND c.source=r.source AND c.site=r.site
       AND c.amount_gross_minor = -r.amount_gross_minor
       AND c.transaction_date BETWEEN (r.transaction_date - INTERVAL '10 days')::date
                                  AND  r.transaction_date
  ), 0) AS candidate_count
FROM refunds r;

-- 1+2. INSERT mart.transaction_matches for refund-side rows
INSERT INTO mart.transaction_matches
  (transaction_date, site, pos_id, processor_id, match_outcome,
   delta_minor, minute_offset, last4_pan_match, terminal_match,
   confidence, reasoning, realm)
SELECT
  transaction_date, site, NULL, id, outcome,
  amount_gross_minor, NULL, NULL, NULL,
  CASE outcome WHEN 'phantom_refund' THEN 0.99
               WHEN 'unlinked_refund' THEN 0.50
               ELSE 0.10 END,
  CASE outcome
    WHEN 'unlinked_refund' THEN
      CASE WHEN candidate_count > 0
           THEN 'unlinked — ' || candidate_count || ' candidate sale(s) at same site/amount within ±10d'
           ELSE 'unlinked — no candidate sale found'
      END
    WHEN 'phantom_refund' THEN 'refund_of='||COALESCE(refund_of,'NULL')||' has no matching sale'
    ELSE outcome
  END,
  'work'
FROM _l2_phantom
WHERE outcome IN ('phantom_refund','unlinked_refund')
ON CONFLICT DO NOTHING;

-- 1+2. INSERT mart.exceptions for actionable refund cases
INSERT INTO mart.exceptions
  (severity, kind, source, site, transaction_date, related_ids, summary, detail, realm)
SELECT
  CASE outcome
    WHEN 'phantom_refund'  THEN 'high'
    WHEN 'unlinked_refund' THEN
      CASE WHEN candidate_count > 0 THEN 'low' ELSE 'medium' END
    ELSE 'low'
  END,
  CASE outcome WHEN 'phantom_refund' THEN 'l2_phantom_refund'
               WHEN 'unlinked_refund' THEN 'l2_unlinked_refund'
               ELSE 'l2_other' END,
  source, site, transaction_date,
  jsonb_build_object('staging_payment_id', id, 'amount_minor', amount_gross_minor, 'refund_of', refund_of),
  format('%s refund £%s on %s',
         INITCAP(REPLACE(outcome,'_',' ')),
         (-amount_gross_minor/100.0)::numeric(12,2),
         transaction_date),
  jsonb_build_object('amount_gbp', (-amount_gross_minor/100.0)::numeric(12,2),
                     'candidate_count', candidate_count),
  'work'
FROM _l2_phantom p
WHERE outcome IN ('phantom_refund','unlinked_refund')
  AND NOT EXISTS (
    SELECT 1 FROM mart.exceptions e
    WHERE e.kind IN ('l2_phantom_refund','l2_unlinked_refund')
      AND e.status='open'
      AND e.related_ids->>'staging_payment_id' = p.id::text
  );

-- 3. Elevated-risk entry modes (inert until adapters capture entry_mode)
INSERT INTO mart.exceptions
  (severity, kind, source, site, transaction_date, related_ids, summary, detail, realm)
SELECT 'medium', 'l2_elevated_risk_mode', source, site, transaction_date,
       jsonb_build_object('staging_payment_id', id, 'entry_mode', entry_mode,
                          'amount_minor', amount_gross_minor),
       format('Elevated-risk %s entry: £%s on %s at %s',
              entry_mode, (amount_gross_minor/100.0)::numeric(12,2),
              transaction_date, site),
       jsonb_build_object('entry_mode', entry_mode,
                          'amount_gbp', (amount_gross_minor/100.0)::numeric(12,2)),
       'work'
  FROM staging.payments
 WHERE entry_mode IN ('keyed','vt')
   AND outcome='approved'
   AND transaction_date >= current_date - ${WINDOW_DAYS}
   AND NOT EXISTS (
     SELECT 1 FROM mart.exceptions e
     WHERE e.kind='l2_elevated_risk_mode' AND e.status='open'
       AND e.related_ids->>'staging_payment_id' = staging.payments.id::text
   );

-- 4. Outsized-amount detection (per-site 5σ)
WITH stats AS (
  SELECT site, AVG(amount_gross_minor) AS mean_minor, STDDEV(amount_gross_minor) AS sd_minor
    FROM staging.payments
   WHERE outcome='approved' AND transaction_date >= current_date - 90
   GROUP BY site
),
outliers AS (
  SELECT p.id, p.source, p.source_transaction_id, p.site, p.transaction_date,
         p.amount_gross_minor, s.mean_minor, s.sd_minor,
         (p.amount_gross_minor - s.mean_minor) / NULLIF(s.sd_minor, 0) AS z_score
    FROM staging.payments p
    JOIN stats s ON s.site = p.site
   WHERE p.outcome='approved'
     AND p.transaction_date >= current_date - ${WINDOW_DAYS}
     AND s.sd_minor > 0
     AND (p.amount_gross_minor - s.mean_minor) / s.sd_minor > 5
)
INSERT INTO mart.exceptions
  (severity, kind, source, site, transaction_date, related_ids, summary, detail, realm)
SELECT 'low', 'l2_outsized_amount', source, site, transaction_date,
       jsonb_build_object('staging_payment_id', id),
       format('Outsized £%s txn at %s on %s (%sσ above 90d mean)',
              (amount_gross_minor/100.0)::numeric(12,2), site, transaction_date,
              round(z_score::numeric, 1)),
       jsonb_build_object('amount_gbp',    (amount_gross_minor/100.0)::numeric(12,2),
                          'site_mean_gbp', (mean_minor/100.0)::numeric(12,2),
                          'z_score',       round(z_score::numeric, 2)),
       'work'
FROM outliers o
WHERE NOT EXISTS (
  SELECT 1 FROM mart.exceptions e WHERE e.kind='l2_outsized_amount' AND e.status='open'
    AND e.related_ids->>'staging_payment_id' = o.id::text
);

COMMIT;

-- Summary
\echo
\echo '=== mart.transaction_matches by outcome (L2-light, last ${WINDOW_DAYS}d) ==='
SELECT match_outcome, COUNT(*) FROM mart.transaction_matches
 WHERE transaction_date >= current_date - ${WINDOW_DAYS} GROUP BY 1 ORDER BY 2 DESC;

\echo
\echo '=== L2 exceptions opened this run ==='
SELECT severity, kind, COUNT(*) FROM mart.exceptions
 WHERE kind LIKE 'l2_%' AND raised_at > now() - interval '5 minutes'
 GROUP BY 1, 2 ORDER BY 1, 3 DESC;
SQL
