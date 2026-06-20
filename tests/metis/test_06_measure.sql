-- tests/metis/test_06_measure.sql — an applied proposal whose vendor now shows a
-- >£1k multi-category contradiction must spawn a corrective proposal.
\set ON_ERROR_STOP on
BEGIN;
SET app.current_entity='all'; SET app.current_realm='owner';
INSERT INTO cognition.proposals (id,task_id,detector,entity_ref,action_kind,action_payload,status,applied_at,impact_gbp,realm)
VALUES (900001,'invoice.categorise','gap','measfix.test','rule_insert',
        jsonb_build_object('domain_pattern','measfix.test','category','kitchen'),'applied',now(),1500,'work');
-- two categories, >£1k → contradiction signal
INSERT INTO vendor_invoice_inbox (idempotency_key,source_email_id,account,vendor_domain,vendor_name,subject,received_at,gross_amount,vendor_category,is_statement,status,realm)
VALUES ('measf1','mf1','info','measfix.test','MF','s',now(),900,'kitchen',false,'new','work'),
       ('measf2','mf2','info','measfix.test','MF','s',now(),900,'bar',false,'new','work');
-- corrective insert (mirrors script)
INSERT INTO cognition.proposals (task_id,detector,entity_ref,action_kind,action_payload,evidence,impact_gbp,status,reverts_proposal_id,realm)
SELECT 'invoice.categorise','overbroad', p.entity_ref,'rule_narrow',
       jsonb_build_object('domain_pattern',p.entity_ref,'reason','applied rule caused >£1k multi-category'),
       '{}'::jsonb, 1800,'pending', p.id,'work'
FROM cognition.proposals p
WHERE p.status='applied' AND p.id=900001
  AND EXISTS (SELECT 1 FROM vendor_invoice_inbox v WHERE v.vendor_domain=p.entity_ref
              GROUP BY v.vendor_domain
              HAVING count(DISTINCT v.vendor_category) >= 2
                 AND sum(COALESCE(v.gross_amount,0)) > 1000)
ON CONFLICT (task_id,detector,entity_ref,action_kind) DO NOTHING;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM cognition.proposals
          WHERE entity_ref='measfix.test' AND action_kind='rule_narrow' AND reverts_proposal_id=900001) = 1,
         'a corrective rule_narrow proposal should be raised';
END $$;
ROLLBACK;
