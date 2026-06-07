-- V240 — SQL dependency graph, COLUMN-REFERENCE level. pg_depend records the
-- exact base columns a view references via refobjsubid; this surfaces them.
-- SCOPE: column *reference* ("view Y reads base column T.C"), NOT column
-- *derivation* ("output column cogs comes from T.C") — the latter needs
-- pg_rewrite targetlist parsing and is a documented stretch, out of scope here.
-- Reversible:
--   DROP FUNCTION home_ai.column_consumers(text, text);
--   DROP VIEW home_ai.v_view_column_deps;
BEGIN;

CREATE OR REPLACE VIEW home_ai.v_view_column_deps AS
SELECT DISTINCT
  dep_ns.nspname AS view_schema,
  dep.relname    AS view_name,
  ref_ns.nspname AS base_schema,
  ref.relname    AS base_table,
  a.attname      AS base_column
FROM pg_depend d
JOIN pg_rewrite   r      ON r.oid = d.objid
JOIN pg_class     dep    ON dep.oid = r.ev_class
JOIN pg_namespace dep_ns ON dep_ns.oid = dep.relnamespace
JOIN pg_class     ref    ON ref.oid = d.refobjid
JOIN pg_namespace ref_ns ON ref_ns.oid = ref.relnamespace
JOIN pg_attribute a      ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
WHERE d.deptype = 'n'
  AND d.refobjsubid > 0
  AND dep.relkind IN ('v','m')
  AND ref.relkind IN ('r','v','m','p')
  AND NOT a.attisdropped;

-- which views consume a given base column (impact of changing T.C)
CREATE OR REPLACE FUNCTION home_ai.column_consumers(p_table text, p_column text)
RETURNS TABLE(view_schema text, view_name text)
LANGUAGE sql STABLE AS $$
  SELECT DISTINCT view_schema, view_name
  FROM home_ai.v_view_column_deps
  WHERE base_table = p_table AND base_column = p_column;
$$;

COMMIT;
