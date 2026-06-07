-- V244 — n8n workflow registry, CHAINS. Entry points (webhook + schedule
-- triggers) and the workflow->workflow call graph, reconstructed by matching an
-- httpRequest URL's /webhook/<path> against the webhook node that owns <path>.
-- Reversible:
--   DROP VIEW home_ai.v_n8n_workflow_calls;
--   DROP VIEW home_ai.v_n8n_triggers;
BEGIN;

CREATE OR REPLACE VIEW home_ai.v_n8n_triggers AS
SELECT
  w.name AS workflow,
  w.id   AS workflow_id,
  node->>'type' AS trigger_type,
  coalesce(node->'parameters'->>'path',
           node->'parameters'->'rule'->'interval'->0->>'field', '') AS detail
FROM workflow_entity w,
     jsonb_array_elements(w.nodes::jsonb) node
WHERE node->>'type' IN ('n8n-nodes-base.webhook', 'n8n-nodes-base.scheduleTrigger');

CREATE OR REPLACE VIEW home_ai.v_n8n_workflow_calls AS
WITH calls AS (
  SELECT w.name AS caller, w.id AS caller_id,
         substring(node->'parameters'->>'url' from '/webhook/([a-zA-Z0-9_-]+)') AS target_path
  FROM workflow_entity w,
       jsonb_array_elements(w.nodes::jsonb) node
  WHERE node->'parameters'->>'url' LIKE '%/webhook/%'
),
hooks AS (
  SELECT w.name AS target, w.id AS target_id,
         node->'parameters'->>'path' AS path
  FROM workflow_entity w,
       jsonb_array_elements(w.nodes::jsonb) node
  WHERE node->>'type' = 'n8n-nodes-base.webhook'
)
SELECT c.caller, c.caller_id, c.target_path,
       h.target, h.target_id
FROM calls c
LEFT JOIN hooks h ON h.path = c.target_path
WHERE c.target_path IS NOT NULL;

COMMIT;
