#!/usr/bin/env bash
# scripts/metis-categorise-detect.sh — DETECT→PROPOSE for invoice.categorise.
# Runs the 4 deterministic detectors; inserts proposals; skips rejected signatures
# and benchmark-conflicting category suggestions. Idempotent (ON CONFLICT).
set -uo pipefail
source "$(dirname "$0")/metis/common.sh"
metis_psql <<'SQL'
SET app.current_entity='all'; SET app.current_realm='owner';
WITH det AS (
  SELECT * FROM cognition.fn_detect_categorise_gaps()
  UNION ALL SELECT * FROM cognition.fn_detect_categorise_contradictions()
  UNION ALL SELECT * FROM cognition.fn_detect_categorise_corrections()
  UNION ALL SELECT * FROM cognition.fn_detect_categorise_overbroad(90)
)
INSERT INTO cognition.proposals
  (task_id,detector,entity_ref,action_kind,action_payload,revert_payload,evidence,
   impact_gbp,confidence,category_source,predicted_effect,realm)
SELECT 'invoice.categorise', d.detector, d.entity_ref, d.action_kind, d.action_payload,
       d.revert_payload, d.evidence, d.impact_gbp, d.confidence, d.category_source,
       d.predicted_effect, d.realm
FROM det d
WHERE NOT EXISTS (                                   -- skip rejected signatures
        SELECT 1 FROM cognition.proposal_rejections r
        WHERE r.task_id='invoice.categorise'
          AND r.signature = md5(d.detector||':'||d.entity_ref||':'||d.action_kind))
  AND NOT EXISTS (                                   -- benchmark gate: don't suggest a category
        SELECT 1 FROM cognition.benchmark_labels b   -- that contradicts a frozen label
        WHERE b.task_id='invoice.categorise'
          AND b.key = d.entity_ref
          AND d.action_payload ? 'category'
          AND b.expected <> (d.action_payload->>'category'))
ON CONFLICT (task_id,detector,entity_ref,action_kind) DO UPDATE
  SET impact_gbp = EXCLUDED.impact_gbp,
      evidence   = EXCLUDED.evidence,
      predicted_effect = EXCLUDED.predicted_effect
  WHERE cognition.proposals.status = 'pending';     -- only refresh still-pending ones
SQL
echo "metis-detect: proposals refreshed"
