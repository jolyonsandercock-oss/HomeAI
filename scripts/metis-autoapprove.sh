# scripts/metis-autoapprove.sh — narrow provably-safe auto-approval, then apply.
# ENABLEMENT TOOL — run MANUALLY only after a clean shadow week (see metis-runbook.md
# precondition gate: >=7 nightly runs, 0 reverted). NOT wired into cron by design.
set -uo pipefail
source "$(dirname "$0")/metis/common.sh"
CEIL="${1:-250}"
metis_psql <<SQL
SET app.current_entity='all'; SET app.current_realm='owner';
UPDATE cognition.proposals p
   SET status='approved', decided_by='hermes-auto', decided_at=now()
 WHERE p.task_id='invoice.categorise' AND p.status='pending'
   AND p.detector='gap' AND p.category_source='deterministic'
   AND p.impact_gbp <= $CEIL
   AND EXISTS (SELECT 1 FROM cognition.benchmark_labels b
               WHERE b.task_id='invoice.categorise' AND b.key=p.entity_ref
                 AND b.expected = p.action_payload->>'category');
SQL
bash "$(dirname "$0")/metis-apply.sh"
echo "metis-autoapprove: safe class approved (ceil £$CEIL) + applied"
