-- V253 — P1b (refactor plan 2026-06-09): home_ai.resolve_counterparty() + a
-- shadow-mode wrapper. Deterministic, no LLM. SECURITY INVOKER — runs under the
-- caller's RLS; the caller sets trusted entity/realm context from the SOURCE ROW.
-- evidence.entity_id/realm are HINTS only, never used to widen access (review #4).
-- Shadow mode writes decisions to counterparty_resolution_shadow; no attribution.
BEGIN;

-- Gate thresholds live in static_context so they tune without a deploy (plan §14.4).
INSERT INTO static_context (key, value) VALUES
  ('resolver.trgm_min', '0.45'::jsonb),
  ('resolver.trgm_margin', '0.12'::jsonb)
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION home_ai.resolve_counterparty(p_evidence jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = pg_catalog, public
AS $fn$
DECLARE
  v_raw   text := nullif(lower(btrim(coalesce(p_evidence->>'raw_counterparty',''))), '');
  v_domain text := nullif(lower(btrim(coalesce(p_evidence->>'email_domain',''))), '');
  v_src   text := coalesce(p_evidence->>'source_system','');
  v_acct  text := coalesce(p_evidence->>'source_account','');
  v_ent   text := coalesce(p_evidence->>'entity_hint', p_evidence->>'entity_id', '');
  v_realm text := coalesce(p_evidence->>'realm','');
  v_fp    text;
  v_cp bigint; v_n int; v_collided int;
  v_trgm_min real := coalesce((SELECT value FROM static_context WHERE key='resolver.trgm_min')::text::real, 0.45);
  v_margin   real := coalesce((SELECT value FROM static_context WHERE key='resolver.trgm_margin')::text::real, 0.12);
  v_s1 real; v_s2 real; v_ent_cp int;
BEGIN
  -- anchor fingerprint of the present strong anchors (for alias matching)
  v_fp := (SELECT coalesce(string_agg(t||':'||v,'|' ORDER BY t||':'||v),'')
           FROM (VALUES ('email_domain',v_domain),
                        ('invoice_account_code', nullif(upper(btrim(coalesce(p_evidence->>'invoice_account_code',''))),'')),
                        ('bank_reference', nullif(coalesce(p_evidence->>'bank_reference',''),'')),
                        ('vat_number', nullif(coalesce(p_evidence->>'vat_number',''),''))
                ) a(t,v) WHERE v IS NOT NULL);

  -- ── STAGE 1: strong identity anchors (collision-aware, most-specific scope) ──
  -- disqualify if any matching identity anchor is collided
  SELECT count(*) INTO v_collided FROM counterparty_anchor ca
   WHERE ca.anchor_role='identity' AND ca.status='collided'
     AND ( (ca.anchor_type='email_domain'        AND ca.anchor_value_normalized=v_domain)
        OR (ca.anchor_type='invoice_account_code'AND ca.anchor_value_normalized=upper(btrim(coalesce(p_evidence->>'invoice_account_code',''))))
        OR (ca.anchor_type='bank_reference'      AND ca.anchor_value_normalized=coalesce(p_evidence->>'bank_reference',''))
        OR (ca.anchor_type='vat_number'          AND ca.anchor_value_normalized=coalesce(p_evidence->>'vat_number','')) );
  IF v_collided > 0 THEN
    RETURN jsonb_build_object('decision','abstain','reason','anchor_collision');
  END IF;

  WITH present AS (
    SELECT * FROM (VALUES
      ('email_domain', v_domain),
      ('invoice_account_code', nullif(upper(btrim(coalesce(p_evidence->>'invoice_account_code',''))),'')),
      ('bank_reference', nullif(coalesce(p_evidence->>'bank_reference',''),'')),
      ('vat_number', nullif(coalesce(p_evidence->>'vat_number',''),''))
    ) a(atype, aval) WHERE aval IS NOT NULL
  ), m AS (
    SELECT DISTINCT ca.counterparty_id
    FROM counterparty_anchor ca JOIN present p
      ON ca.anchor_type=p.atype AND ca.anchor_value_normalized=p.aval
    WHERE ca.anchor_role='identity' AND ca.status='active'
      AND ( ca.scope_type='global'
         OR (ca.scope_type='source_account' AND ca.scope_value=v_acct)
         OR (ca.scope_type='entity' AND ca.scope_value=v_ent)
         OR (ca.scope_type='realm'  AND ca.scope_value=v_realm) )
  )
  SELECT count(*), min(counterparty_id) INTO v_n, v_cp FROM m;
  IF v_n = 1 THEN
    RETURN jsonb_build_object('decision','resolve','counterparty_id',v_cp,
                              'stage','strong_anchor','confidence',1.0);
  ELSIF v_n > 1 THEN
    RETURN jsonb_build_object('decision','abstain','reason','anchor_ambiguous');
  END IF;

  -- ── STAGE 2: contextual learned alias (valid only) ──
  SELECT counterparty_id INTO v_cp FROM counterparty_resolution_log
   WHERE source_system=v_src AND source_account=v_acct
     AND raw_counterparty_normalized=coalesce(v_raw,'') AND anchor_fingerprint=v_fp
     AND validation_status='valid' LIMIT 1;
  IF v_cp IS NOT NULL THEN
    RETURN jsonb_build_object('decision','resolve','counterparty_id',v_cp,
                              'stage','learned_alias','confidence',0.99);
  END IF;

  -- ── STAGE 3: domain-exact (grain B workhorse) ──
  IF v_domain IS NOT NULL THEN
    SELECT count(*), min(id) INTO v_n, v_cp
      FROM financial_counterparty WHERE status='active' AND domain=v_domain;
    IF v_n = 1 THEN
      RETURN jsonb_build_object('decision','resolve','counterparty_id',v_cp,
                                'stage','domain_exact','confidence',0.95);
    END IF;
  END IF;

  -- ── STAGE 4: trigram fallback on display_name (scored, gated, no cross-entity) ──
  IF v_raw IS NOT NULL THEN
    SELECT fc.id, similarity(lower(fc.display_name), v_raw) AS s, fc.default_entity_id
      INTO v_cp, v_s1, v_ent_cp
      FROM financial_counterparty fc WHERE fc.status='active'
      ORDER BY similarity(lower(fc.display_name), v_raw) DESC NULLS LAST LIMIT 1;
    SELECT max(s) INTO v_s2 FROM (
      SELECT similarity(lower(fc.display_name), v_raw) AS s
        FROM financial_counterparty fc WHERE fc.status='active' AND fc.id<>v_cp
        ORDER BY 1 DESC LIMIT 1) t;
    IF v_cp IS NOT NULL AND v_s1 >= v_trgm_min AND (v_s1 - coalesce(v_s2,0)) >= v_margin THEN
      -- asymmetric guard: lexical-only must NOT cross entity boundaries (review #7/§7)
      IF v_ent <> '' AND v_ent_cp IS NOT NULL AND v_ent_cp::text <> v_ent THEN
        RETURN jsonb_build_object('decision','abstain','reason','cross_entity_ambiguity',
                 'top_candidates', jsonb_build_array(jsonb_build_object('counterparty_id',v_cp,'score',v_s1)));
      END IF;
      RETURN jsonb_build_object('decision','resolve','counterparty_id',v_cp,
               'stage','trigram','confidence',round(v_s1::numeric,3));
    ELSIF v_cp IS NOT NULL THEN
      RETURN jsonb_build_object('decision','abstain','reason',
               CASE WHEN v_s1 < v_trgm_min THEN 'fuzzy_only_low_sim' ELSE 'low_margin' END,
               'top_candidates', jsonb_build_array(
                 jsonb_build_object('counterparty_id',v_cp,'score',round(v_s1::numeric,3))));
    END IF;
  END IF;

  RETURN jsonb_build_object('decision','abstain','reason','no_anchor');
END;
$fn$;

-- Shadow-mode wrapper: record what the resolver WOULD do; write no attribution.
-- (review #5 modes: shadow = metrics only. enforce-mode attribution lands in P5
--  once the source tables carry counterparty_id columns.)
CREATE OR REPLACE FUNCTION home_ai.resolve_shadow(
  p_source_system text, p_source_ref text, p_evidence jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $fn$
DECLARE d jsonb;
BEGIN
  d := home_ai.resolve_counterparty(p_evidence);
  INSERT INTO counterparty_resolution_shadow
    (source_system, source_ref, decision, counterparty_id, confidence, stage, abstain_reason, evidence_json)
  VALUES (p_source_system, p_source_ref, d->>'decision',
          (d->>'counterparty_id')::bigint, (d->>'confidence')::real,
          d->>'stage', d->>'reason', p_evidence);
  RETURN d;
END;
$fn$;

GRANT EXECUTE ON FUNCTION home_ai.resolve_counterparty(jsonb) TO homeai_pipeline, homeai_readonly;
GRANT EXECUTE ON FUNCTION home_ai.resolve_shadow(text,text,jsonb) TO homeai_pipeline;

COMMIT;
