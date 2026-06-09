-- V256 — P2-backend (refactor plan 2026-06-09): review-workflow action logic.
-- The deterministic SQL behind confirm/merge/ignore (the visual review page is
-- the deferred UX layer that calls these). Each action is auditable + reversible.
-- Revert: DROP these functions.
BEGIN;

-- Confirm a review item -> write a CONTEXTUAL learned alias (keyed on evidence
-- fingerprint, with registry fingerprint for revalidation), optionally promote a
-- strong identity anchor so identical future records auto-resolve, close the item.
CREATE OR REPLACE FUNCTION home_ai.confirm_resolution(
  p_review_id bigint, p_counterparty_id bigint, p_confirmed_by text, p_promote_anchor boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public
AS $fn$
DECLARE rq counterparty_resolution_review_queue%ROWTYPE; ev jsonb;
        v_raw text; v_fp text; v_domain text; v_acct text; v_promoted text := 'none';
BEGIN
  SELECT * INTO rq FROM counterparty_resolution_review_queue WHERE id=p_review_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'review item % not found', p_review_id; END IF;
  IF NOT EXISTS (SELECT 1 FROM financial_counterparty WHERE id=p_counterparty_id AND status='active') THEN
    RAISE EXCEPTION 'counterparty % not active', p_counterparty_id; END IF;
  ev := rq.evidence_json;
  v_raw := nullif(lower(btrim(coalesce(ev->>'raw_counterparty',''))),'');
  v_domain := nullif(lower(btrim(coalesce(ev->>'email_domain',''))),'');
  v_acct := coalesce(ev->>'source_account','');
  v_fp := (SELECT coalesce(string_agg(t||':'||v,'|' ORDER BY t||':'||v),'') FROM (VALUES
            ('email_domain',v_domain),
            ('invoice_account_code', nullif(upper(btrim(coalesce(ev->>'invoice_account_code',''))),'')),
            ('bank_reference', nullif(coalesce(ev->>'bank_reference',''),'')),
            ('vat_number', nullif(coalesce(ev->>'vat_number',''),''))
          ) a(t,v) WHERE v IS NOT NULL);

  INSERT INTO counterparty_resolution_log
    (source_system, source_account, raw_counterparty_normalized, anchor_fingerprint,
     counterparty_id, entity_id, realm, confirmed_by, validation_status, evidence_json, registry_fingerprint)
  VALUES (rq.source_system, v_acct, coalesce(v_raw,''), v_fp,
          p_counterparty_id, rq.entity_id, rq.realm, p_confirmed_by, 'valid', ev,
          home_ai.fc_fingerprint(p_counterparty_id))
  ON CONFLICT (source_system, source_account, raw_counterparty_normalized, anchor_fingerprint)
    WHERE validation_status='valid'
  DO UPDATE SET counterparty_id=EXCLUDED.counterparty_id, evidence_json=EXCLUDED.evidence_json,
                registry_fingerprint=EXCLUDED.registry_fingerprint, confirmed_by=EXCLUDED.confirmed_by,
                confirmed_at=now(), updated_at=now();

  IF p_promote_anchor AND v_domain IS NOT NULL THEN
    PERFORM home_ai.upsert_anchor('email_domain','identity',v_domain,'global','',
              p_counterparty_id, rq.entity_id, rq.realm, rq.source_system, 'strong');
    v_promoted := 'email_domain:'||v_domain;
  END IF;

  UPDATE counterparty_resolution_review_queue
     SET status='resolved', resolved_by=p_confirmed_by, resolved_at=now(),
         resolution_counterparty_id=p_counterparty_id, decision='confirm'
   WHERE id=p_review_id;

  INSERT INTO audit_log (pipeline, action, result, ai_parsed)
  VALUES ('counterparty_resolver','confirm','success',
          jsonb_build_object('review_id',p_review_id,'counterparty_id',p_counterparty_id,
                             'by',p_confirmed_by,'anchor_promoted',v_promoted));
  RETURN jsonb_build_object('confirmed',p_review_id,'counterparty_id',p_counterparty_id,'anchor_promoted',v_promoted);
END $fn$;

-- Merge one identity into another: mark merged + record history + bump versions +
-- disable the merged-away anchors. Aliases on the merged id are caught as
-- target_changed by the next revalidation pass (re-review, not auto-redirect).
CREATE OR REPLACE FUNCTION home_ai.merge_counterparty(
  p_from bigint, p_into bigint, p_by text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public
AS $fn$
BEGIN
  IF p_from = p_into THEN RAISE EXCEPTION 'cannot merge a counterparty into itself'; END IF;
  UPDATE financial_counterparty SET status='merged', merged_into=p_into, updated_at=now() WHERE id=p_from;
  INSERT INTO counterparty_merge_history (from_id, into_id, merged_by, reason) VALUES (p_from,p_into,p_by,p_reason);
  PERFORM home_ai.fc_touch_version(p_from,'merge');
  PERFORM home_ai.fc_touch_version(p_into,'merge');
  UPDATE counterparty_anchor SET status='disabled', updated_at=now() WHERE counterparty_id=p_from AND status='active';
  INSERT INTO audit_log (pipeline, action, result, ai_parsed)
  VALUES ('counterparty_resolver','merge','success',
          jsonb_build_object('from',p_from,'into',p_into,'by',p_by,'reason',p_reason));
  RETURN jsonb_build_object('merged',p_from,'into',p_into);
END $fn$;

-- Close a review item without confirming (non-financial / not actionable).
CREATE OR REPLACE FUNCTION home_ai.ignore_review(p_review_id bigint, p_by text, p_decision text DEFAULT 'ignored')
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public
AS $fn$
BEGIN
  UPDATE counterparty_resolution_review_queue
     SET status='ignored', resolved_by=p_by, resolved_at=now(), decision=p_decision
   WHERE id=p_review_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'review item % not found', p_review_id; END IF;
  RETURN jsonb_build_object('ignored',p_review_id);
END $fn$;

GRANT EXECUTE ON FUNCTION home_ai.confirm_resolution(bigint,bigint,text,boolean) TO homeai_pipeline;
GRANT EXECUTE ON FUNCTION home_ai.merge_counterparty(bigint,bigint,text,text) TO homeai_pipeline;
GRANT EXECUTE ON FUNCTION home_ai.ignore_review(bigint,text,text) TO homeai_pipeline;

COMMIT;
