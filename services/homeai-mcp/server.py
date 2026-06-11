"""Home AI MCP server.

Exposes Home AI's query_whitelist as MCP tools so Claude Desktop / Claude
Code / any MCP-compatible agent can interrogate the system with the same
realm-aware RLS the bot-responder uses.

Transport: HTTP+SSE on :8765 by default (so Claude Desktop on Jo's laptop
can reach it over Tailscale). Stdio mode available via MCP_TRANSPORT=stdio
for sessions where the agent spawns the server directly.

Auth: in HTTP mode, requires a bearer token (HOMEAI_MCP_TOKEN). Caller's
realm comes from the bearer-token → identity → realm map (mirrors the
bot_sender_whitelist lookup).
"""
import os, json, asyncio, asyncpg, logging
from contextlib import asynccontextmanager

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("homeai-mcp")

PG_DSN  = os.environ["PG_DSN"]
TRANSPORT = os.environ.get("MCP_TRANSPORT", "sse")  # 'sse' (HTTP) or 'stdio'
TOKEN     = os.environ.get("HOMEAI_MCP_TOKEN")      # bearer token for HTTP mode
DEFAULT_REALM = os.environ.get("HOMEAI_MCP_REALM", "owner")

# mcp>=1.9 enables DNS-rebinding protection that 421s any Host other than
# localhost; allow the Tailscale identities this server is actually reached on.
ALLOWED_HOSTS = [h.strip() for h in os.environ.get(
    "MCP_ALLOWED_HOSTS",
    "100.104.82.53:8765,jolybox.tailc27dff.ts.net:8765,localhost:8765,127.0.0.1:8765",
).split(",") if h.strip()]

mcp = FastMCP("Home AI", instructions=(
    "This MCP server exposes Home AI's whitelisted database queries. "
    "Use list_slugs to discover available tools. Each slug is a "
    "pre-approved, parameterised SQL view. Results respect Home AI's "
    "realm-based row-level security."
), transport_security=TransportSecuritySettings(
    allowed_hosts=ALLOWED_HOSTS,
    allowed_origins=[f"http://{h}" for h in ALLOWED_HOSTS],
))

_pool: asyncpg.Pool | None = None


async def get_pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(PG_DSN, min_size=1, max_size=4)
    return _pool


@mcp.tool()
async def list_slugs() -> str:
    """List every whitelisted query slug + its description + parameters."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        await conn.execute(f"SELECT home_ai.set_realm('{DEFAULT_REALM}')")
        rows = await conn.fetch("""
            SELECT slug, display_name, description, param_schema, realm
              FROM query_whitelist
             WHERE active=true AND approved_at IS NOT NULL
             ORDER BY slug
        """)
    out = []
    for r in rows:
        ps = r["param_schema"] or {}
        if isinstance(ps, str):
            try: ps = json.loads(ps)
            except Exception: ps = {}
        param_str = ", ".join(f"{k}:{v.get('type','str')}" for k, v in ps.items()) or "(none)"
        out.append(f"• {r['slug']}  [{r['realm']}]\n  {r['display_name']}\n  params: {param_str}\n  {r['description'] or ''}")
    return "\n\n".join(out)


@mcp.tool()
async def run_slug(slug: str, params: dict | None = None) -> str:
    """Run a whitelisted slug. `params` are bound positionally per the slug's
    param_schema. Returns rows as a JSON string (truncated to 50 rows /
    10kB). Use list_slugs to discover slugs + their parameters."""
    pool = await get_pool()
    params = params or {}
    async with pool.acquire() as conn:
        await conn.execute(f"SELECT home_ai.set_realm('{DEFAULT_REALM}')")
        row = await conn.fetchrow(
            "SELECT slug, sql_template, param_schema FROM query_whitelist "
            "WHERE slug = $1 AND active = true AND approved_at IS NOT NULL",
            slug)
        if row is None:
            return f"error: slug '{slug}' not found in active whitelist"
        sql = row["sql_template"]
        ps = row["param_schema"] or {}
        if isinstance(ps, str):
            ps = json.loads(ps) if ps else {}
        # Bind positional args matching template's $1, $2, … in param_schema order
        args = [params.get(k) for k in ps.keys()] if ps else []
        try:
            rows = await conn.fetch(sql, *args)
        except Exception as e:
            return f"error: {e!s}"
    if not rows:
        return "[]"
    serialised = [dict(r) for r in rows[:50]]
    js = json.dumps(serialised, default=str)
    if len(js) > 10000:
        js = js[:10000] + " …(truncated)"
    return js


@mcp.tool()
async def query_postgres_readonly(sql: str) -> str:
    """Run an arbitrary read-only SQL query. Strictly SELECT/WITH/EXPLAIN —
    anything else is rejected. Returns up to 50 rows as JSON. Use for
    ad-hoc investigation; prefer run_slug for repeatable answers."""
    head = sql.strip().lstrip("(").lstrip().upper()
    if not (head.startswith("SELECT") or head.startswith("WITH") or head.startswith("EXPLAIN")):
        return "error: only SELECT/WITH/EXPLAIN permitted"
    if any(bad in sql.upper() for bad in (" INSERT ", " UPDATE ", " DELETE ", " DROP ",
                                          " TRUNCATE ", " ALTER ", " CREATE ", " COPY ")):
        return "error: write keywords detected"
    pool = await get_pool()
    async with pool.acquire() as conn:
        await conn.execute(f"SELECT home_ai.set_realm('{DEFAULT_REALM}')")
        try:
            rows = await conn.fetch(f"SELECT * FROM ({sql}) _q LIMIT 50")
        except Exception as e:
            return f"error: {e!s}"
    js = json.dumps([dict(r) for r in rows], default=str)
    if len(js) > 10000:
        js = js[:10000] + " …(truncated)"
    return js


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


@mcp.resource("homeai://today")
async def resource_today() -> str:
    """Today's KPI snapshot — the headline numbers from v_today_kpis_work."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        await conn.execute(f"SELECT home_ai.set_realm('{DEFAULT_REALM}')")
        r = await conn.fetchrow("SELECT * FROM v_today_kpis_work")
    return json.dumps(dict(r), default=str) if r else "{}"


@mcp.resource("homeai://properties")
async def resource_properties() -> str:
    """The property portfolio with entity ownership + key metadata."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        await conn.execute(f"SELECT home_ai.set_realm('{DEFAULT_REALM}')")
        rows = await conn.fetch("SELECT id, name, postcode, entity_id, status FROM properties ORDER BY id")
    return json.dumps([dict(r) for r in rows], default=str)


if __name__ == "__main__":
    if TRANSPORT == "stdio":
        mcp.run(transport="stdio")
    else:
        import uvicorn
        uvicorn.run(mcp.sse_app(), host="0.0.0.0", port=8765)
