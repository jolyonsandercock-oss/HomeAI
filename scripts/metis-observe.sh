#!/bin/bash
# scripts/metis-observe.sh — OBSERVE stage for invoice.categorise.
# Writes one cognition.task_runs row. Cron: nightly, AFTER u-invoice-categorise-sweep.
set -uo pipefail
source "$(dirname "$0")/metis/common.sh"
metis_psql <<SQL
$METIS_GUC
INSERT INTO cognition.task_runs (task_id, metrics, realm)
SELECT 'invoice.categorise',
  jsonb_build_object(
    'population',     count(*) FILTER (WHERE is_statement=false AND status NOT IN ('duplicate','ignored')),
    'categorised',    count(*) FILTER (WHERE category_canonical IS NOT NULL AND is_statement=false AND status NOT IN ('duplicate','ignored')),
    'uncategorised',  count(*) FILTER (WHERE category_canonical IS NULL AND is_statement=false AND status NOT IN ('duplicate','ignored')),
    'coverage_pct',   round(100.0 * count(*) FILTER (WHERE category_canonical IS NOT NULL AND is_statement=false AND status NOT IN ('duplicate','ignored'))
                            / NULLIF(count(*) FILTER (WHERE is_statement=false AND status NOT IN ('duplicate','ignored')),0), 1),
    'mismatch_over_1k', 0
  ),
  'work'
FROM vendor_invoice_inbox;
SQL
echo "metis-observe: wrote task_run for invoice.categorise"
