# n8n Workflow Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Index — straight from n8n's own database tables — which workflow calls which service, reads/writes which DB table, and triggers/calls which other workflow, so debugging an event chain doesn't mean reading 25 opaque workflow JSON blobs.

**Architecture:** Same philosophy as the SQL dependency graph (`2026-06-06-sql-dependency-graph.md`): don't build a store — n8n already keeps every workflow's node graph as JSON in `workflow_entity.nodes` (same `homeai` database). Flatten it into `home_ai.*` views with Postgres JSON operators + light regex. Four reversible, self-testing sprints, each a migration with a paired `DROP`, gated by a self-test asserting a **live-verified fact** (e.g. `Master Router → email-pipeline`, `Gmail Ingest Pipeline` reads `emails`, `P5 EPOS Pipeline` writes `epos_daily`). The SQL-ref view **bridges into the SQL graph**: an n8n table write → `home_ai.object_dependents(table)` → affected views.

**Tech Stack:** PostgreSQL JSON operators (`jsonb_array_elements`, `->>`, `regexp_matches`) over n8n's `workflow_entity` table; `home_ai` schema; `homeai-mcp` (FastMCP, `services/homeai-mcp/server.py`); `query_whitelist` slug table (guarded by the V238 validate_slug trigger).

**Verified facts (live, 2026-06-07):** 25 workflows (22 active); node census — postgres 64, httpRequest 56, code 43, scheduleTrigger 18, webhook 7. `workflow_entity.nodes` is type `json` (must cast `::jsonb`). 7 webhook entry points (bank-csv, email-pipeline, invoice-pipeline, nanny, notify-bridge, prom-alert, report-ingestion). Master Router httpRequest-calls email-pipeline/report-ingestion/nanny/invoice-pipeline.

**Scope notes (held out, documented):** `code` (JS) node bodies are NOT parsed (no AST; would need a JS parser) — only postgres + httpRequest + trigger nodes are indexed. Dynamic n8n-expression URLs (`={{ … }}`) are captured raw and flagged `is_dynamic`, not resolved. SQL table extraction is regex-based and **filtered to real `public` tables** to drop false positives; it does not parse CTEs/subquery aliases.

---

## Conventions used by every task

- **Migrations** live in `postgres/migrations/Vxxx__name.sql`. Latest existing is **V241**; this plan adds **V242–V245**. Each wraps DDL in `BEGIN; … COMMIT;` and documents its `DROP` reversal in a header comment.
- **Source table caveat:** we read `workflow_entity.nodes` (the current saved definition shown in the n8n UI). Note the known runtime subtlety ([[feedback_n8n_workflow_history_runtime]]): the *executing* version lives in `workflow_history` via `workflow_entity.activeVersionId`. For a structural registry the saved `workflow_entity.nodes` is the right, simplest source; do NOT switch to `workflow_history` without reason.
- **Apply a migration:**
  ```bash
  cd /home_ai
  PGPW=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)
  docker cp postgres/migrations/Vxxx__name.sql homeai-postgres:/tmp/Vxxx.sql
  docker exec -e PGPASSWORD="$PGPW" homeai-postgres \
    psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f /tmp/Vxxx.sql
  ```
- **Run a self-test:** write SQL to `/tmp/*.sql`, `docker cp` in, `psql -f` (heredocs are unreliable here).
- All objects live in the **`home_ai`** schema, owned by `postgres`, read-only over `workflow_entity` — no realm column, no GRANTs needed.
- The pre-commit entropy hook runs on commit; these diffs are plain SQL/code with no secrets and pass normally. Do **not** use `--no-verify`.

---

## File Structure

| File | Responsibility |
|---|---|
| `postgres/migrations/V242__n8n_registry_core.sql` | `v_n8n_workflows` (inventory) + `v_n8n_http_calls` (service-call edges). |
| `postgres/migrations/V243__n8n_registry_sql_refs.sql` | `v_n8n_sql_refs` (workflow→table refs, regex, real-table-filtered). |
| `postgres/migrations/V244__n8n_registry_chains.sql` | `v_n8n_triggers` (entry points) + `v_n8n_workflow_calls` (workflow→workflow event chain). |
| `postgres/migrations/V245__n8n_registry_slug.sql` | `n8n_workflow` slug into `query_whitelist`. |
| `services/homeai-mcp/server.py` (modify) | `@mcp.tool() n8n_workflow(name)` returning a workflow's services + tables + chain. |

---

## Sprint N1 — workflow inventory + service-call edges (V242)

**Files:**
- Create: `postgres/migrations/V242__n8n_registry_core.sql`
- Test: `/tmp/n1_test.sql` (scratch)

- [ ] **Step 1: Write the migration file**

Create `postgres/migrations/V242__n8n_registry_core.sql`:

```sql
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
```

- [ ] **Step 2: Apply the migration**

```bash
cd /home_ai
PGPW=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)
docker cp postgres/migrations/V242__n8n_registry_core.sql homeai-postgres:/tmp/V242.sql
docker exec -e PGPASSWORD="$PGPW" homeai-postgres \
  psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f /tmp/V242.sql
```
Expected: `BEGIN … CREATE VIEW … CREATE VIEW … COMMIT`, no error.

- [ ] **Step 3: Write the self-test**

Create `/tmp/n1_test.sql`:

```sql
\echo === T1: workflow inventory non-trivial (expect ~25) ===
SELECT count(*) AS workflows, count(*) FILTER (WHERE active) AS active FROM home_ai.v_n8n_workflows;
\echo === T2: Master Router has httpRequest nodes ===
SELECT http_nodes AS must_be_gt_0 FROM home_ai.v_n8n_workflows WHERE name='Master Router';
\echo === T3: a known service-call host resolves (Gmail Ingest Pipeline -> anthropic/ollama/vault) ===
SELECT count(*) AS must_be_ge_1 FROM home_ai.v_n8n_http_calls
WHERE workflow='Gmail Ingest Pipeline' AND host IS NOT NULL;
\echo === T4: dynamic URLs are flagged, not dropped ===
SELECT count(*) AS dynamic_urls FROM home_ai.v_n8n_http_calls WHERE is_dynamic;
```

- [ ] **Step 4: Run the self-test**

```bash
docker cp /tmp/n1_test.sql homeai-postgres:/tmp/n1_test.sql
docker exec -e PGPASSWORD="$PGPW" homeai-postgres psql -U postgres -d homeai -f /tmp/n1_test.sql
```
Expected: T1 workflows ≈ 25 (active ≈ 22); T2 must_be_gt_0 > 0; T3 must_be_ge_1 ≥ 1; T4 dynamic_urls ≥ 0 (informational). If T1–T3 fail, fix the migration before committing.

- [ ] **Step 5: Commit**

```bash
cd /home_ai
git add postgres/migrations/V242__n8n_registry_core.sql
git commit -m "n8n registry N1: workflow inventory + service-call edges (V242)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Sprint N2 — SQL table references + SQL-graph bridge (V243)

**Files:**
- Create: `postgres/migrations/V243__n8n_registry_sql_refs.sql`
- Test: `/tmp/n2_test.sql` (scratch)

- [ ] **Step 1: Write the migration file**

Create `postgres/migrations/V243__n8n_registry_sql_refs.sql`:

```sql
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
```

- [ ] **Step 2: Apply the migration**

```bash
cd /home_ai
PGPW=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)
docker cp postgres/migrations/V243__n8n_registry_sql_refs.sql homeai-postgres:/tmp/V243.sql
docker exec -e PGPASSWORD="$PGPW" homeai-postgres \
  psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f /tmp/V243.sql
```
Expected: `BEGIN … CREATE VIEW … COMMIT`, no error.

- [ ] **Step 3: Write the self-test**

Create `/tmp/n2_test.sql`:

```sql
\echo === T1: Gmail Ingest Pipeline references the emails table (must be >=1) ===
SELECT count(*) AS must_be_ge_1 FROM home_ai.v_n8n_sql_refs
WHERE workflow='Gmail Ingest Pipeline' AND referenced_table='emails';
\echo === T2: P5 EPOS Pipeline writes epos_daily (must be >=1) ===
SELECT count(*) AS must_be_ge_1 FROM home_ai.v_n8n_sql_refs
WHERE workflow='P5 EPOS Pipeline' AND referenced_table='epos_daily';
\echo === T3: every referenced_table is a real public table (must be 0 unknowns) ===
SELECT count(*) AS must_be_0 FROM home_ai.v_n8n_sql_refs r
WHERE NOT EXISTS (SELECT 1 FROM pg_tables t WHERE t.schemaname='public' AND t.tablename=r.referenced_table);
\echo === T4: bridge into the SQL graph — a workflow table maps to downstream views ===
SELECT count(*) AS bridge_rows FROM home_ai.v_n8n_sql_refs r
JOIN LATERAL home_ai.object_dependents(r.referenced_table) d ON true
WHERE r.referenced_table='vendor_invoice_inbox';
```

- [ ] **Step 4: Run the self-test**

```bash
docker cp /tmp/n2_test.sql homeai-postgres:/tmp/n2_test.sql
docker exec -e PGPASSWORD="$PGPW" homeai-postgres psql -U postgres -d homeai -f /tmp/n2_test.sql
```
Expected: T1 ≥ 1; T2 ≥ 1; T3 must_be_0 = 0; T4 bridge_rows ≥ 0 (proves the join to the SQL graph composes). If T1–T3 fail, fix before committing.

- [ ] **Step 5: Commit**

```bash
cd /home_ai
git add postgres/migrations/V243__n8n_registry_sql_refs.sql
git commit -m "n8n registry N2: SQL table references + SQL-graph bridge (V243)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Sprint N3 — triggers + workflow→workflow event chain (V244)

**Files:**
- Create: `postgres/migrations/V244__n8n_registry_chains.sql`
- Test: `/tmp/n3_test.sql` (scratch)

- [ ] **Step 1: Write the migration file**

Create `postgres/migrations/V244__n8n_registry_chains.sql`:

```sql
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
```

- [ ] **Step 2: Apply the migration**

```bash
cd /home_ai
PGPW=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)
docker cp postgres/migrations/V244__n8n_registry_chains.sql homeai-postgres:/tmp/V244.sql
docker exec -e PGPASSWORD="$PGPW" homeai-postgres \
  psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f /tmp/V244.sql
```
Expected: `BEGIN … CREATE VIEW … CREATE VIEW … COMMIT`, no error.

- [ ] **Step 3: Write the self-test**

Create `/tmp/n3_test.sql`:

```sql
\echo === T1: 7 webhook entry points exist ===
SELECT count(*) AS webhook_triggers FROM home_ai.v_n8n_triggers WHERE trigger_type='n8n-nodes-base.webhook';
\echo === T2: the email-pipeline webhook belongs to Gmail Ingest Pipeline ===
SELECT workflow AS must_be_gmail FROM home_ai.v_n8n_triggers
WHERE trigger_type='n8n-nodes-base.webhook' AND detail='email-pipeline';
\echo === T3: Master Router -> email-pipeline (resolved to Gmail Ingest Pipeline) ===
SELECT count(*) AS must_be_1 FROM home_ai.v_n8n_workflow_calls
WHERE caller='Master Router' AND target_path='email-pipeline' AND target='Gmail Ingest Pipeline';
\echo === T4: Master Router fans out to >=4 pipelines ===
SELECT count(*) AS fanout FROM home_ai.v_n8n_workflow_calls WHERE caller='Master Router';
```

- [ ] **Step 4: Run the self-test**

```bash
docker cp /tmp/n3_test.sql homeai-postgres:/tmp/n3_test.sql
docker exec -e PGPASSWORD="$PGPW" homeai-postgres psql -U postgres -d homeai -f /tmp/n3_test.sql
```
Expected: T1 webhook_triggers = 7; T2 must_be_gmail = `Gmail Ingest Pipeline`; T3 must_be_1 = 1; T4 fanout ≥ 4. If any fail, fix before committing.

- [ ] **Step 5: Commit**

```bash
cd /home_ai
git add postgres/migrations/V244__n8n_registry_chains.sql
git commit -m "n8n registry N3: triggers + workflow->workflow event chain (V244)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Sprint N4 — MCP + slug exposure (server.py + V245)

**Files:**
- Modify: `services/homeai-mcp/server.py` (add one `@mcp.tool()` after the `sql_lineage` tool added in the SQL-graph plan)
- Create: `postgres/migrations/V245__n8n_registry_slug.sql`
- Test: `/tmp/n4_test.sql` (scratch) + MCP boot check

- [ ] **Step 1: Read the existing tool pattern**

Run: `sed -n '120,160p' services/homeai-mcp/server.py`
Expected: confirm the `sql_lineage` tool (from the SQL-graph plan) is present, tools are `async def … -> str` using `get_pool()` and `json.dumps(...)`, and `json` is imported. Match this style exactly.

- [ ] **Step 2: Add the `n8n_workflow` MCP tool**

In `services/homeai-mcp/server.py`, immediately after the `sql_lineage` tool, add:

```python
@mcp.tool()
async def n8n_workflow(name: str) -> str:
    """Summarise one n8n workflow: the services its httpRequest nodes call, the
    DB tables its postgres nodes read/write, its triggers, and the workflows it
    calls (event chain). `name` matches workflow_entity.name (exact).
    Returns JSON {services, tables, triggers, calls}."""
    pool = await get_pool()
    async with pool.acquire() as c:
        services = await c.fetch(
            "SELECT node_name, url, is_dynamic, host FROM home_ai.v_n8n_http_calls WHERE workflow = $1 ORDER BY node_name", name)
        tables = await c.fetch(
            "SELECT DISTINCT referenced_table FROM home_ai.v_n8n_sql_refs WHERE workflow = $1 ORDER BY 1", name)
        triggers = await c.fetch(
            "SELECT trigger_type, detail FROM home_ai.v_n8n_triggers WHERE workflow = $1", name)
        calls = await c.fetch(
            "SELECT target_path, target FROM home_ai.v_n8n_workflow_calls WHERE caller = $1 ORDER BY target_path", name)
    return json.dumps({
        "workflow": name,
        "services": [dict(r) for r in services],
        "tables": [r["referenced_table"] for r in tables],
        "triggers": [dict(r) for r in triggers],
        "calls": [dict(r) for r in calls],
    })
```
All four queries pass `name` as the `$1` bind parameter — injection-safe; no string interpolation. Do not change that.

- [ ] **Step 3: Write the slug migration**

Create `postgres/migrations/V245__n8n_registry_slug.sql` (mirror the columns V241 used — it relies on the `intent_examples`/`entity_id`/`result_format` NOT-NULL defaults):

```sql
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
```

- [ ] **Step 4: Apply the slug migration (proves it passes the V238 trigger)**

```bash
cd /home_ai
PGPW=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)
docker cp postgres/migrations/V245__n8n_registry_slug.sql homeai-postgres:/tmp/V245.sql
docker exec -e PGPASSWORD="$PGPW" homeai-postgres \
  psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f /tmp/V245.sql
```
Expected: `INSERT 0 1` (or update) with NO `does not plan` trigger error. If rejected, the template is malformed — fix it.

- [ ] **Step 5: Rebuild + recreate the MCP service**

```bash
cd /home_ai
docker tag $(docker inspect homeai-mcp --format '{{.Config.Image}}') homeai-mcp:pre-n8nreg 2>/dev/null || true
docker compose build homeai-mcp 2>&1 | tail -5
docker compose up -d homeai-mcp 2>&1 | tail -3
sleep 4
docker ps --format '{{.Names}}: {{.Status}}' | grep mcp
```
Expected: `homeai-mcp` shows `Up`. (Rollback: `docker tag homeai-mcp:pre-n8nreg <image> && docker compose up -d homeai-mcp`.)

- [ ] **Step 6: Self-test the slug (DB) and MCP boot (service)**

Create `/tmp/n4_test.sql`:

```sql
\echo === slug registered + active (must be 1) ===
SELECT count(*) AS must_be_1 FROM query_whitelist WHERE slug='n8n_workflow_tables' AND active;
\echo === slug template returns Gmail Ingest Pipeline's tables (must be >=1, includes emails) ===
SELECT count(*) AS must_be_ge_1 FROM home_ai.v_n8n_sql_refs
WHERE workflow='Gmail Ingest Pipeline';
```
Run + MCP boot check:
```bash
docker cp /tmp/n4_test.sql homeai-postgres:/tmp/n4_test.sql
docker exec -e PGPASSWORD="$PGPW" homeai-postgres psql -U postgres -d homeai -f /tmp/n4_test.sql
docker logs homeai-mcp --since 90s 2>&1 | grep -iE 'error|traceback|exception' || echo "MCP booted clean"
```
Expected: must_be_1 = 1; must_be_ge_1 ≥ 1; `MCP booted clean`.

- [ ] **Step 7: Commit**

```bash
cd /home_ai
git add services/homeai-mcp/server.py postgres/migrations/V245__n8n_registry_slug.sql
git commit -m "n8n registry N4: expose via homeai-mcp n8n_workflow tool + slug (V245)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Out of scope (documented, not deferred-by-omission)

- **`code` (JS) node bodies.** Not parsed — no AST available. A workflow whose only DB/service interaction is inside a `code` node will under-report. Revisit only if it proves to be a real blind spot.
- **Dynamic-expression URLs** (`={{ … }}`). Captured raw + flagged `is_dynamic`; the `host` regex is best-effort. No expression evaluation.
- **SQL extraction precision.** Regex-based, filtered to real `public` tables; it will miss tables referenced only via an alias defined elsewhere and won't distinguish read vs write (a follow-up could classify by leading keyword INTO/UPDATE vs FROM/JOIN).
- **`workflow_history` / active-version reconciliation.** We read `workflow_entity.nodes`; reconciling against the runtime `activeVersionId` version is a separate concern ([[feedback_n8n_workflow_history_runtime]]).

## Rollback (whole feature)

```sql
DROP VIEW IF EXISTS home_ai.v_n8n_workflow_calls;
DROP VIEW IF EXISTS home_ai.v_n8n_triggers;
DROP VIEW IF EXISTS home_ai.v_n8n_sql_refs;
DROP VIEW IF EXISTS home_ai.v_n8n_http_calls;
DROP VIEW IF EXISTS home_ai.v_n8n_workflows;
DELETE FROM query_whitelist WHERE slug='n8n_workflow_tables';
```
Plus revert `server.py` (remove the `n8n_workflow` tool) and recreate `homeai-mcp` from `homeai-mcp:pre-n8nreg`.
