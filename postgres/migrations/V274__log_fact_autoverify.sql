-- V274: cognition.log_fact() — Pillar 2 enforcement for NUMERIC facts (Hermes' Item 1, built right).
-- Instead of self-attested verified=true, a numeric claim is checked against ops.live_state() at
-- write time: verified is SYSTEM-stamped, and evidence records claimed-vs-actual. If an agent claims
-- "extractable backlog = 11506" but live_state says 383, verified=false and the mismatch is recorded.
-- (Prose-parsing every number was rejected as brittle — it would false-reject legit findings like
--  'drink GP 53%'. Structured claim is the robust path.)
CREATE OR REPLACE FUNCTION cognition.log_fact(
  p_agent text, p_subject text, p_detail text,
  p_metric_path text,                 -- dot-path into ops.live_state(), e.g. 'invoices.lines_backlog_extractable'
  p_claimed numeric, p_tolerance numeric DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = cognition, ops, public AS $$
DECLARE actual numeric; ok boolean; fid bigint;
BEGIN
  BEGIN
    actual := (ops.live_state() #>> string_to_array(p_metric_path,'.'))::numeric;
  EXCEPTION WHEN others THEN actual := NULL; END;
  ok := actual IS NOT NULL AND abs(actual - p_claimed) <= p_tolerance;
  INSERT INTO cognition.agent_findings(agent,kind,subject,detail,verified,evidence)
  VALUES (p_agent,'fact',left(p_subject,80),left(p_detail,2000), ok,
          format('AUTO-VERIFY claimed=%s actual=%s path=%s tol=%s', p_claimed, COALESCE(actual::text,'(null)'), p_metric_path, p_tolerance))
  RETURNING id INTO fid;
  RETURN jsonb_build_object('id',fid,'verified',ok,'claimed',p_claimed,'actual',actual,'path',p_metric_path);
END $$;
GRANT EXECUTE ON FUNCTION cognition.log_fact(text,text,text,text,numeric,numeric) TO hermes_ro, homeai_pipeline, homeai_readonly;

-- Item 2+3: persist the operating rules in the log (so they survive compaction; re-derive from here).
INSERT INTO cognition.agent_findings(agent,kind,subject,detail,verified,evidence) VALUES
 ('claude','decision','operating-rule','Query ops.live_state() before quoting ANY system number. Raw count(*) lies — use the *_extractable / filtered fields, never the *_raw_DO_NOT_USE ones.',true,'session 2026-06-21'),
 ('claude','decision','operating-rule','Numeric facts: write via cognition.log_fact(agent,subject,detail,metric_path,claimed[,tol]) — it auto-verifies against live_state and SYSTEM-stamps verified. Self-attested verified=true on prose is weaker.',true,'V274'),
 ('claude','decision','operating-rule','Lead any analysis with [unverified] on every claim not cross-checked against live_state. Tag-untagged-by-default.',true,'Hermes item 3'),
 ('claude','decision','operating-rule','Truth-store split: persistent memory = immutable ENVIRONMENT facts (GPU/paths/prefs); the shared log = all operational decisions + rules. On compaction, re-derive rules from cognition.v_current_findings WHERE subject=''operating-rule''.',true,'Hermes item 2')
ON CONFLICT DO NOTHING;
