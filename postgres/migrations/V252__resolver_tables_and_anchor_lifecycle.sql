-- V252 — P1a (refactor plan 2026-06-09): resolver tables + anchor collision
-- lifecycle. Additive; DEFAULT-DENY RLS on realm-bearing tables. No resolver
-- function yet (that is V253/P1b). Targets financial_counterparty(id) (V251).
BEGIN;

-- ── 1. counterparty_anchor — scoped anchors, classified by role ────────────────
CREATE TABLE IF NOT EXISTS counterparty_anchor (
  id                bigserial PRIMARY KEY,
  anchor_type       text NOT NULL CHECK (anchor_type IN
                      ('email_domain','invoice_account_code','bank_account_id','bank_reference',
                       'sort_code','iban','vendor_domain_regex','subject_token','vat_number')),
  anchor_role       text NOT NULL CHECK (anchor_role IN ('identity','routing','category')),
  anchor_value_normalized text NOT NULL,
  scope_type        text NOT NULL CHECK (scope_type IN ('global','source_system','source_account','entity','realm')),
  scope_value       text NOT NULL DEFAULT '',          -- '' for global; never NULL (NULL-safe uniqueness)
  counterparty_id   bigint REFERENCES financial_counterparty(id) ON DELETE CASCADE,
  entity_id         integer,
  realm             text,
  source_system     text CHECK (source_system IN ('bank','dext','xero','email','icrtouch','caterbook','manual')),
  confidence_class  text NOT NULL DEFAULT 'strong' CHECK (confidence_class IN ('strong','medium','weak')),
  status            text NOT NULL DEFAULT 'active' CHECK (status IN ('active','collided','disabled')),
  collided_at       timestamptz,
  collided_with     bigint[] NOT NULL DEFAULT '{}',
  first_seen_at     timestamptz NOT NULL DEFAULT now(),
  last_seen_at      timestamptz NOT NULL DEFAULT now(),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
-- One ACTIVE anchor per (type,value,scope,role) — NULL-safe (review #2). This is
-- the safety proof for "unique-in-scope => HIGH": a competing active row cannot exist.
CREATE UNIQUE INDEX IF NOT EXISTS counterparty_anchor_active_key
  ON counterparty_anchor (anchor_type, anchor_value_normalized, scope_type, scope_value, anchor_role)
  WHERE status = 'active';
CREATE INDEX IF NOT EXISTS counterparty_anchor_cp ON counterparty_anchor (counterparty_id);
CREATE INDEX IF NOT EXISTS counterparty_anchor_val_trgm
  ON counterparty_anchor USING gin (anchor_value_normalized gin_trgm_ops);
ALTER TABLE counterparty_anchor ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS realm_isolation ON counterparty_anchor;
CREATE POLICY realm_isolation ON counterparty_anchor USING (
  CASE current_setting('app.current_realm', true)
    WHEN 'owner' THEN true
    WHEN 'work' THEN realm = ANY (ARRAY['work','shared'])
    WHEN 'personal' THEN realm = ANY (ARRAY['personal','shared'])
    ELSE false END);

-- ── 2. counterparty_resolution_log — contextual learned aliases + lifecycle ────
CREATE TABLE IF NOT EXISTS counterparty_resolution_log (
  id                bigserial PRIMARY KEY,
  source_system     text NOT NULL,
  source_account    text NOT NULL DEFAULT '',
  raw_counterparty_normalized text NOT NULL,
  anchor_fingerprint text NOT NULL DEFAULT '',
  counterparty_id   bigint NOT NULL REFERENCES financial_counterparty(id) ON DELETE CASCADE,
  entity_id         integer,
  realm             text,
  site              text,
  category          text,
  property_id       bigint,
  confirmed_by      text NOT NULL,
  confirmed_at      timestamptz NOT NULL DEFAULT now(),
  validated_at      timestamptz,
  validated_by      text,
  validation_status text NOT NULL DEFAULT 'valid'
                      CHECK (validation_status IN ('valid','stale','collided','target_changed','needs_re_review','disabled')),
  evidence_json     jsonb NOT NULL DEFAULT '{}'::jsonb,
  registry_fingerprint text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
-- One VALID alias per (system,account,raw,fingerprint) — keyed on anchor_fingerprint,
-- not raw text alone (review #3 context): a confirmation under one evidence shape does
-- not auto-apply under a different shape. Superseded/non-valid history may coexist.
CREATE UNIQUE INDEX IF NOT EXISTS resolution_log_valid_key
  ON counterparty_resolution_log (source_system, source_account, raw_counterparty_normalized, anchor_fingerprint)
  WHERE validation_status = 'valid';
CREATE INDEX IF NOT EXISTS resolution_log_cp ON counterparty_resolution_log (counterparty_id);
CREATE INDEX IF NOT EXISTS resolution_log_status ON counterparty_resolution_log (validation_status);
CREATE INDEX IF NOT EXISTS resolution_log_validated ON counterparty_resolution_log (validated_at);
ALTER TABLE counterparty_resolution_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS realm_isolation ON counterparty_resolution_log;
CREATE POLICY realm_isolation ON counterparty_resolution_log USING (
  CASE current_setting('app.current_realm', true)
    WHEN 'owner' THEN true
    WHEN 'work' THEN realm = ANY (ARRAY['work','shared'])
    WHEN 'personal' THEN realm = ANY (ARRAY['personal','shared'])
    ELSE false END);

-- ── 3. counterparty_resolution_review_queue — abstention items ─────────────────
CREATE TABLE IF NOT EXISTS counterparty_resolution_review_queue (
  id                bigserial PRIMARY KEY,
  created_at        timestamptz NOT NULL DEFAULT now(),
  status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved','ignored','auto_closed')),
  source_system     text NOT NULL,
  source_ref        text NOT NULL,
  entity_id         integer,
  realm             text,
  evidence_json     jsonb NOT NULL DEFAULT '{}'::jsonb,
  abstain_reason    text,
  top_candidates    jsonb NOT NULL DEFAULT '[]'::jsonb,
  suggested_action  text CHECK (suggested_action IN ('confirm_existing','create_new','mark_non_financial','split_merge')),
  resolved_by       text,
  resolved_at       timestamptz,
  resolution_counterparty_id bigint REFERENCES financial_counterparty(id) ON DELETE SET NULL,
  decision          text,
  reversed_of       bigint REFERENCES counterparty_resolution_review_queue(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS review_queue_open ON counterparty_resolution_review_queue (status, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS review_queue_open_dedupe
  ON counterparty_resolution_review_queue (source_system, source_ref) WHERE status = 'open';
ALTER TABLE counterparty_resolution_review_queue ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS realm_isolation ON counterparty_resolution_review_queue;
CREATE POLICY realm_isolation ON counterparty_resolution_review_queue USING (
  CASE current_setting('app.current_realm', true)
    WHEN 'owner' THEN true
    WHEN 'work' THEN realm = ANY (ARRAY['work','shared'])
    WHEN 'personal' THEN realm = ANY (ARRAY['personal','shared'])
    ELSE false END);

-- ── 4. counterparty_resolution_shadow — shadow-mode decisions for scoring ──────
CREATE TABLE IF NOT EXISTS counterparty_resolution_shadow (
  id                bigserial PRIMARY KEY,
  created_at        timestamptz NOT NULL DEFAULT now(),
  source_system     text NOT NULL,
  source_ref        text NOT NULL,
  decision          text NOT NULL,        -- 'resolve' | 'abstain'
  counterparty_id   bigint,
  confidence        real,
  stage             text,                 -- which stage produced it
  abstain_reason    text,
  evidence_json     jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS shadow_src ON counterparty_resolution_shadow (source_system, created_at);
-- shadow rows carry evidence_json (raw counterparty text) → owner-only, default-deny.
ALTER TABLE counterparty_resolution_shadow ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS owner_only ON counterparty_resolution_shadow;
CREATE POLICY owner_only ON counterparty_resolution_shadow USING (current_setting('app.current_realm', true) = 'owner');

-- ── 5. lifecycle backbone (owner-visible metadata) ─────────────────────────────
CREATE TABLE IF NOT EXISTS counterparty_registry_version (
  id                bigserial PRIMARY KEY,
  counterparty_id   bigint NOT NULL REFERENCES financial_counterparty(id) ON DELETE CASCADE,
  version           integer NOT NULL,
  identity_fingerprint text NOT NULL,
  change_kind       text NOT NULL CHECK (change_kind IN ('create','rename','merge','split','disable','enable')),
  changed_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (counterparty_id, version)
);
CREATE TABLE IF NOT EXISTS counterparty_merge_history (
  id                bigserial PRIMARY KEY,
  from_id           bigint NOT NULL REFERENCES financial_counterparty(id),
  into_id           bigint NOT NULL REFERENCES financial_counterparty(id),
  merged_at         timestamptz NOT NULL DEFAULT now(),
  merged_by         text NOT NULL,
  reason            text
);
ALTER TABLE counterparty_registry_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE counterparty_merge_history ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS owner_only ON counterparty_registry_version;
DROP POLICY IF EXISTS owner_only ON counterparty_merge_history;
-- lifecycle metadata: owner realm only (revalidation/admin run in owner/all context)
CREATE POLICY owner_only ON counterparty_registry_version USING (current_setting('app.current_realm', true) = 'owner');
CREATE POLICY owner_only ON counterparty_merge_history    USING (current_setting('app.current_realm', true) = 'owner');

-- ── grants ─────────────────────────────────────────────────────────────────────
GRANT SELECT ON counterparty_anchor, counterparty_resolution_log,
                counterparty_resolution_review_queue, counterparty_resolution_shadow,
                counterparty_registry_version, counterparty_merge_history TO homeai_readonly;
GRANT SELECT, INSERT, UPDATE ON counterparty_anchor, counterparty_resolution_log,
                counterparty_resolution_review_queue, counterparty_resolution_shadow,
                counterparty_registry_version, counterparty_merge_history TO homeai_pipeline;
DO $$ DECLARE s text; BEGIN
  FOR s IN SELECT c.relname||'_id_seq' FROM pg_class c WHERE c.relname IN
    ('counterparty_anchor','counterparty_resolution_log','counterparty_resolution_review_queue',
     'counterparty_resolution_shadow','counterparty_registry_version','counterparty_merge_history')
  LOOP EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE %I TO homeai_pipeline', s); END LOOP;
END $$;

-- ── resolver mode flag (review #5) ─────────────────────────────────────────────
INSERT INTO static_context (key, value)
VALUES ('resolver.mode', '"shadow"'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- ── 6. upsert_anchor — explicit collision lifecycle (review #3) ────────────────
-- Never blindly INSERT a second active row (would hit the unique index). Detect a
-- competing active anchor for the same (type,value,scope,role); if it maps to a
-- DIFFERENT counterparty, transition BOTH to 'collided' (disqualifying), record
-- collided_with, and emit a review item. collided anchors are NEVER HIGH.
CREATE OR REPLACE FUNCTION home_ai.upsert_anchor(
  p_type text, p_role text, p_value text, p_scope_type text, p_scope_value text,
  p_counterparty_id bigint, p_entity_id integer, p_realm text,
  p_source_system text, p_confidence_class text DEFAULT 'strong'
) RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE existing counterparty_anchor%ROWTYPE; new_id bigint;
BEGIN
  SELECT * INTO existing FROM counterparty_anchor
   WHERE anchor_type=p_type AND anchor_value_normalized=p_value
     AND scope_type=p_scope_type AND COALESCE(scope_value,'')=COALESCE(p_scope_value,'')
     AND anchor_role=p_role AND status='active'
   LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO counterparty_anchor
      (anchor_type,anchor_role,anchor_value_normalized,scope_type,scope_value,
       counterparty_id,entity_id,realm,source_system,confidence_class)
    VALUES (p_type,p_role,p_value,p_scope_type,COALESCE(p_scope_value,''),
            p_counterparty_id,p_entity_id,p_realm,p_source_system,p_confidence_class);
    RETURN 'inserted';
  ELSIF existing.counterparty_id IS NOT DISTINCT FROM p_counterparty_id THEN
    UPDATE counterparty_anchor SET last_seen_at=now(), updated_at=now() WHERE id=existing.id;
    RETURN 'updated';
  ELSE
    -- COLLISION: same anchor key, different counterparty. Disqualify both, flag for review.
    UPDATE counterparty_anchor
       SET status='collided', collided_at=now(),
           collided_with = array(SELECT DISTINCT unnest(collided_with || ARRAY[p_counterparty_id])),
           updated_at=now()
     WHERE id=existing.id;
    INSERT INTO counterparty_anchor
      (anchor_type,anchor_role,anchor_value_normalized,scope_type,scope_value,
       counterparty_id,entity_id,realm,source_system,confidence_class,status,collided_at,collided_with)
    VALUES (p_type,p_role,p_value,p_scope_type,COALESCE(p_scope_value,''),
            p_counterparty_id,p_entity_id,p_realm,p_source_system,p_confidence_class,
            'collided',now(),ARRAY[existing.counterparty_id])
    RETURNING id INTO new_id;
    INSERT INTO counterparty_resolution_review_queue
      (status,source_system,source_ref,entity_id,realm,abstain_reason,top_candidates,suggested_action)
    VALUES ('open',p_source_system,'anchor_collision:'||p_type||':'||p_value,p_entity_id,p_realm,
            'anchor_collision',
            jsonb_build_array(jsonb_build_object('counterparty_id',existing.counterparty_id,'why','prior active anchor'),
                              jsonb_build_object('counterparty_id',p_counterparty_id,'why','competing anchor')),
            'split_merge')
    ON CONFLICT (source_system, source_ref) WHERE status='open' DO NOTHING;
    RETURN 'collided';
  END IF;
END;
$fn$;

COMMIT;
