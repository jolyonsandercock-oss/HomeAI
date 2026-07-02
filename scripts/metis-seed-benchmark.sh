#!/bin/bash
# scripts/metis-seed-benchmark.sh — freeze high-confidence vendor→category labels.
set -euo pipefail
source "$(dirname "$0")/metis/common.sh"
metis_psql <<'SQL'
SET app.current_entity='all'; SET app.current_realm='owner';
INSERT INTO cognition.benchmark_labels (task_id, key, expected, added_by, realm)
SELECT 'invoice.categorise', vendor_domain, max(vendor_category), 'seed', 'work'
FROM vendor_invoice_inbox
WHERE vendor_category IS NOT NULL AND is_statement=false AND status NOT IN ('duplicate','ignored')
GROUP BY vendor_domain
HAVING count(DISTINCT vendor_category)=1 AND count(*)>=3
ON CONFLICT (task_id,key) DO NOTHING;
SQL
echo "metis-seed-benchmark: frozen labels seeded"
