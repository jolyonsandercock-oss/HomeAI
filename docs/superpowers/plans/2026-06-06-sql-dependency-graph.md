# SQL Dependency Graph Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose Postgres's own dependency catalog as queryable lineage views (object- and column-level) so agents and humans can answer "what depends on X / what does view Y read" without manually reading view definitions.

**Architecture:** Three reversible, self-testing sprints. We do **not** build a graph store — Postgres already maintains the dependency graph in `pg_depend` / `pg_rewrite` / `pg_trigger` / `pg_policy`. We flatten it into `home_ai.*` views + two recursive helper functions (object-level), extend with column-reference edges, then expose both through the existing `homeai-mcp` server and a `query_whitelist` slug. Each sprint is a migration with a paired `DROP`, gated by a SQL self-test asserting a **known-real edge** (`v_daily_cost_vs_sales → vendor_invoice_inbox.category_canonical`, verified live 2026-06-06).

**Tech Stack:** PostgreSQL system catalogs (`pg_depend`, `pg_rewrite`, `pg_trigger`, `pg_policy`, `pg_attribute`); `home_ai` schema; `homeai-mcp` (FastMCP, `services/homeai-mcp/server.py`); `query_whitelist` slug table (subject to the V238 validation trigger).

**Design decisions (locked):** views-then-MCP surface; object-level first, column-reference second; column *derivation* (output-column → input-column mapping) is explicitly **out of scope** (needs `pg_rewrite` targetlist parsing) and documented as a stretch.

---

## Conventions used by every task

- **Migrations** live in `postgres/migrations/Vxxx__name.sql`. Latest existing is **V238**; this plan adds **V239, V240, V241**. Each wraps its DDL in `BEGIN; … COMMIT;` and documents its `DROP` reversal in a header comment.
- **Apply a migration** (the established pattern in this repo):
  ```bash
  cd /home_ai
  PGPW=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)
  docker cp postgres/migrations/Vxxx__name.sql homeai-postgres:/tmp/Vxxx.sql
  docker exec -e PGPASSWORD="$PGPW" homeai-postgres \
    psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f /tmp/Vxxx.sql
  ```
- **Run a self-test query**: write it to `/tmp/test.sql`, `docker cp` it in, run with `psql -f` (avoids heredoc/quoting traps seen this session).
- **Pre-commit hook** entropy-scans staged diffs; these commits are SQL/code with no secrets, so it will pass normally. Do **not** use `--no-verify` unless a pure-deletion diff false-blocks it.
- All objects live in the **`home_ai`** schema (same as `home_ai.set_realm`), are owned by `postgres`, and read only system catalogs — no RLS interaction, no realm column.

---

## File Structure

| File | Responsibility |
|---|---|
| `postgres/migrations/V239__sql_graph_object_level.sql` | Object-level lineage: `v_view_deps`, `v_trigger_map`, `v_rls_policy_map`, unified `v_object_edges`, recursive `object_dependencies()` / `object_dependents()`. |
| `postgres/migrations/V240__sql_graph_column_level.sql` | Column-reference lineage: `v_view_column_deps` + `column_consumers()`. |
| `postgres/migrations/V241__sql_graph_lineage_slug.sql` | Inserts the `sql_lineage` row into `query_whitelist` (passes the V238 validation trigger). |
| `services/homeai-mcp/server.py` (modify) | Adds `@mcp.tool() sql_lineage(...)` exposing the recursive functions over MCP. |
| `docs/superpowers/plans/2026-06-06-sql-dependency-graph.md` | This plan. |

---

## Sprint S1 — Object-level lineage (V239)

**Files:**
- Create: `postgres/migrations/V239__sql_graph_object_level.sql`
- Test: `/tmp/s1_test.sql` (scratch)

- [ ] **Step 1: Write the migration file**

Create `postgres/migrations/V239__sql_graph_object_level.sql`:

```sql
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
  pol.polpermissive AS is_permissive
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
    SELECT 1 AS depth, e.src_name, e.edge_kind, e.dst_name, e.dst_kind
    FROM home_ai.v_object_edges e
    WHERE e.src_name = p_name
    UNION
    SELECT w.depth + 1, e.src_name, e.edge_kind, e.dst_name, e.dst_kind
    FROM home_ai.v_object_edges e
    JOIN walk w ON e.src_name = w.dst_name
    WHERE w.depth < 20
  )
  SELECT depth, src_name, edge_kind, dst_name, dst_kind FROM walk;
$$;

-- everything that (transitively) DEPENDS ON object p_name (impact analysis)
CREATE OR REPLACE FUNCTION home_ai.object_dependents(p_name text)
RETURNS TABLE(depth int, src_name text, edge_kind text, dst_name text, dst_kind text)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE walk AS (
    SELECT 1 AS depth, e.src_name, e.edge_kind, e.dst_name, e.dst_kind
    FROM home_ai.v_object_edges e
    WHERE e.dst_name = p_name
    UNION
    SELECT w.depth + 1, e.src_name, e.edge_kind, e.dst_name, e.dst_kind
    FROM home_ai.v_object_edges e
    JOIN walk w ON e.dst_name = w.src_name
    WHERE w.depth < 20
  )
  SELECT depth, src_name, edge_kind, dst_name, dst_kind FROM walk;
$$;

COMMIT;
```

Note: the recursive CTEs use `UNION` (not `UNION ALL`) so cycles dedup; `depth < 20` is a hard stop.

- [ ] **Step 2: Apply the migration**

```bash
cd /home_ai
PGPW=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)
docker cp postgres/migrations/V239__sql_graph_object_level.sql homeai-postgres:/tmp/V239.sql
docker exec -e PGPASSWORD="$PGPW" homeai-postgres \
  psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f /tmp/V239.sql
```
Expected: `BEGIN … CREATE VIEW … CREATE FUNCTION … COMMIT` with no error.

- [ ] **Step 3: Write the self-test**

Create `/tmp/s1_test.sql`:

```sql
\echo === T1: known view->table edge present (must return 1) ===
SELECT count(*) AS must_be_1 FROM home_ai.v_view_deps
WHERE view_name='v_daily_cost_vs_sales' AND depends_on='vendor_invoice_inbox';

\echo === T2: bank_transactions has exactly its 2 RLS policies ===
SELECT count(*) AS must_be_2 FROM home_ai.v_rls_policy_map
WHERE table_name='bank_transactions';

\echo === T3: edge list is non-trivial (expect >100 view edges) ===
SELECT count(*) AS edges FROM home_ai.v_object_edges WHERE edge_kind='uses';

\echo === T4: impact closure finds the downstream view (must return >=1) ===
SELECT count(*) AS must_be_ge_1 FROM home_ai.object_dependents('vendor_invoice_inbox')
WHERE dst_name='v_daily_cost_vs_sales' OR src_name='v_daily_cost_vs_sales';

\echo === T5: transitive closure reaches a 2nd-hop view (v_daily_cost_vs_sales -> v_daily_unit_economics) ===
SELECT bool_or(dst_name='v_daily_unit_economics') AS reaches_2nd_hop
FROM home_ai.object_dependencies('v_daily_cost_vs_sales');
```

- [ ] **Step 4: Run the self-test**

```bash
docker cp /tmp/s1_test.sql homeai-postgres:/tmp/s1_test.sql
docker exec -e PGPASSWORD="$PGPW" homeai-postgres psql -U postgres -d homeai -f /tmp/s1_test.sql
```
Expected: T1 `must_be_1 = 1`; T2 `must_be_2 = 2`; T3 `edges > 100`; T4 `must_be_ge_1 >= 1`; T5 `reaches_2nd_hop = t`. If any fails → the migration is wrong; fix before committing.

- [ ] **Step 5: Commit**

```bash
cd /home_ai
git add postgres/migrations/V239__sql_graph_object_level.sql
git commit -m "SQL graph S1: object-level lineage views + recursive closure (V239)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Sprint S2 — Column-reference lineage (V240)

**Files:**
- Create: `postgres/migrations/V240__sql_graph_column_level.sql`
- Test: `/tmp/s2_test.sql` (scratch)

- [ ] **Step 1: Write the migration file**

Create `postgres/migrations/V240__sql_graph_column_level.sql`:

```sql
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
```

- [ ] **Step 2: Apply the migration**

```bash
cd /home_ai
PGPW=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)
docker cp postgres/migrations/V240__sql_graph_column_level.sql homeai-postgres:/tmp/V240.sql
docker exec -e PGPASSWORD="$PGPW" homeai-postgres \
  psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f /tmp/V240.sql
```
Expected: `BEGIN … CREATE VIEW … CREATE FUNCTION … COMMIT`, no error.

- [ ] **Step 3: Write the self-test**

Create `/tmp/s2_test.sql`:

```sql
\echo === T1: the exact cited column edge exists (must return 1) ===
SELECT count(*) AS must_be_1 FROM home_ai.v_view_column_deps
WHERE view_name='v_daily_cost_vs_sales'
  AND base_table='vendor_invoice_inbox'
  AND base_column='category_canonical';

\echo === T2: column_consumers() finds that view from the base column ===
SELECT count(*) AS must_be_ge_1
FROM home_ai.column_consumers('vendor_invoice_inbox','category_canonical')
WHERE view_name='v_daily_cost_vs_sales';

\echo === T3: column edges are non-trivial (expect > T-table object edges) ===
SELECT count(*) AS column_edges FROM home_ai.v_view_column_deps;
```

- [ ] **Step 4: Run the self-test**

```bash
docker cp /tmp/s2_test.sql homeai-postgres:/tmp/s2_test.sql
docker exec -e PGPASSWORD="$PGPW" homeai-postgres psql -U postgres -d homeai -f /tmp/s2_test.sql
```
Expected: T1 `must_be_1 = 1`; T2 `must_be_ge_1 >= 1`; T3 `column_edges > 0`. Any failure → fix the migration before committing.

- [ ] **Step 5: Commit**

```bash
cd /home_ai
git add postgres/migrations/V240__sql_graph_column_level.sql
git commit -m "SQL graph S2: column-reference lineage view + column_consumers() (V240)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Sprint S3 — MCP + slug exposure (server.py + V241)

**Files:**
- Modify: `services/homeai-mcp/server.py` (add one `@mcp.tool()` after the existing `query_postgres_readonly` tool, ~line 103)
- Create: `postgres/migrations/V241__sql_graph_lineage_slug.sql`
- Test: `/tmp/s3_slug_test.sql` (scratch) + an MCP/HTTP probe

- [ ] **Step 1: Read the existing tool pattern**

Run: `sed -n '100,135p' services/homeai-mcp/server.py`
Expected: confirm the `@mcp.tool()` decorator style, that `get_pool()` returns an `asyncpg.Pool`, and that tools return a `str` (the existing `query_postgres_readonly` and `list_slugs` both return `str`). Match this exactly.

- [ ] **Step 2: Add the `sql_lineage` MCP tool**

In `services/homeai-mcp/server.py`, immediately after the `query_postgres_readonly` tool function, add:

```python
@mcp.tool()
async def sql_lineage(object_name: str, direction: str = "dependents") -> str:
    """Return the dependency subgraph for a database object (view/table).

    direction='dependents' (default): everything that depends ON object_name
      (impact analysis — what breaks if you change it).
    direction='dependencies': everything object_name reads (downstream).
    Returns JSON: [{"depth","src_name","edge_kind","dst_name","dst_kind"}].
    """
    if direction not in ("dependents", "dependencies"):
        return json.dumps({"error": "direction must be 'dependents' or 'dependencies'"})
    fn = "home_ai.object_dependents" if direction == "dependents" else "home_ai.object_dependencies"
    pool = await get_pool()
    async with pool.acquire() as c:
        rows = await c.fetch(f"SELECT depth, src_name, edge_kind, dst_name, dst_kind FROM {fn}($1) ORDER BY depth", object_name)
    return json.dumps([dict(r) for r in rows])
```

Verify `json` is imported at the top of `server.py` (it is used by `list_slugs`); if not, add `import json`.

- [ ] **Step 3: Write the slug migration**

Create `postgres/migrations/V241__sql_graph_lineage_slug.sql`:

```sql
-- V241 — register the sql_lineage slug so the graph is reachable via run_slug /
-- the playground, not only the MCP tool. The template uses a :named param and
-- must pass the V238 validate_slug trigger (EXPLAIN with :object->NULL plans OK).
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
```
Note: confirm the real `query_whitelist` column set first with `\d query_whitelist`; if `created_by`/`approved_at`/`realm` differ, match the columns the table actually has (the inserted row must satisfy NOT NULL constraints — `display_name`, `created_by` were NOT NULL when checked in H3).

- [ ] **Step 4: Apply the slug migration (proves it passes the V238 trigger)**

```bash
cd /home_ai
PGPW=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)
docker cp postgres/migrations/V241__sql_graph_lineage_slug.sql homeai-postgres:/tmp/V241.sql
docker exec -e PGPASSWORD="$PGPW" homeai-postgres \
  psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f /tmp/V241.sql
```
Expected: `INSERT 0 1` (or `UPDATE 1`) with **no** `does not plan` error from the validate_slug trigger. A trigger rejection here means the template is malformed — fix it.

- [ ] **Step 5: Rebuild + recreate the MCP service**

```bash
cd /home_ai
docker tag $(docker inspect homeai-mcp --format '{{.Config.Image}}') homeai-mcp:pre-sqlgraph 2>/dev/null || true
docker compose build homeai-mcp
docker compose up -d homeai-mcp
sleep 4
docker ps --format '{{.Names}}: {{.Status}}' | grep mcp
```
Expected: `homeai-mcp` shows `Up`. (Rollback if needed: `docker tag homeai-mcp:pre-sqlgraph <image> && docker compose up -d homeai-mcp`.)

- [ ] **Step 6: Self-test the slug path (DB) and the MCP tool (service)**

Create `/tmp/s3_slug_test.sql`:

```sql
\echo === slug registered + active (must return 1) ===
SELECT count(*) AS must_be_1 FROM query_whitelist WHERE slug='sql_lineage' AND active;
\echo === slug template runs and returns the known downstream view ===
SELECT count(*) AS must_be_ge_1
FROM home_ai.object_dependents('vendor_invoice_inbox')
WHERE src_name='v_daily_cost_vs_sales' OR dst_name='v_daily_cost_vs_sales';
```
Run it:
```bash
docker cp /tmp/s3_slug_test.sql homeai-postgres:/tmp/s3_slug_test.sql
docker exec -e PGPASSWORD="$PGPW" homeai-postgres psql -U postgres -d homeai -f /tmp/s3_slug_test.sql
```
Expected: both `must_be_1 = 1` and `must_be_ge_1 >= 1`.

Then verify the MCP container imported the new tool cleanly (no import error at boot):
```bash
docker logs homeai-mcp --since 60s 2>&1 | grep -iE 'error|traceback' || echo "MCP booted clean"
```
Expected: `MCP booted clean`. (If the MCP server exposes an HTTP/SSE health route on :8765, additionally curl it; otherwise the clean-boot log + the slug DB test are the gate.)

- [ ] **Step 7: Commit**

```bash
cd /home_ai
git add services/homeai-mcp/server.py postgres/migrations/V241__sql_graph_lineage_slug.sql
git commit -m "SQL graph S3: expose lineage via homeai-mcp sql_lineage tool + slug (V241)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Out of scope (documented, not deferred-by-omission)

- **Column derivation** (output-column → input-column mapping, e.g. "`cogs` is computed from `vendor_invoice_inbox.net_amount`"). Requires parsing the view's `pg_rewrite` targetlist / `pg_get_viewdef` output — a parser, not a catalog join. Revisit only if column-reference lineage proves insufficient for the "why is this number wrong" workflow.
- **Function-body dependencies.** `pg_depend` does not track tables referenced inside `plpgsql`/`sql` function bodies, so `v_object_edges` covers `trigger → function` but not `function → tables it reads/writes`. Tracing those needs body parsing; out of scope.
- **n8n workflow registry** and **SPEC.md semantic index** — separate initiatives (see `.hermes/code-graph-review.md`); not part of the SQL graph.

## Rollback (whole feature)

```sql
DROP FUNCTION IF EXISTS home_ai.column_consumers(text, text);
DROP VIEW     IF EXISTS home_ai.v_view_column_deps;
DROP FUNCTION IF EXISTS home_ai.object_dependents(text);
DROP FUNCTION IF EXISTS home_ai.object_dependencies(text);
DROP VIEW     IF EXISTS home_ai.v_object_edges;
DROP VIEW     IF EXISTS home_ai.v_rls_policy_map;
DROP VIEW     IF EXISTS home_ai.v_trigger_map;
DROP VIEW     IF EXISTS home_ai.v_view_deps;
DELETE FROM query_whitelist WHERE slug='sql_lineage';
```
Plus revert `server.py` (remove the `sql_lineage` tool) and recreate `homeai-mcp` from `homeai-mcp:pre-sqlgraph`.
