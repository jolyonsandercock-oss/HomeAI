-- postgres/migrations/V268__metis_cognition_loop.sql
-- Metis self-improvement loop spine (design: docs/superpowers/specs/2026-06-20-metis-...).
-- Additive. Task-agnostic. Detectors are deterministic SQL (no LLM).
SET search_path = cognition, public;

CREATE TABLE IF NOT EXISTS cognition.task_runs (
  id          bigserial PRIMARY KEY,
  task_id     text NOT NULL,
  run_at      timestamptz NOT NULL DEFAULT now(),
  metrics     jsonb NOT NULL DEFAULT '{}'::jsonb,
  duration_ms integer,
  realm       text NOT NULL DEFAULT 'work'
              CHECK (realm IN ('owner','work','personal','shared'))
);
CREATE INDEX IF NOT EXISTS idx_task_runs_task_time ON cognition.task_runs(task_id, run_at DESC);

CREATE TABLE IF NOT EXISTS cognition.proposals (
  id                  bigserial PRIMARY KEY,
  task_id             text NOT NULL,
  detector            text NOT NULL,
  entity_ref          text NOT NULL,
  action_kind         text NOT NULL
                      CHECK (action_kind IN ('rule_insert','rule_narrow','rule_retire','noise_add','threshold_change')),
  action_payload      jsonb NOT NULL,
  revert_payload      jsonb,
  evidence            jsonb NOT NULL DEFAULT '{}'::jsonb,
  impact_gbp          numeric(12,2) NOT NULL DEFAULT 0,
  confidence          numeric(4,3),
  category_source     text NOT NULL DEFAULT 'deterministic'
                      CHECK (category_source IN ('deterministic','llm_suggested')),
  predicted_effect    jsonb,
  measured_effect     jsonb,
  status              text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','approved','rejected','applied','reverted','auto_approved')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  decided_by          text,
  decided_at          timestamptz,
  applied_at          timestamptz,
  reverts_proposal_id bigint REFERENCES cognition.proposals(id),
  realm               text NOT NULL DEFAULT 'work'
                      CHECK (realm IN ('owner','work','personal','shared')),
  UNIQUE (task_id, detector, entity_ref, action_kind)
);
CREATE INDEX IF NOT EXISTS idx_proposals_pending ON cognition.proposals(task_id, status, impact_gbp DESC)
  WHERE status='pending';

CREATE TABLE IF NOT EXISTS cognition.proposal_rejections (
  id          bigserial PRIMARY KEY,
  task_id     text NOT NULL,
  signature   text NOT NULL,
  reason      text,
  rejected_by text NOT NULL DEFAULT 'jo',
  rejected_at timestamptz NOT NULL DEFAULT now(),
  realm       text NOT NULL DEFAULT 'work'
              CHECK (realm IN ('owner','work','personal','shared')),
  UNIQUE (task_id, signature)
);

CREATE TABLE IF NOT EXISTS cognition.benchmark_labels (
  task_id   text NOT NULL,
  key       text NOT NULL,
  expected  text NOT NULL,
  added_by  text NOT NULL DEFAULT 'jo',
  added_at  timestamptz NOT NULL DEFAULT now(),
  realm     text NOT NULL DEFAULT 'work'
            CHECK (realm IN ('owner','work','personal','shared')),
  PRIMARY KEY (task_id, key)
);

-- composite return type for detectors
DO $$ BEGIN
  CREATE TYPE cognition.detection AS (
    detector text, entity_ref text, action_kind text,
    action_payload jsonb, revert_payload jsonb, evidence jsonb,
    impact_gbp numeric, confidence numeric, category_source text,
    predicted_effect jsonb, realm text);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- RLS (default-deny realm pattern; copy of counterparty_anchor block)
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['task_runs','proposals','proposal_rejections','benchmark_labels'] LOOP
    EXECUTE format('ALTER TABLE cognition.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS realm_isolation ON cognition.%I', t);
    EXECUTE format($f$
      CREATE POLICY realm_isolation ON cognition.%I USING (
        CASE current_setting('app.current_realm', true)
          WHEN 'owner' THEN true
          WHEN 'work' THEN realm = ANY (ARRAY['work','shared'])
          WHEN 'personal' THEN realm = ANY (ARRAY['personal','shared'])
          ELSE (current_setting('app.current_realm', true) IS NULL
                OR current_setting('app.current_realm', true) = '')
        END)$f$, t);
    EXECUTE format('GRANT SELECT ON cognition.%I TO homeai_readonly', t);
  END LOOP;
END $$;

-- ── Detectors (deterministic). All return cognition.detection rows. ──
-- GAP: uncategorised invoices grouped by vendor_domain, ranked Σnet; suggested
-- category = majority category of that vendor's already-categorised siblings.
CREATE OR REPLACE FUNCTION cognition.fn_detect_categorise_gaps()
RETURNS SETOF cognition.detection LANGUAGE sql STABLE AS $$
  WITH uncat AS (
    SELECT vendor_domain,
           sum(COALESCE(net_amount, gross_amount, 0)) AS impact,
           count(*) AS n,
           array_agg(id ORDER BY id) AS sample_ids
    FROM vendor_invoice_inbox
    WHERE category_canonical IS NULL AND is_statement = false
      AND status NOT IN ('duplicate','ignored')
    GROUP BY vendor_domain
  ),
  majority AS (
    SELECT vendor_domain, vendor_category AS cat,
           row_number() OVER (PARTITION BY vendor_domain
                              ORDER BY count(*) DESC) AS rn
    FROM vendor_invoice_inbox
    WHERE vendor_category IS NOT NULL AND is_statement = false
    GROUP BY vendor_domain, vendor_category
  )
  SELECT 'gap', u.vendor_domain, 'rule_insert',
         jsonb_build_object('domain_pattern', u.vendor_domain, 'category', m.cat,
                            'site','shared','priority',100,'realm','work'),
         NULL::jsonb,
         jsonb_build_object('n_invoices', u.n, 'sample_ids', to_jsonb(u.sample_ids[1:5])),
         u.impact, 0.85, 'deterministic',
         jsonb_build_object('will_categorise', u.n, 'gbp', u.impact),
         'work'
  FROM uncat u JOIN majority m ON m.vendor_domain = u.vendor_domain AND m.rn = 1
  WHERE m.cat IS NOT NULL;
$$;

-- CONTRADICTION: one vendor_domain mapped to >=2 categories.
CREATE OR REPLACE FUNCTION cognition.fn_detect_categorise_contradictions()
RETURNS SETOF cognition.detection LANGUAGE sql STABLE AS $$
  WITH multi AS (
    SELECT vendor_domain,
           count(DISTINCT vendor_category) AS ncat,
           jsonb_agg(DISTINCT vendor_category) AS cats,
           sum(COALESCE(net_amount, gross_amount, 0)) AS impact
    FROM vendor_invoice_inbox
    WHERE vendor_category IS NOT NULL AND is_statement = false
      AND status NOT IN ('duplicate','ignored')
    GROUP BY vendor_domain
    HAVING count(DISTINCT vendor_category) >= 2
  )
  SELECT 'contradiction', vendor_domain, 'rule_narrow',
         jsonb_build_object('domain_pattern', vendor_domain, 'reason','multi-category; needs site split or rule fix'),
         NULL::jsonb,
         jsonb_build_object('categories', cats),
         impact, 0.70, 'deterministic',
         jsonb_build_object('categories_seen', cats),
         'work'
  FROM multi;
$$;

-- CORRECTION: a human re-categorisation in invoice_feedback that hasn't yet
-- produced a proposal. (ai_proposal lifecycle: pending = applied_at & rejected_at NULL.)
CREATE OR REPLACE FUNCTION cognition.fn_detect_categorise_corrections()
RETURNS SETOF cognition.detection LANGUAGE sql STABLE AS $$
  SELECT 'correction', v.vendor_domain, 'rule_insert',
         jsonb_build_object('domain_pattern', v.vendor_domain, 'from_feedback_id', f.id,
                            'feedback_text', f.feedback_text),
         NULL::jsonb,
         jsonb_build_object('invoice_id', f.invoice_id, 'feedback_id', f.id),
         COALESCE(v.net_amount, v.gross_amount, 0), 0.90, 'deterministic',
         jsonb_build_object('source','human_correction'),
         'work'
  FROM invoice_feedback f
  JOIN vendor_invoice_inbox v ON v.id = f.invoice_id
  WHERE f.applied_at IS NULL AND f.rejected_at IS NULL;
$$;

-- OVER-BROAD / DEAD: rules that never matched anything in p_dead_days days.
CREATE OR REPLACE FUNCTION cognition.fn_detect_categorise_overbroad(p_dead_days int DEFAULT 90)
RETURNS SETOF cognition.detection LANGUAGE sql STABLE AS $$
  SELECT 'dead', r.domain_pattern, 'rule_retire',
         jsonb_build_object('rule_id', r.id, 'domain_pattern', r.domain_pattern, 'category', r.category),
         jsonb_build_object('restore', to_jsonb(r)),         -- revert = re-insert the row
         jsonb_build_object('created_at', r.created_at),
         0, 0.60, 'deterministic',
         jsonb_build_object('dead_days', p_dead_days),
         r.realm
  FROM vendor_category_rules r
  WHERE NOT EXISTS (
    SELECT 1 FROM vendor_invoice_inbox v
    WHERE (v.vendor_domain ~* r.domain_pattern OR v.vendor_name ~* r.domain_pattern)
      AND v.ingested_at > now() - make_interval(days => p_dead_days)
  );
$$;

CREATE OR REPLACE VIEW cognition.v_proposal_queue AS
  SELECT id, task_id, detector, entity_ref, action_kind, impact_gbp, confidence,
         category_source, predicted_effect, evidence, created_at
  FROM cognition.proposals
  WHERE status = 'pending'
  ORDER BY impact_gbp DESC, created_at;
