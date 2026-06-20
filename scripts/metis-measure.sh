#!/usr/bin/env bash
# scripts/metis-measure.sh — MEASURE stage: record effect of applied rules and
# auto-raise corrective proposals when an applied rule is implicated in a >£1k
# multi-category contradiction. Recursive close of the loop.
set -uo pipefail
source "$(dirname "$0")/metis/common.sh"
metis_psql <<'SQL'
SET app.current_entity='all'; SET app.current_realm='owner';
-- 1. record measured effect: how many invoices the applied domain now covers
UPDATE cognition.proposals p
   SET measured_effect = jsonb_build_object('now_covering',
         (SELECT count(*) FROM vendor_invoice_inbox v
          WHERE v.vendor_domain = p.entity_ref AND v.vendor_category IS NOT NULL))
 WHERE p.task_id='invoice.categorise' AND p.status='applied' AND p.measured_effect IS NULL;
-- 2. corrective: applied rule whose vendor now shows >£1k multi-category
INSERT INTO cognition.proposals
  (task_id,detector,entity_ref,action_kind,action_payload,evidence,impact_gbp,status,reverts_proposal_id,realm)
SELECT 'invoice.categorise','overbroad', p.entity_ref,'rule_narrow',
       jsonb_build_object('domain_pattern',p.entity_ref,'reason','applied rule caused >£1k multi-category'),
       '{}'::jsonb,
       (SELECT sum(COALESCE(v.gross_amount,0)) FROM vendor_invoice_inbox v WHERE v.vendor_domain=p.entity_ref),
       'pending', p.id,'work'
FROM cognition.proposals p
WHERE p.task_id='invoice.categorise' AND p.status='applied' AND p.action_kind='rule_insert'
  AND EXISTS (SELECT 1 FROM vendor_invoice_inbox v WHERE v.vendor_domain=p.entity_ref
              GROUP BY v.vendor_domain
              HAVING count(DISTINCT v.vendor_category) >= 2
                 AND sum(COALESCE(v.gross_amount,0)) > 1000)
ON CONFLICT (task_id,detector,entity_ref,action_kind) DO NOTHING;
SQL
echo "metis-measure: effects recorded, correctives raised"
