#!/usr/bin/env bash
# scripts/metis-apply.sh — enact human-APPROVED proposals only. Shadow-safe:
# does nothing to 'pending'. rule_insert is auto-enacted; narrow/retire are flagged
# for manual SQL in the shadow phase (logged, status left 'approved').
set -euo pipefail
source "$(dirname "$0")/metis/common.sh"
metis_psql <<'SQL'
SET app.current_entity='all'; SET app.current_realm='owner';
WITH appr AS (
  SELECT * FROM cognition.proposals
  WHERE task_id='invoice.categorise' AND status='approved' AND action_kind='rule_insert'
), ins AS (
  INSERT INTO vendor_category_rules (domain_pattern, category, site, priority, realm, vendor_display, notes)
  SELECT a.action_payload->>'domain_pattern', a.action_payload->>'category',
         COALESCE(a.action_payload->>'site','shared'), COALESCE((a.action_payload->>'priority')::int,100),
         COALESCE(a.action_payload->>'realm','work'), a.entity_ref, 'metis proposal #'||a.id
  FROM appr a
  ON CONFLICT (domain_pattern, site) DO NOTHING
  RETURNING domain_pattern
)
UPDATE cognition.proposals p
   SET status='applied', applied_at=now(),
       revert_payload=jsonb_build_object('delete_rule_pattern', p.action_payload->>'domain_pattern',
                                         'site', COALESCE(p.action_payload->>'site','shared'))
 WHERE p.task_id='invoice.categorise' AND p.status='approved' AND p.action_kind='rule_insert';
\echo 'Approved narrow/retire proposals needing manual enactment:'
SELECT id, action_kind, entity_ref FROM cognition.proposals
 WHERE task_id='invoice.categorise' AND status='approved' AND action_kind IN ('rule_narrow','rule_retire');
SQL
echo "metis-apply: applied approved rule_insert proposals"
