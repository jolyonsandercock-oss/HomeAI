-- V243 — n8n workflow registry, SQL REFS. Extracts table names referenced by
-- each postgres node's inline query, via regex, then KEEPS ONLY real public
-- tables (drops aliases/CTEs/false positives). Bridges into the SQL graph:
--   SELECT * FROM home_ai.object_dependents(referenced_table)  -- affected views.
-- Reversible:
--   DROP VIEW home_ai.v_n8n_sql_refs;
BEGIN;

CREATE OR REPLACE VIEW home_ai.v_n8n_sql_refs AS
WITH pg_nodes AS (
  SELECT w.name AS workflow, w.id AS workflow_id,
         node->>'name' AS node_name,
         coalesce(node->'parameters'->>'query', '') AS sql_text
  FROM workflow_entity w,
       jsonb_array_elements(w.nodes::jsonb) node
  WHERE node->>'type' = 'n8n-nodes-base.postgres'
)
SELECT DISTINCT
  p.workflow,
  p.workflow_id,
  p.node_name,
  lower(m[1]) AS referenced_table
FROM pg_nodes p,
     regexp_matches(p.sql_text,
       '(?:from|join|into|update)\s+"?([a-zA-Z_][a-zA-Z0-9_]*)"?', 'gi') AS m
WHERE EXISTS (
  SELECT 1 FROM pg_tables t
  WHERE t.schemaname = 'public' AND t.tablename = lower(m[1])
);

COMMIT;
