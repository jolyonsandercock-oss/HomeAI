-- verify-resolve-counterparty.sql — P1b golden tests; psql exits non-zero on failure.
\set ON_ERROR_STOP on
DO $$
DECLARE d jsonb; cp_jrf bigint; a bigint; b bigint;
BEGIN
  SELECT id INTO cp_jrf FROM financial_counterparty WHERE domain='jrf.lls.com' LIMIT 1;
  IF cp_jrf IS NULL THEN RAISE EXCEPTION 'fixture: jrf.lls.com not seeded'; END IF;

  -- 1. domain-exact resolve
  d := home_ai.resolve_counterparty(jsonb_build_object('source_system','dext','email_domain','jrf.lls.com','raw_counterparty','J&R Foodservice'));
  IF d->>'decision'<>'resolve' OR (d->>'counterparty_id')::bigint<>cp_jrf OR d->>'stage'<>'domain_exact' THEN
    RAISE EXCEPTION 'domain-exact failed: %', d; END IF;

  -- 2. fake counterparty MUST abstain (never nearest-neighbour) — the core property
  d := home_ai.resolve_counterparty(jsonb_build_object('source_system','bank','raw_counterparty','zzzq nonexistent fake payee 99999'));
  IF d->>'decision'<>'abstain' THEN RAISE EXCEPTION 'fake counterparty did NOT abstain: %', d; END IF;

  -- 3. unknown domain abstains (no nearest-neighbour by domain)
  d := home_ai.resolve_counterparty(jsonb_build_object('source_system','dext','email_domain','no-such-domain-xyz.example'));
  IF d->>'decision'<>'abstain' THEN RAISE EXCEPTION 'unknown domain did NOT abstain: %', d; END IF;

  -- 4. strong identity anchor resolves; then a collision abstains
  SELECT id INTO b FROM financial_counterparty WHERE id<>cp_jrf ORDER BY id LIMIT 1;
  PERFORM home_ai.upsert_anchor('bank_reference','identity','__TESTRES_REF__','global','',cp_jrf,1,'work','manual','strong');
  d := home_ai.resolve_counterparty(jsonb_build_object('source_system','bank','bank_reference','__TESTRES_REF__'));
  IF d->>'decision'<>'resolve' OR (d->>'counterparty_id')::bigint<>cp_jrf OR d->>'stage'<>'strong_anchor' THEN
    RAISE EXCEPTION 'strong-anchor resolve failed: %', d; END IF;
  PERFORM home_ai.upsert_anchor('bank_reference','identity','__TESTRES_REF__','global','',b,1,'work','manual','strong'); -- collide
  d := home_ai.resolve_counterparty(jsonb_build_object('source_system','bank','bank_reference','__TESTRES_REF__'));
  IF d->>'decision'<>'abstain' OR d->>'reason'<>'anchor_collision' THEN
    RAISE EXCEPTION 'collided anchor did NOT abstain: %', d; END IF;

  -- 5. learned alias resolves
  INSERT INTO counterparty_resolution_log
    (source_system, source_account, raw_counterparty_normalized, anchor_fingerprint,
     counterparty_id, realm, confirmed_by, validation_status)
  VALUES ('bank','acc1','acme widgets','', cp_jrf, 'work', 'test', 'valid');
  d := home_ai.resolve_counterparty(jsonb_build_object('source_system','bank','source_account','acc1','raw_counterparty','ACME WIDGETS'));
  IF d->>'decision'<>'resolve' OR d->>'stage'<>'learned_alias' THEN
    RAISE EXCEPTION 'learned-alias resolve failed: %', d; END IF;

  -- 6. shadow wrapper records a decision
  PERFORM home_ai.resolve_shadow('test','__TESTRES_SHADOW__', jsonb_build_object('source_system','test','email_domain','jrf.lls.com'));
  IF NOT EXISTS (SELECT 1 FROM counterparty_resolution_shadow WHERE source_ref='__TESTRES_SHADOW__' AND decision='resolve') THEN
    RAISE EXCEPTION 'shadow wrapper did not record a decision'; END IF;

  -- cleanup all test rows
  DELETE FROM counterparty_anchor WHERE anchor_value_normalized='__TESTRES_REF__';
  DELETE FROM counterparty_resolution_review_queue WHERE source_ref LIKE 'anchor_collision:bank_reference:__TESTRES_REF__';
  DELETE FROM counterparty_resolution_log WHERE raw_counterparty_normalized='acme widgets' AND confirmed_by='test';
  DELETE FROM counterparty_resolution_shadow WHERE source_ref='__TESTRES_SHADOW__';
  RAISE NOTICE 'resolve_counterparty golden tests PASSED (domain-exact, fake→abstain, unknown→abstain, strong-anchor, collision→abstain, learned-alias, shadow)';
END $$;
