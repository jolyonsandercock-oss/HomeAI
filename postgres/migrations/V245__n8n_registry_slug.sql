-- V245 — register the n8n_workflow slug (tables a workflow touches) for run_slug
-- / the playground. The :name-param template must pass the V238 validate_slug
-- trigger (EXPLAIN with :name->NULL plans OK).
-- Reversible: DELETE FROM query_whitelist WHERE slug='n8n_workflow_tables';
BEGIN;

INSERT INTO query_whitelist (slug, display_name, sql_template, param_schema,
                            active, created_by, approved_at, realm)
VALUES (
  'n8n_workflow_tables',
  'n8n workflow → DB tables it touches',
  'SELECT DISTINCT referenced_table FROM home_ai.v_n8n_sql_refs WHERE workflow = :name ORDER BY 1',
  '{"name": "text"}'::jsonb,
  true, 'n8n-registry-plan', now(), 'owner'
)
ON CONFLICT (slug) DO UPDATE
  SET sql_template = EXCLUDED.sql_template,
      param_schema = EXCLUDED.param_schema,
      active       = EXCLUDED.active;

COMMIT;
