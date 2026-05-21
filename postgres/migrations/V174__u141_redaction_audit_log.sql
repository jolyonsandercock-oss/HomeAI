-- =============================================================================
-- V174 — U141: redaction_audit_log table for Presidio forensic ledger.
-- =============================================================================
-- Every cloud-bound LLM call now passes through homeai-presidio for PII
-- redaction. This table logs each redaction event so we can:
--   * audit what kinds of PII the system has been seeing (recognisers_hit)
--   * detect HARD-FAIL events when Presidio is unreachable (status='hard_fail')
--   * verify recogniser coverage during the U146 7-day soak
--
-- We DO NOT store the original or redacted text — only:
--   * sha256_input: lets us correlate identical payloads without keeping content
--   * recognisers_hit: jsonb summary {"UK_POSTCODE": 2, "UK_SORT_CODE": 1, ...}
--   * redacted_token_count: how many spans were replaced
-- =============================================================================

BEGIN;

CREATE TABLE redaction_audit_log (
    id                   bigserial PRIMARY KEY,
    ts                   timestamptz NOT NULL DEFAULT NOW(),
    sha256_input         text NOT NULL,
    recognisers_hit      jsonb NOT NULL DEFAULT '{}'::jsonb,
    redacted_token_count integer NOT NULL DEFAULT 0,
    input_length         integer NOT NULL DEFAULT 0,
    status               text NOT NULL DEFAULT 'ok'
                         CHECK (status IN ('ok','hard_fail','degraded','bypass')),
    workflow_id          text,
    capability_tag       text,
    error_message        text,
    presidio_version     text,
    latency_ms           integer,
    realm                text NOT NULL DEFAULT 'work'
                         CHECK (realm IN ('owner','work','personal','family','shared'))
);

CREATE INDEX idx_redaction_ts          ON redaction_audit_log(ts DESC);
CREATE INDEX idx_redaction_status      ON redaction_audit_log(status, ts DESC) WHERE status <> 'ok';
CREATE INDEX idx_redaction_workflow    ON redaction_audit_log(workflow_id, ts DESC) WHERE workflow_id IS NOT NULL;
CREATE INDEX idx_redaction_sha         ON redaction_audit_log(sha256_input);

ALTER TABLE redaction_audit_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY realm_isolation ON redaction_audit_log
USING (
  CASE
    WHEN current_setting('app.current_realm', true) = 'owner'    THEN TRUE
    WHEN current_setting('app.current_realm', true) = 'work'     THEN (realm = ANY (ARRAY['work','shared']))
    WHEN current_setting('app.current_realm', true) = 'personal' THEN (realm = ANY (ARRAY['family','personal','shared']))
    WHEN current_setting('app.current_realm', true) = 'family'   THEN (realm = ANY (ARRAY['family','personal','shared']))
    WHEN (current_setting('app.current_realm', true) IS NULL
       OR current_setting('app.current_realm', true) = '')       THEN TRUE
    ELSE FALSE
  END
);

GRANT INSERT, SELECT ON redaction_audit_log TO homeai_readonly;
GRANT USAGE, SELECT ON SEQUENCE redaction_audit_log_id_seq TO homeai_readonly;
-- Presidio service connects as homeai_pipeline (per x-postgres-env anchor):
GRANT INSERT, SELECT ON redaction_audit_log TO homeai_pipeline;
GRANT USAGE, SELECT ON SEQUENCE redaction_audit_log_id_seq TO homeai_pipeline;

-- View: 24h redaction summary
CREATE OR REPLACE VIEW v_redaction_24h AS
SELECT status,
       COUNT(*) AS event_count,
       SUM(redacted_token_count) AS total_redactions,
       SUM(input_length) AS total_input_chars,
       ROUND(AVG(latency_ms))::int AS avg_latency_ms,
       MAX(ts) AS most_recent
  FROM redaction_audit_log
 WHERE ts >= NOW() - INTERVAL '24 hours'
 GROUP BY status;

GRANT SELECT ON v_redaction_24h TO homeai_readonly;

-- Slug for /admin tile
INSERT INTO query_whitelist
  (slug, display_name, description, sql_template, param_schema, result_format,
   active, created_by, approved_at, approved_by, notes, realm, intent_examples)
VALUES
('redaction_24h_summary',
 'U141 — redaction events last 24h',
 'Counts of redaction events by status (ok / hard_fail / degraded / bypass) over last 24h. hard_fail count > 0 means cloud-bound LLM calls were blocked due to Presidio outage.',
 $sql$SELECT * FROM v_redaction_24h$sql$,
 '{}'::jsonb,
 'table', true, 'u141', NOW(), 'u141', NULL, 'shared',
 ARRAY['redaction summary','presidio status']);

COMMIT;
