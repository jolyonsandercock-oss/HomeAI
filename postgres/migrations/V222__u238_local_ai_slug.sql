-- V222 — U238: local-model workload slug (owner realm) for the backend page.
-- Surfaces what the local Ollama/qwen model is doing (calls/tokens by workload),
-- gated to owner via the new realm gate (U147 Phase B front-half).
INSERT INTO query_whitelist (slug, sql_template, param_schema, realm, active, display_name, created_by)
VALUES ('backend_local_ai_30d',
'SELECT COALESCE(service, task_type, ''(unknown)'') AS workload, capability_tag,
        count(*) AS calls, COALESCE(sum(prompt_tokens),0)::bigint AS prompt_tokens,
        COALESCE(sum(completion_tokens),0)::bigint AS completion_tokens, max(timestamp) AS latest
   FROM ai_usage WHERE provider=''ollama'' AND timestamp >= now() - interval ''30 days''
  GROUP BY 1,2 ORDER BY count(*) DESC',
'{}'::jsonb, 'owner', true, 'Local model workload (30d)', 'U238')
ON CONFLICT (slug) DO UPDATE SET sql_template=EXCLUDED.sql_template, realm='owner', active=true, approved_at=NOW();
UPDATE query_whitelist SET approved_at=NOW() WHERE slug='backend_local_ai_30d';
