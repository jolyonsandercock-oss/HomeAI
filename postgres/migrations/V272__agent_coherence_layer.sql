-- V272: multi-agent coherence layer — Pillars 1(grants) + 3(findings log) + 4(work-claims).
-- Makes the Claude↔Hermes loop work WITHOUT human relay: both agents read live facts, write
-- findings/corrections to a shared append-only log, and claim shared resources before acting.
-- hermes_ro is SELECT-only, so writes go through SECURITY DEFINER functions it may EXECUTE.

-- ── Pillar 1 fix: hermes_ro couldn't CALL ops.live_state() — needs schema USAGE, not just EXECUTE.
GRANT USAGE ON SCHEMA ops TO hermes_ro;
GRANT EXECUTE ON FUNCTION ops.live_state() TO hermes_ro;

-- ── Pillar 3: shared, append-only decision/finding log (agent↔agent write-back).
CREATE TABLE IF NOT EXISTS cognition.agent_findings (
  id            bigserial PRIMARY KEY,
  agent         text NOT NULL CHECK (agent IN ('claude','hermes','human','gpt5')),
  kind          text NOT NULL CHECK (kind IN ('fact','decision','finding','correction','proposal')),
  subject       text NOT NULL,                       -- short tag, e.g. 'n8n-status'
  detail        text NOT NULL,
  verified      boolean NOT NULL DEFAULT false,       -- Pillar 2: measured vs [unverified]
  evidence      text,                                 -- the query/commit/source backing it
  supersedes_id bigint REFERENCES cognition.agent_findings(id),  -- corrections chain
  created_at    timestamptz NOT NULL DEFAULT now(),
  realm         text NOT NULL DEFAULT 'work'
);
CREATE INDEX IF NOT EXISTS idx_agent_findings_subject ON cognition.agent_findings(subject, created_at DESC);
CREATE OR REPLACE VIEW cognition.v_current_findings AS  -- latest non-superseded per subject
  SELECT f.* FROM cognition.agent_findings f
  WHERE NOT EXISTS (SELECT 1 FROM cognition.agent_findings s WHERE s.supersedes_id = f.id)
  ORDER BY f.created_at DESC;

CREATE OR REPLACE FUNCTION cognition.log_finding(
  p_agent text, p_kind text, p_subject text, p_detail text,
  p_verified boolean DEFAULT false, p_evidence text DEFAULT NULL, p_supersedes bigint DEFAULT NULL)
RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path = cognition, public AS $$
  INSERT INTO cognition.agent_findings(agent,kind,subject,detail,verified,evidence,supersedes_id)
  VALUES (p_agent,p_kind,left(p_subject,80),left(p_detail,2000),p_verified,left(p_evidence,500),p_supersedes)
  RETURNING id;
$$;
GRANT USAGE ON SCHEMA cognition TO hermes_ro;
GRANT SELECT ON cognition.agent_findings, cognition.v_current_findings TO hermes_ro, homeai_readonly;
GRANT EXECUTE ON FUNCTION cognition.log_finding(text,text,text,text,boolean,text,bigint) TO hermes_ro, homeai_pipeline;

-- ── Pillar 4: work-claims lock (deconflict shared resources: crontab, bank, extractor…).
CREATE TABLE IF NOT EXISTS ops.work_claims (
  id         bigserial PRIMARY KEY,
  agent      text NOT NULL,
  resource   text NOT NULL,                          -- e.g. 'crontab', 'bank_import', 'invoice-line-extract.py'
  intent     text,
  claimed_at timestamptz NOT NULL DEFAULT now(),
  released_at timestamptz,
  realm      text NOT NULL DEFAULT 'work'
);
CREATE UNIQUE INDEX IF NOT EXISTS work_claims_active ON ops.work_claims(resource) WHERE released_at IS NULL;

CREATE OR REPLACE FUNCTION ops.claim_work(p_agent text, p_resource text, p_intent text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, public AS $$
DECLARE holder text;
BEGIN
  UPDATE ops.work_claims SET released_at=now()                       -- auto-expire stale claims (2h)
    WHERE released_at IS NULL AND claimed_at < now() - interval '2 hours';
  SELECT agent INTO holder FROM ops.work_claims WHERE resource=p_resource AND released_at IS NULL;
  IF holder IS NOT NULL AND holder <> p_agent THEN
    RETURN jsonb_build_object('ok',false,'held_by',holder,'resource',p_resource);
  END IF;
  IF holder IS NULL THEN
    INSERT INTO ops.work_claims(agent,resource,intent) VALUES (p_agent,p_resource,p_intent);
  END IF;
  RETURN jsonb_build_object('ok',true,'resource',p_resource,'agent',p_agent);
EXCEPTION WHEN unique_violation THEN  -- race: someone claimed between the check and insert
  RETURN jsonb_build_object('ok',false,'held_by','(race)','resource',p_resource);
END $$;

CREATE OR REPLACE FUNCTION ops.release_work(p_agent text, p_resource text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = ops, public AS $$
  UPDATE ops.work_claims SET released_at=now()
  WHERE resource=p_resource AND released_at IS NULL AND agent=p_agent;
$$;
GRANT SELECT ON ops.work_claims TO hermes_ro, homeai_readonly;
GRANT EXECUTE ON FUNCTION ops.claim_work(text,text,text), ops.release_work(text,text) TO hermes_ro, homeai_pipeline;
