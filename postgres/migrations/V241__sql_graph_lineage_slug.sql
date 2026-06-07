-- V241 — register the sql_lineage slug so the graph is reachable via run_slug /
-- the playground, not only the MCP tool. The :named-param template must pass the
-- V238 validate_slug trigger (EXPLAIN with :object->NULL plans OK).
-- Reversible: DELETE FROM query_whitelist WHERE slug='sql_lineage';
BEGIN;

INSERT INTO query_whitelist (slug, display_name, sql_template, param_schema,
                            active, created_by, approved_at, realm)
VALUES (
  'sql_lineage',
  'SQL object dependents (impact)',
  'SELECT depth, src_name, edge_kind, dst_name, dst_kind FROM home_ai.object_dependents(:object) ORDER BY depth',
  '{"object": "text"}'::jsonb,
  true, 'sql-graph-plan', now(), 'owner'
)
ON CONFLICT (slug) DO UPDATE
  SET sql_template = EXCLUDED.sql_template,
      param_schema = EXCLUDED.param_schema,
      active       = EXCLUDED.active;

COMMIT;
