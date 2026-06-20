-- tests/metis/test_05_apply.sql — approve a rule_insert proposal, run the apply
-- logic, assert the rule exists and proposal is 'applied' with a revert_payload.
\set ON_ERROR_STOP on
BEGIN;
SET app.current_entity='all'; SET app.current_realm='owner';
INSERT INTO cognition.proposals (task_id,detector,entity_ref,action_kind,action_payload,evidence,impact_gbp,status,realm)
VALUES ('invoice.categorise','gap','applyfix.test','rule_insert',
        jsonb_build_object('domain_pattern','applyfix.test','category','kitchen','site','shared','priority',100,'realm','work'),
        '{}'::jsonb, 50, 'approved','work');
-- apply logic (mirrors the script)
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
   SET status='applied', applied_at=now(), decided_by=COALESCE(decided_by,'test'),
       revert_payload=jsonb_build_object('delete_rule_pattern', p.action_payload->>'domain_pattern',
                                         'site', COALESCE(p.action_payload->>'site','shared'))
 WHERE p.task_id='invoice.categorise' AND p.status='approved' AND p.action_kind='rule_insert';
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM vendor_category_rules WHERE domain_pattern='applyfix.test') = 1,
         'rule should be inserted';
  ASSERT (SELECT status FROM cognition.proposals WHERE entity_ref='applyfix.test') = 'applied',
         'proposal should be applied';
  ASSERT (SELECT revert_payload->>'delete_rule_pattern' FROM cognition.proposals WHERE entity_ref='applyfix.test') = 'applyfix.test',
         'revert payload should record the inverse';
END $$;
ROLLBACK;
