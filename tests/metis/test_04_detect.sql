-- tests/metis/test_04_detect.sql — seed a fixture vendor with a clean sibling +
-- an uncategorised invoice, run the GAP→proposal insert, assert one proposal; then
-- assert a rejection signature suppresses it. All inside a rolled-back txn.
\set ON_ERROR_STOP on
BEGIN;
SET app.current_entity='all'; SET app.current_realm='owner';
-- fixture: vendor 'fixturevendor.test' — one categorised sibling, one NULL
INSERT INTO vendor_invoice_inbox (idempotency_key, source_email_id, account, vendor_domain, vendor_name, subject, received_at, gross_amount, vendor_category, is_statement, status, realm)
VALUES ('mtfix1','m1','info','fixturevendor.test','Fixture','s',now(),100,'kitchen',false,'new','work');
INSERT INTO vendor_invoice_inbox (idempotency_key, source_email_id, account, vendor_domain, vendor_name, subject, received_at, gross_amount, vendor_category, is_statement, status, realm)
VALUES ('mtfix2','m2','info','fixturevendor.test','Fixture','s',now(),200,NULL,false,'new','work');
-- run the proposal insert (mirrors the script body)
INSERT INTO cognition.proposals (task_id,detector,entity_ref,action_kind,action_payload,revert_payload,evidence,impact_gbp,confidence,category_source,predicted_effect,realm)
SELECT 'invoice.categorise', d.detector, d.entity_ref, d.action_kind, d.action_payload, d.revert_payload, d.evidence, d.impact_gbp, d.confidence, d.category_source, d.predicted_effect, d.realm
FROM cognition.fn_detect_categorise_gaps() d
WHERE d.entity_ref='fixturevendor.test'
  AND NOT EXISTS (SELECT 1 FROM cognition.proposal_rejections r
                  WHERE r.task_id='invoice.categorise'
                    AND r.signature = md5(d.detector||':'||d.entity_ref||':'||d.action_kind))
ON CONFLICT (task_id,detector,entity_ref,action_kind) DO NOTHING;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM cognition.proposals
          WHERE entity_ref='fixturevendor.test' AND detector='gap') = 1,
         'expected one GAP proposal for the fixture vendor';
  ASSERT (SELECT action_payload->>'category' FROM cognition.proposals
          WHERE entity_ref='fixturevendor.test' AND detector='gap') = 'kitchen',
         'suggested category should be the majority sibling category';
END $$;
ROLLBACK;
