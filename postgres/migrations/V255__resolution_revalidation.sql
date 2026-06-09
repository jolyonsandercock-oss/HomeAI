-- V255 — P4 (refactor plan 2026-06-09): learned-alias revalidation lifecycle.
-- Background SQL only (no UX). Keeps confirmed aliases from rotting: re-checks
-- each valid alias against the current registry + resolver and flags those that
-- no longer hold (target merged/renamed, anchor collided, resolver disagrees),
-- emitting review items. NEVER silently re-points. Revert: DROP these functions.
BEGIN;

-- identity fingerprint of a financial_counterparty (changes on rename/merge/disable)
CREATE OR REPLACE FUNCTION home_ai.fc_fingerprint(p_id bigint)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT md5(coalesce(display_name,'')||'|'||coalesce(domain,'')||'|'||status||'|'||coalesce(merged_into::text,''))
  FROM financial_counterparty WHERE id = p_id;
$$;

-- bump a registry version row (call from merge/rename/disable flows in P2/P5)
CREATE OR REPLACE FUNCTION home_ai.fc_touch_version(p_id bigint, p_kind text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v int;
BEGIN
  SELECT coalesce(max(version),0)+1 INTO v FROM counterparty_registry_version WHERE counterparty_id=p_id;
  INSERT INTO counterparty_registry_version (counterparty_id, version, identity_fingerprint, change_kind)
  VALUES (p_id, v, home_ai.fc_fingerprint(p_id), p_kind);
END $$;

-- the revalidation pass. Run as a privileged role (cron) so it sees all aliases.
-- p_max_review caps review emissions per run (anti-flood, mirrors u241 breaker).
CREATE OR REPLACE FUNCTION home_ai.revalidate_resolution_log(p_max_review int DEFAULT 200)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public
AS $fn$
DECLARE
  r record; d jsonb; new_status text; cur_fp text; tgt_status text;
  n_valid int:=0; n_collided int:=0; n_review_flag int:=0; emitted int:=0;
BEGIN
  FOR r IN SELECT * FROM counterparty_resolution_log WHERE validation_status='valid' LOOP
    cur_fp := home_ai.fc_fingerprint(r.counterparty_id);
    SELECT status INTO tgt_status FROM financial_counterparty WHERE id=r.counterparty_id;

    IF tgt_status IS NULL OR tgt_status IN ('merged','disabled') THEN
      new_status := 'target_changed';
    ELSIF r.registry_fingerprint IS NOT NULL AND r.registry_fingerprint <> cur_fp THEN
      new_status := 'target_changed';
    ELSE
      d := home_ai.resolve_counterparty(r.evidence_json);
      IF d->>'decision'='abstain' AND d->>'reason'='anchor_collision' THEN
        new_status := 'collided';
      ELSIF d->>'decision'='resolve' AND (d->>'counterparty_id')::bigint = r.counterparty_id THEN
        -- still holds: refresh validated_at, backfill fingerprint if it was missing
        UPDATE counterparty_resolution_log
           SET validated_at=now(), validated_by='revalidate_job',
               registry_fingerprint=coalesce(registry_fingerprint,cur_fp), updated_at=now()
         WHERE id=r.id;
        n_valid := n_valid+1; CONTINUE;
      ELSE
        -- resolver now points elsewhere, or no longer confident: never silently re-point
        new_status := 'needs_re_review';
      END IF;
    END IF;

    UPDATE counterparty_resolution_log
       SET validation_status=new_status, validated_at=now(), validated_by='revalidate_job', updated_at=now()
     WHERE id=r.id;
    IF new_status='collided' THEN n_collided:=n_collided+1; ELSE n_review_flag:=n_review_flag+1; END IF;

    IF emitted < p_max_review THEN
      INSERT INTO counterparty_resolution_review_queue
        (status,source_system,source_ref,entity_id,realm,evidence_json,abstain_reason,top_candidates,suggested_action)
      VALUES ('open',r.source_system,'revalidate:log:'||r.id,r.entity_id,r.realm,r.evidence_json,
              'alias_'||new_status,
              jsonb_build_array(jsonb_build_object('counterparty_id',r.counterparty_id,'why','prior confirmed target')),
              'confirm_existing')
      ON CONFLICT (source_system,source_ref) WHERE status='open' DO NOTHING;
      emitted := emitted+1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('still_valid',n_valid,'collided',n_collided,
                            'flagged_for_review',n_review_flag,'review_items_emitted',emitted);
END $fn$;

GRANT EXECUTE ON FUNCTION home_ai.fc_fingerprint(bigint) TO homeai_pipeline, homeai_readonly;
GRANT EXECUTE ON FUNCTION home_ai.fc_touch_version(bigint,text) TO homeai_pipeline;
GRANT EXECUTE ON FUNCTION home_ai.revalidate_resolution_log(int) TO homeai_pipeline;

COMMIT;
