-- V239 — SQL dependency graph, OBJECT level. Flattens Postgres' own dependency
-- catalog (pg_depend/pg_rewrite/pg_trigger/pg_policy) into queryable home_ai views
-- + two recursive closure functions. Read-only over system catalogs; no RLS.
-- Reversible:
--   DROP FUNCTION home_ai.object_dependents(text);
--   DROP FUNCTION home_ai.object_dependencies(text);
--   DROP VIEW home_ai.v_object_edges;
--   DROP VIEW home_ai.v_rls_policy_map;
--   DROP VIEW home_ai.v_trigger_map;
--   DROP VIEW home_ai.v_view_deps;
BEGIN;

-- view/matview -> referenced relation (object level)
CREATE OR REPLACE VIEW home_ai.v_view_deps AS
SELECT DISTINCT
  dep_ns.nspname AS view_schema,
  dep.relname    AS view_name,
  ref_ns.nspname AS depends_on_schema,
  ref.relname    AS depends_on,
  ref.relkind    AS depends_on_kind
FROM pg_depend d
JOIN pg_rewrite   r      ON r.oid = d.objid
JOIN pg_class     dep    ON dep.oid = r.ev_class
JOIN pg_namespace dep_ns ON dep_ns.oid = dep.relnamespace
JOIN pg_class     ref    ON ref.oid = d.refobjid
JOIN pg_namespace ref_ns ON ref_ns.oid = ref.relnamespace
WHERE d.deptype = 'n'
  AND dep.oid <> ref.oid
  AND dep.relkind IN ('v','m')
  AND ref.relkind IN ('r','v','m','p');

-- table -> trigger -> function
CREATE OR REPLACE VIEW home_ai.v_trigger_map AS
SELECT
  tn.nspname AS table_schema,
  t.relname  AS table_name,
  tg.tgname  AS trigger_name,
  fn.nspname AS function_schema,
  p.proname  AS function_name
FROM pg_trigger tg
JOIN pg_class     t  ON t.oid = tg.tgrelid
JOIN pg_namespace tn ON tn.oid = t.relnamespace
JOIN pg_proc      p  ON p.oid = tg.tgfoid
JOIN pg_namespace fn ON fn.oid = p.pronamespace
WHERE NOT tg.tgisinternal;

-- table -> RLS policy
CREATE OR REPLACE VIEW home_ai.v_rls_policy_map AS
SELECT
  pn.nspname  AS table_schema,
  c.relname   AS table_name,
  pol.polname AS policy_name,
  CASE pol.polcmd WHEN 'r' THEN 'SELECT' WHEN 'a' THEN 'INSERT'
                  WHEN 'w' THEN 'UPDATE' WHEN 'd' THEN 'DELETE'
                  ELSE 'ALL' END AS command,
  pol.polpermissive::boolean AS is_permissive
FROM pg_policy pol
JOIN pg_class     c  ON c.oid = pol.polrelid
JOIN pg_namespace pn ON pn.oid = c.relnamespace;

-- unified directed edge list for traversal
CREATE OR REPLACE VIEW home_ai.v_object_edges AS
  SELECT view_schema AS src_schema, view_name AS src_name, 'view'::text AS src_kind,
         'uses'::text AS edge_kind,
         depends_on_schema AS dst_schema, depends_on AS dst_name,
         CASE depends_on_kind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view'
              WHEN 'm' THEN 'matview' WHEN 'p' THEN 'partitioned'
              ELSE 'relation' END AS dst_kind
  FROM home_ai.v_view_deps
  UNION ALL
  SELECT table_schema, table_name, 'table', 'has_trigger',
         function_schema, function_name, 'function'
  FROM home_ai.v_trigger_map
  UNION ALL
  SELECT table_schema, table_name, 'table', 'has_policy',
         table_schema, policy_name, 'rls_policy'
  FROM home_ai.v_rls_policy_map;

-- everything object p_name (transitively) DEPENDS ON (downstream reads)
CREATE OR REPLACE FUNCTION home_ai.object_dependencies(p_name text)
RETURNS TABLE(depth int, src_name text, edge_kind text, dst_name text, dst_kind text)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE walk AS (
    SELECT 1 AS depth, e.src_schema, e.src_name, e.edge_kind,
           e.dst_schema, e.dst_name, e.dst_kind,
           ARRAY[e.src_schema || '.' || e.src_name,
                 e.dst_schema || '.' || e.dst_name] AS visited
    FROM home_ai.v_object_edges e
    WHERE e.src_name = p_name
    UNION ALL
    SELECT w.depth + 1, e.src_schema, e.src_name, e.edge_kind,
           e.dst_schema, e.dst_name, e.dst_kind,
           w.visited || (e.dst_schema || '.' || e.dst_name)
    FROM home_ai.v_object_edges e
    JOIN walk w ON e.src_schema = w.dst_schema AND e.src_name = w.dst_name
    WHERE w.depth < 20
      AND NOT ((e.dst_schema || '.' || e.dst_name) = ANY (w.visited))
  )
  SELECT depth, src_name, edge_kind, dst_name, dst_kind FROM walk;
$$;

-- everything that (transitively) DEPENDS ON object p_name (impact analysis)
CREATE OR REPLACE FUNCTION home_ai.object_dependents(p_name text)
RETURNS TABLE(depth int, src_name text, edge_kind text, dst_name text, dst_kind text)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE walk AS (
    SELECT 1 AS depth, e.src_schema, e.src_name, e.edge_kind,
           e.dst_schema, e.dst_name, e.dst_kind,
           ARRAY[e.dst_schema || '.' || e.dst_name,
                 e.src_schema || '.' || e.src_name] AS visited
    FROM home_ai.v_object_edges e
    WHERE e.dst_name = p_name
    UNION ALL
    SELECT w.depth + 1, e.src_schema, e.src_name, e.edge_kind,
           e.dst_schema, e.dst_name, e.dst_kind,
           w.visited || (e.src_schema || '.' || e.src_name)
    FROM home_ai.v_object_edges e
    JOIN walk w ON e.dst_schema = w.src_schema AND e.dst_name = w.src_name
    WHERE w.depth < 20
      AND NOT ((e.src_schema || '.' || e.src_name) = ANY (w.visited))
  )
  SELECT depth, src_name, edge_kind, dst_name, dst_kind FROM walk;
$$;

COMMIT;
