-- V242 — n8n workflow registry, CORE. Inventory of each workflow + the outbound
-- HTTP service calls its httpRequest nodes make. Read-only over workflow_entity
-- (n8n's saved node graph). nodes is type json -> cast ::jsonb.
-- Reversible:
--   DROP VIEW home_ai.v_n8n_http_calls;
--   DROP VIEW home_ai.v_n8n_workflows;
BEGIN;

CREATE OR REPLACE VIEW home_ai.v_n8n_workflows AS
SELECT
  w.id,
  w.name,
  w.active,
  jsonb_array_length(w.nodes::jsonb) AS node_count,
  (SELECT count(*) FROM jsonb_array_elements(w.nodes::jsonb) n
     WHERE n->>'type' = 'n8n-nodes-base.postgres')    AS postgres_nodes,
  (SELECT count(*) FROM jsonb_array_elements(w.nodes::jsonb) n
     WHERE n->>'type' = 'n8n-nodes-base.httpRequest')  AS http_nodes
FROM workflow_entity w;

-- One row per httpRequest node. host is best-effort: NULL/partial for dynamic
-- (={{...}}) URLs, which are flagged is_dynamic.
CREATE OR REPLACE VIEW home_ai.v_n8n_http_calls AS
SELECT
  w.name AS workflow,
  w.id   AS workflow_id,
  node->>'name' AS node_name,
  node->'parameters'->>'url' AS url,
  (left(node->'parameters'->>'url', 1) = '=') AS is_dynamic,
  substring(node->'parameters'->>'url'
            from 'https?://([a-zA-Z0-9_.:-]+)') AS host
FROM workflow_entity w,
     jsonb_array_elements(w.nodes::jsonb) node
WHERE node->>'type' = 'n8n-nodes-base.httpRequest'
  AND node->'parameters'->>'url' IS NOT NULL;

COMMIT;
