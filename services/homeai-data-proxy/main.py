"""homeai-data-proxy — HTTPS surface for Vercel (or any external client)
to call whitelisted Home AI slugs without exposing Postgres directly.

Fronted by Tailscale Funnel at <jolybox.tailc27dff.ts.net>:443. Bearer-token
auth via HOMEAI_DATA_TOKEN env (set per-deploy from Vault). Only slugs in
query_whitelist (active + approved) are executable. All queries run under
home_ai.set_realm('owner') — same trust model as homeai-mcp.

Endpoints:
  GET /healthz                — public health check
  GET /slug/{slug}            — bearer-protected, returns rows as JSON
"""
import os, asyncio, json, logging
from contextlib import asynccontextmanager

import asyncpg
from fastapi import FastAPI, HTTPException, Header, Query

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("homeai-data-proxy")

PG_DSN = os.environ["PG_DSN"]
TOKEN  = os.environ.get("HOMEAI_DATA_TOKEN")
MAX_ROWS = int(os.environ.get("MAX_ROWS", "200"))

if not TOKEN:
    raise RuntimeError("HOMEAI_DATA_TOKEN must be set")


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.pool = await asyncpg.create_pool(PG_DSN, min_size=1, max_size=16)
    log.info("data-proxy ready (max_rows=%d)", MAX_ROWS)
    yield
    await app.state.pool.close()


app = FastAPI(lifespan=lifespan, title="homeai-data-proxy")


@app.get("/healthz")
async def healthz():
    try:
        async with app.state.pool.acquire() as conn:
            n = await conn.fetchval("SELECT NOW()")
        return {"status": "ok", "db_time": n.isoformat()}
    except Exception as e:
        raise HTTPException(503, f"db unreachable: {e}")


def _check_auth(authorization: str | None):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "missing Bearer token")
    if authorization[7:] != TOKEN:
        raise HTTPException(403, "invalid token")


@app.get("/slug/{slug}")
async def slug(slug: str,
               authorization: str | None = Header(None),
               request: dict = None):
    _check_auth(authorization)
    # Slugs in query_whitelist follow a strict allowlist — looking up the
    # template here means we never run arbitrary SQL even with a valid token.
    from fastapi import Request
    async with app.state.pool.acquire() as conn:
        await conn.execute("SELECT home_ai.set_realm('owner')")
        row = await conn.fetchrow(
            "SELECT sql_template, param_schema FROM query_whitelist "
            "WHERE slug=$1 AND active=true AND approved_at IS NOT NULL", slug)
        if not row:
            raise HTTPException(404, f"slug not found: {slug}")
        return None  # handler rewritten below — fastapi route signature trick


# Re-register with explicit Request injection (FastAPI quirk: can't mix Header + free-form query params with the typed sig above)
from fastapi import Request
app.router.routes = [r for r in app.router.routes if getattr(r, 'path', '') != '/slug/{slug}']


@app.get("/slug/{slug}")
async def run_slug_endpoint(slug: str, request: Request,
                            authorization: str | None = Header(None)):
    _check_auth(authorization)
    qp: dict[str, str] = {k: v for k, v in request.query_params.items()}
    async with app.state.pool.acquire() as conn:
        await conn.execute("SELECT home_ai.set_realm('owner')")
        row = await conn.fetchrow(
            "SELECT sql_template, param_schema FROM query_whitelist "
            "WHERE slug=$1 AND active=true AND approved_at IS NOT NULL", slug)
        if not row:
            raise HTTPException(404, f"slug not found: {slug}")
        sql = row["sql_template"]
        ps = row["param_schema"] or {}
        if isinstance(ps, str):
            ps = json.loads(ps) if ps else {}
        args = [qp.get(k) for k in (ps.keys() if ps else [])]
        try:
            rows = await conn.fetch(sql, *args)
        except Exception as e:
            raise HTTPException(500, f"query failed: {e}")
    out = [dict(r) for r in rows[:MAX_ROWS]]
    # Hand back as JSON — let FastAPI handle datetime/Decimal via str fallback
    from fastapi.responses import JSONResponse
    import datetime, decimal
    def default(o):
        if isinstance(o, (datetime.date, datetime.datetime)): return o.isoformat()
        if isinstance(o, decimal.Decimal): return str(o)
        raise TypeError(f"unserialisable {type(o)}")
    return JSONResponse(content=json.loads(json.dumps(out, default=default)))


@app.post("/sandbox/comments")
async def post_comment(request: Request, authorization: str | None = Header(None)):
    _check_auth(authorization)
    body = await request.json()
    cid = body.get("component_id"); text = body.get("comment_text")
    page = body.get("page_path"); author = body.get("author")
    if not cid or not text:
        raise HTTPException(400, "component_id + comment_text required")
    async with app.state.pool.acquire() as conn:
        r = await conn.fetchrow(
            "INSERT INTO sandbox_comments (component_id, comment_text, author, page_path) "
            "VALUES ($1,$2,$3,$4) RETURNING id, created_at",
            cid, text, author, page)
    return {"id": r["id"], "created_at": r["created_at"].isoformat()}


@app.get("/sandbox/comments")
async def get_comments(request: Request, authorization: str | None = Header(None)):
    _check_auth(authorization)
    qp = request.query_params
    where, args = [], []
    if qp.get("component_id"):
        args.append(qp["component_id"]); where.append(f"component_id = ${len(args)}")
    if qp.get("page_path"):
        args.append(qp["page_path"]); where.append(f"page_path = ${len(args)}")
    sql = ("SELECT id, component_id, comment_text, author, page_path, "
           "created_at::text, resolved_at::text FROM sandbox_comments "
           + ("WHERE " + " AND ".join(where) if where else "")
           + " ORDER BY created_at DESC LIMIT 100")
    async with app.state.pool.acquire() as conn:
        rows = await conn.fetch(sql, *args)
    return [dict(r) for r in rows]
