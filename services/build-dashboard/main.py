"""Home AI build dashboard — command center.

GET /                  → static/index.html
GET /api/snapshot      → live numbers + achievements + debt + tasks + situational
GET /api/recent        → last 20 audit_log entries
GET /api/outcomes      → recent OutcomeObjects (audit_log.ai_parsed) for the registry
GET /api/hardware      → CPU / RAM / disk / GPU / Vault / containers
GET /api/agents        → Ollama loaded models + heatmap data
GET /api/healthz       → liveness

YAML data files live in ./data/ and are re-read on each request.
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import subprocess
import time
from datetime import datetime, timedelta, timezone, date
from pathlib import Path
from typing import Any

import asyncpg
import httpx
import yaml
from fastapi import FastAPI, Query, Request, Body
from fastapi.responses import FileResponse, JSONResponse, HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

ROOT = Path(__file__).parent
DATA = ROOT / "data"
STATIC = ROOT / "static"

PG_DSN = os.environ.get(
    "PG_DSN",
    "postgresql://postgres:postgres@homeai-postgres:5432/homeai",
)
PROM_URL = os.environ.get("PROM_URL", "http://homeai-prometheus:9090")
NETDATA_URL = os.environ.get("NETDATA_URL", "http://host.docker.internal:19999")
VAULT_URL = os.environ.get("VAULT_URL", "http://homeai-vault:8200")
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://homeai-ollama:11434")
N8N_BASE_URL = os.environ.get("N8N_BASE_URL", "http://100.104.82.53:5678")
MONTHLY_BUDGET_GBP = float(os.environ.get("MONTHLY_BUDGET_GBP", "15.0"))

# £/MTok by model (May 2026; USD→GBP at 0.79).
PRICES = {
    "claude-haiku-4-5-20251001":  {"in": 0.80 * 0.79, "out": 4.00 * 0.79},
    "claude-haiku-4-5":           {"in": 0.80 * 0.79, "out": 4.00 * 0.79},
    "claude-sonnet-4-6":          {"in": 3.00 * 0.79, "out": 15.0 * 0.79},
    "claude-opus-4-7":            {"in": 15.0 * 0.79, "out": 75.0 * 0.79},
    "qwen2.5:7b":                 {"in": 0.0,  "out": 0.0},
    "phi4:14b":                   {"in": 0.0,  "out": 0.0},
    "llama3.3:70b":               {"in": 0.0,  "out": 0.0},
}
DEFAULT_PRICE = {"in": 1.00 * 0.79, "out": 5.00 * 0.79}

# ─── Cache ──────────────────────────────────────────────────────
_cache: dict[str, tuple[float, Any]] = {}
CACHE_TTL = 10

async def cached(key: str, fn, ttl: int = CACHE_TTL):
    now = time.time()
    if key in _cache and (now - _cache[key][0]) < ttl:
        return _cache[key][1]
    val = await fn()
    _cache[key] = (now, val)
    return val

# ─── YAML loaders (re-read on each call) ────────────────────────
def _isoify(o):
    """Walk a yaml-loaded structure and convert datetime.date / datetime.datetime
    to ISO strings so the result is JSON-serialisable. YAML literal `2026-05-14`
    becomes a date object by default; we want a string in the API surface."""
    from datetime import date, datetime as _dt
    if isinstance(o, dict):
        return {k: _isoify(v) for k, v in o.items()}
    if isinstance(o, list):
        return [_isoify(v) for v in o]
    if isinstance(o, _dt):
        return o.isoformat()
    if isinstance(o, date):
        return o.isoformat()
    return o

def load_yaml(name: str) -> dict:
    p = DATA / name
    if not p.exists():
        return {}
    return _isoify(yaml.safe_load(p.read_text()) or {})

# ─── Postgres pool ──────────────────────────────────────────────
_pool: asyncpg.Pool | None = None

async def pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(PG_DSN, min_size=1, max_size=4)
    return _pool

# Realm enforcement (R2) — see U52 sprint plan.
# REALM_ENFORCE=0 (default): every request runs as OWNER realm. Behaviour is
# identical to pre-V65: realm_isolation policy's owner branch passes every row.
# REALM_ENFORCE=1: middleware reads X-Realm header (set by Authelia + Caddy
# once R3 lands) and rejects requests missing/with invalid realm. Until R3,
# leave at 0.
from contextvars import ContextVar
_current_realm: ContextVar[str] = ContextVar("current_realm", default="owner")
REALM_ENFORCE = os.environ.get("REALM_ENFORCE", "0") == "1"

async def db_one(sql: str, *args):
    p = await pool()
    async with p.acquire() as c:
        async with c.transaction():
            await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())
            return await c.fetchrow(sql, *args)

async def db_all(sql: str, *args):
    p = await pool()
    async with p.acquire() as c:
        async with c.transaction():
            await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())
            return await c.fetch(sql, *args)

# U84 — for endpoints that need multiple statements in one transaction
# (e.g. action queue resolve, ingest pipeline writes). Acquires a connection,
# sets realm and optional entity, releases on exit. NEVER hold this across
# template rendering or third-party network calls (G3 fix).
from contextlib import asynccontextmanager

@asynccontextmanager
async def db_session(entity: str | None = None):
    """Yields an asyncpg connection with realm + optional entity SET LOCAL.
    The connection is released on context exit — use inside endpoint
    blocks only, never around `await call_next` or template renders."""
    p = await pool()
    async with p.acquire() as c:
        async with c.transaction():
            await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())
            if entity is not None:
                # SET LOCAL takes a literal — use set_config() so parameters work
                await c.execute("SELECT set_config('app.current_entity', $1, true)", str(entity))
            yield c

# ─── Helpers ────────────────────────────────────────────────────
async def http_json(url: str, timeout: float = 4.0) -> Any:
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            r = await client.get(url)
            r.raise_for_status()
            return r.json()
    except Exception:
        return None

# ─── Hardware sensing ───────────────────────────────────────────
def _shell(cmd: list[str], timeout: float = 3.0) -> str:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        return ""

def _gpu_via_nvidia_smi() -> list[dict]:
    raw = _shell(["nvidia-smi",
                  "--query-gpu=name,memory.used,memory.total,temperature.gpu,utilization.gpu,utilization.memory",
                  "--format=csv,noheader,nounits"])
    if not raw:
        return []
    out = []
    for line in raw.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 6:
            continue
        try:
            out.append({
                "name": parts[0],
                "vram_used_mb":  int(parts[1]),
                "vram_total_mb": int(parts[2]),
                "vram_pct":      round(100 * int(parts[1]) / max(int(parts[2]), 1), 1),
                "temp_c":        int(parts[3]),
                "gpu_pct":       int(parts[4]),
                "mem_pct":       int(parts[5]),
            })
        except Exception:
            continue
    return out

def _read_cpu_jiffies(path: str = "/host/proc/stat") -> tuple[int, int]:
    """Returns (idle_jiffies, total_jiffies) from /proc/stat."""
    try:
        with open(path) as f:
            for line in f:
                if line.startswith("cpu "):
                    parts = [int(x) for x in line.split()[1:]]
                    # user, nice, system, idle, iowait, irq, softirq, steal, ...
                    idle = parts[3] + (parts[4] if len(parts) > 4 else 0)
                    total = sum(parts)
                    return idle, total
    except Exception:
        pass
    return 0, 0

async def hardware_snapshot() -> dict:
    # CPU% from /proc/stat — read twice with 1s gap, compute non-idle delta.
    # /host/proc is bind-mounted from the host (see docker-compose.yml).
    cpu_pct = None
    mem_pct = None
    load1 = None
    try:
        i1, t1 = _read_cpu_jiffies()
        await asyncio.sleep(1.0)
        i2, t2 = _read_cpu_jiffies()
        if t2 > t1:
            cpu_pct = round(100 * (1 - (i2 - i1) / (t2 - t1)), 1)
    except Exception:
        pass

    # /host/proc/loadavg
    try:
        with open("/host/proc/loadavg") as f:
            load1 = round(float(f.read().split()[0]), 2)
    except Exception:
        pass

    # /host/proc/meminfo
    try:
        mem = {}
        with open("/host/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":")
                mem[k.strip()] = int(v.strip().split()[0])
        total = mem.get("MemTotal", 1)
        avail = mem.get("MemAvailable", 0)
        mem_pct = round(100 * (1 - avail / max(total, 1)), 1)
    except Exception:
        pass

    # GPU via nvidia-smi (shell). Only present if the dashboard container has
    # access to /usr/bin/nvidia-smi via NVIDIA Container Toolkit; otherwise
    # this returns []. The frontend handles empty gracefully.
    gpu = _gpu_via_nvidia_smi()

    # Disk for /home_ai (mounted in)
    disk_pct = None
    disk_free_gb = None
    try:
        statvfs = os.statvfs("/home_ai")
        total = statvfs.f_blocks * statvfs.f_frsize
        free  = statvfs.f_bavail * statvfs.f_frsize
        if total:
            disk_pct = round(100 * (1 - free / total), 1)
            disk_free_gb = round(free / 1024 / 1024 / 1024, 1)
    except Exception:
        pass

    # Vault seal status
    vault_state = await http_json(f"{VAULT_URL}/v1/sys/seal-status")
    vault = {
        "reachable": vault_state is not None,
        "sealed":    bool(vault_state.get("sealed", True)) if vault_state else None,
        "version":   vault_state.get("version") if vault_state else None,
    }

    # Container health: query Postgres for n8n workflow_entity active count, plus
    # do a docker socket-less liveness via service HTTP probes for the critical few.
    probes = await asyncio.gather(
        http_json(f"{PROM_URL}/api/v1/query?query=up", timeout=3.0),
        http_json(f"http://homeai-pdfplumber:8003/healthcheck",  timeout=2.0),
        http_json(f"http://homeai-markitdown:8004/healthcheck",  timeout=2.0),
        http_json(f"{OLLAMA_URL}/api/version",                   timeout=2.0),
        http_json(f"http://homeai-n8n:5678/healthz",             timeout=2.0),
        return_exceptions=True,
    )
    prom_up, pdfp, mditd, ollama_v, n8n_h = probes
    services = {
        "prometheus":  bool(prom_up and not isinstance(prom_up, Exception) and prom_up.get("data", {}).get("result")),
        "pdfplumber":  bool(pdfp  and not isinstance(pdfp,  Exception) and pdfp.get("status") == "ok"),
        "markitdown":  bool(mditd and not isinstance(mditd, Exception) and mditd.get("status") == "ok"),
        "ollama":      bool(ollama_v and not isinstance(ollama_v, Exception)),
        "n8n":         bool(n8n_h is not None and not isinstance(n8n_h, Exception)) or (n8n_h == {}),
        "postgres":    True,  # if we got here we have a pool
    }

    return {
        "cpu_pct":    cpu_pct,
        "mem_pct":    mem_pct,
        "load1":      load1,
        "disk_pct":   disk_pct,
        "disk_free_gb": disk_free_gb,
        "gpu":        gpu,
        "vault":      vault,
        "services":   services,
    }

# ─── Agent heatmap (Ollama loaded models) ──────────────────────
async def ollama_loaded() -> dict:
    ps = await http_json(f"{OLLAMA_URL}/api/ps", timeout=3.0)
    if not ps:
        return {"reachable": False, "models": []}
    models = []
    for m in ps.get("models", []):
        models.append({
            "name":      m.get("name") or m.get("model"),
            "size_mb":   round((m.get("size") or 0) / 1024 / 1024, 1),
            "size_vram_mb": round((m.get("size_vram") or 0) / 1024 / 1024, 1),
            "expires_at": m.get("expires_at"),
        })
    # Also list installed models for the heatmap
    tags = await http_json(f"{OLLAMA_URL}/api/tags", timeout=3.0)
    installed = []
    if tags:
        for m in tags.get("models", []):
            installed.append({
                "name": m.get("name"),
                "size_mb": round((m.get("size") or 0) / 1024 / 1024, 1),
                "loaded":  any(lm["name"] == m.get("name") for lm in models),
            })
    return {"reachable": True, "models": models, "installed": installed}

# ─── Snapshot computation ───────────────────────────────────────
async def compute_phase1_progress() -> dict:
    p = load_yaml("phase1.yaml")
    cats = p.get("categories", [])
    counts = {"done": 0, "in_progress": 0, "todo": 0, "blocked": 0, "phase2": 0}
    for cat in cats:
        for it in cat.get("items", []):
            if it.get("phase2"):
                counts["phase2"] += 1
                continue
            counts[it.get("status", "todo")] = counts.get(it.get("status", "todo"), 0) + 1
    actionable = counts["done"] + counts["in_progress"] + counts["todo"]
    pct = round(100 * counts["done"] / actionable) if actionable else 0
    return {"percent": pct, "counts": counts, "categories": cats}

async def compute_dynamic_counts() -> dict:
    rows = await db_all("""
        SELECT
          (SELECT count(*) FROM workflow_entity WHERE active = true)        AS active_workflows,
          (SELECT count(*) FROM events)                                     AS events_total,
          (SELECT count(*) FROM events WHERE status='pending')              AS events_pending,
          (SELECT count(*) FROM events WHERE status='processing')           AS events_processing,
          (SELECT count(*) FROM events WHERE status='failed')               AS events_failed,
          (SELECT count(*) FROM dead_letter
            WHERE pipeline != 'system_marker' AND resolved = FALSE)             AS dead_letter,
          (SELECT count(*) FROM emails)                                     AS emails_total,
          (SELECT count(*) FROM bank_transactions)                          AS bank_transactions,
          (SELECT count(*) FROM email_attachments)                          AS email_attachments,
          (SELECT count(*) FROM child_events)                               AS child_events,
          (SELECT count(*) FROM invoices)                                   AS invoices,
          (SELECT count(*) FROM audit_log
            WHERE created_at > NOW() - INTERVAL '24 hours')                 AS audit_24h,
          (SELECT count(*) FROM audit_log
            WHERE created_at > NOW() - INTERVAL '24 hours'
              AND result = 'success')                                       AS audit_24h_success,
          (SELECT count(*) FROM system_alerts
            WHERE status='firing' AND acknowledged = FALSE)                   AS alerts_firing,
          (SELECT count(*)
             FROM pg_inherits i
             JOIN pg_class p ON p.oid = i.inhparent
            WHERE p.relname = 'events')                                     AS event_partitions,
          (SELECT count(*) FROM v_documents_needing_review)                 AS docs_needing_review
    """)
    return dict(rows[0]) if rows else {}

async def compute_migrations_count() -> int:
    mig_dir = Path("/home_ai/postgres/migrations")
    if not mig_dir.exists():
        return 0
    return len(list(mig_dir.glob("V*__*.sql")))

async def compute_alert_rules_count() -> int:
    data = await http_json(f"{PROM_URL}/api/v1/rules")
    if not data:
        return 0
    return sum(len(g.get("rules", [])) for g in data.get("data", {}).get("groups", []))

async def compute_active_alerts() -> list[dict]:
    """Currently-firing alerts from system_alerts + Alertmanager active set."""
    rows = await db_all("""
        SELECT alertname, severity, summary, last_updated_at
          FROM system_alerts
         WHERE status = 'firing'
      ORDER BY last_updated_at DESC
         LIMIT 10
    """)
    return [
        {
            "alertname": r["alertname"],
            "severity":  r["severity"],
            "summary":   r["summary"],
            "since":     r["last_updated_at"].isoformat() if r["last_updated_at"] else None,
        }
        for r in rows
    ]

async def compute_situational() -> dict:
    """Critical-pipeline pulse logic. Returns severity = ok | amber | red.

    Heartbeat source is `execution_entity` (n8n's authoritative execution
    log) rather than `audit_log`, because Master Router doesn't write to
    audit_log when there's no work to do — only when recover_stale_leases
    finds something. execution_entity records every 30s schedule fire.
    """
    state_row = await db_one(
        "SELECT value->>'state' AS state, value->>'paused_reason' AS paused_reason "
        "FROM static_context WHERE key = 'system.state'"
    )
    state = state_row["state"] if state_row else "unknown"
    paused_reason = state_row["paused_reason"] if state_row else None

    last_exec = await db_one(
        'SELECT max("startedAt") AS last FROM execution_entity '
        "WHERE \"workflowId\" = 'test-master-router'"
    )
    last_exec_ts = last_exec["last"] if last_exec else None
    router_age = None
    if last_exec_ts:
        router_age = int((datetime.now(timezone.utc) - last_exec_ts).total_seconds())

    severity = "ok"
    if state == "paused":
        severity = "amber"
    if state == "unknown":
        severity = "red"
    # Master Router fires every 30s; >5 min silence = red
    if router_age is not None and router_age > 300:
        severity = "red"

    return {
        "severity":      severity,
        "system_state":  state,
        "paused_reason": paused_reason,
        "router_age_s":  router_age,
    }

async def compute_last_backup() -> dict:
    log = Path("/home_ai/backups/last-backup.log")
    if not log.exists():
        return {"ago_seconds": None, "iso": None, "exists": False}
    mtime = log.stat().st_mtime
    return {
        "ago_seconds": int(time.time() - mtime),
        "iso": datetime.fromtimestamp(mtime, tz=timezone.utc).isoformat(),
        "exists": True,
    }

def _row_cost_gbp(model: str, prompt_tok: int, completion_tok: int) -> float:
    p = PRICES.get(model, DEFAULT_PRICE)
    return (prompt_tok / 1_000_000.0) * p["in"] + (completion_tok / 1_000_000.0) * p["out"]

async def compute_spend() -> dict:
    rows = await db_all("""
        SELECT model_used, SUM(prompt_tokens)::bigint AS pt, SUM(completion_tokens)::bigint AS ct
          FROM ai_usage
         WHERE timestamp >= date_trunc('month', NOW())
      GROUP BY model_used
    """)
    month_total = sum(_row_cost_gbp(r["model_used"], r["pt"] or 0, r["ct"] or 0) for r in rows)
    rows_all = await db_all(
        "SELECT count(*)::int AS n FROM ai_usage WHERE timestamp >= date_trunc('month', NOW())"
    )
    n_calls = rows_all[0]["n"] if rows_all else 0

    # Velocity: every successful pipeline run avoids ~3 min of human work.
    # Multiply by £20/hr to project savings. This is a heuristic for visibility,
    # not precise accounting.
    velocity_rows = await db_all(
        "SELECT count(*)::int AS n FROM audit_log "
        "WHERE result = 'success' AND created_at >= date_trunc('month', NOW())"
    )
    auto_runs = velocity_rows[0]["n"] if velocity_rows else 0
    minutes_saved = auto_runs * 3
    gbp_saved = round(minutes_saved / 60 * 20, 0)

    return {
        "month_total_gbp": round(month_total, 4),
        "month_calls":     n_calls,
        "monthly_budget_gbp": MONTHLY_BUDGET_GBP,
        "pct_of_budget":   round(100 * month_total / MONTHLY_BUDGET_GBP, 1) if MONTHLY_BUDGET_GBP else 0,
        "velocity_auto_runs": auto_runs,
        "velocity_minutes_saved": minutes_saved,
        "velocity_gbp_saved": gbp_saved,
    }

async def compute_recent_activity(limit: int = 30) -> list[dict]:
    rows = await db_all(f"""
        SELECT id, pipeline, action, result, created_at, ai_worker, ai_model,
               ai_parsed, error_msg
          FROM audit_log
      ORDER BY id DESC
         LIMIT {int(limit)}
    """)
    out = []
    for r in rows:
        # ai_parsed may be jsonb (asyncpg returns dict) or str
        ai_parsed = r["ai_parsed"]
        if isinstance(ai_parsed, str):
            try: ai_parsed = __import__("json").loads(ai_parsed)
            except Exception: ai_parsed = None
        out.append({
            "id":         r["id"],
            "pipeline":   r["pipeline"],
            "action":     r["action"],
            "result":     r["result"],
            "ai_worker":  r["ai_worker"],
            "ai_model":   r["ai_model"],
            "created_at": r["created_at"].isoformat() if r["created_at"] else None,
            "outcome":    ai_parsed,
            "error_msg":  r["error_msg"],
        })
    return out

# ─── App ────────────────────────────────────────────────────────
app = FastAPI(title="Home AI Build Dashboard", version="2.0")
app.mount("/static", StaticFiles(directory=str(STATIC)), name="static")

# Realm middleware: set _current_realm contextvar from X-Realm header when
# REALM_ENFORCE=1, otherwise pin to 'owner'. Health and static paths are
# exempt so liveness checks don't 401 when REALM_ENFORCE=1 without a header.
#
# U84 — UI vocabulary is now [Work | All]. Map at the middleware boundary:
#   X-Realm: all   → DB realm 'owner'   (unfiltered; owner sees everything)
#   X-Realm: work  → DB realm 'work'    (work-only)
#   X-Realm: family → DB realm 'family' (kept for backwards compat with
#                     the Private bucket and existing scripts)
#   X-Realm: owner → DB realm 'owner'   (legacy alias accepted)
_REALM_EXEMPT_PREFIXES = (
    "/api/healthz",
    "/static",
    "/api/documents/ingest-from-paperless",  # U70 — webhook from Paperless, auth'd by shared secret
)

_UI_TO_DB_REALM = {
    "all":    "owner",
    "owner":  "owner",
    "work":   "work",
    "family": "family",
}

# U84 Phase 7: page-view telemetry. We log every nav hit to /work/*, /private/*,
# /build/*, /all, /m, /index, and the legacy detail pages we're considering
# decommissioning. Lets us answer "is anyone still hitting /playground?"
# without guessing.
#
# Skipped: /api/*, /static/*, /healthz/* (high-volume, no decom signal).
_TELEMETRY_LOG_PREFIXES = (
    "/work/", "/private/", "/build/", "/all",
    "/m", "/index", "/finance", "/workforce", "/vehicles", "/dojo",
    "/touchoffice", "/caterbook", "/agents-ops", "/forensics",
    "/reconciliation", "/recon", "/economics", "/invoices", "/tasks",
    "/coverage", "/playground", "/landing", "/pub", "/ask", "/search",
)


async def _log_pageview(path: str, realm: str, status: int, user_agent: str | None):
    """Fire-and-forget page-view log. Failures are swallowed; we never
    block the request on telemetry."""
    try:
        async with db_session() as conn:
            await conn.execute("""
                INSERT INTO audit_log (pipeline, action, record_type, record_id,
                                       result, ai_parsed, realm)
                VALUES ('dashboard-ui', 'page_view', 'route', NULL,
                        $1, $2::jsonb, $3)
            """, str(status),
                 json.dumps({"path": path, "ua": (user_agent or "")[:160]}),
                 _current_realm.get())
    except Exception:
        pass  # Never break the request on telemetry

@app.middleware("http")
async def realm_middleware(request, call_next):
    if not REALM_ENFORCE or any(request.url.path.startswith(p) for p in _REALM_EXEMPT_PREFIXES):
        _current_realm.set("owner")
        return await call_next(request)

    # Two header sources, in order of trust:
    #   1. X-Realm — explicit override (used for testing or manual injection)
    #      Accepts UI vocabulary: 'work' | 'all' | 'family' | 'owner'.
    #   2. Remote-Groups — Authelia forward_auth carries the authenticated
    #      user's group list comma-separated; pick the first valid realm.
    raw = (request.headers.get("X-Realm") or "").strip().lower()
    realm = _UI_TO_DB_REALM.get(raw)
    if not realm:
        groups = (request.headers.get("Remote-Groups") or "").strip()
        for g in (g.strip() for g in groups.split(",")):
            if g in _UI_TO_DB_REALM:
                realm = _UI_TO_DB_REALM[g]
                break
    if not realm:
        return JSONResponse(
            {"error": "missing or invalid realm — no X-Realm and no valid Remote-Groups"},
            status_code=401,
        )
    # Just stash on the contextvar (no DB connection held across the
    # request — per U84 §4 G3 fix; each endpoint acquires + sets realm
    # micro-transactionally inside its own block).
    _current_realm.set(realm)
    response = await call_next(request)

    # U84 Phase 7: page-view telemetry. Skip API + static; only log nav
    # routes. Fire-and-forget so we never add latency to the response.
    path = request.url.path
    if (any(path.startswith(p) for p in _TELEMETRY_LOG_PREFIXES)
            and not path.startswith("/api/")):
        ua = request.headers.get("user-agent")
        try:
            asyncio.create_task(_log_pageview(path, realm, response.status_code, ua))
        except Exception:
            pass
    return response

@app.get("/")
async def root(request: Request):
    """U84 Phase 7: route the unprefixed root to the new IA based on the
    user's persisted realm. Falls back to /work/today if no realm cookie
    is present (the most common entry-point for Jo).
    Old /index Mission Control page is still reachable at /index for
    nostalgia + scripts that depend on it."""
    # Read the cookie set by realm-toggle.js. localStorage is the
    # client-side source of truth but the cookie mirrors it.
    cookie_realm = (request.cookies.get("X-Realm") or "").strip().lower()
    if cookie_realm == "all":
        # 'all' realm: send to /work/today as the primary daily surface.
        # Jo can navigate to /private/today via the IA.
        return RedirectResponse(url="/work/today", status_code=302)
    if cookie_realm == "family":
        return RedirectResponse(url="/private/today", status_code=302)
    # Default: work realm
    return RedirectResponse(url="/work/today", status_code=302)


@app.get("/index")
async def legacy_index():
    """Old Mission Control page. Preserved at /index so existing
    bookmarks and the occasional cron job that hits it still work."""
    return FileResponse(str(STATIC / "index.html"))

@app.get("/api/healthz")
async def healthz():
    """Shallow liveness — selftest checks this at startup."""
    return {"status": "ok"}


@app.get("/api/healthz-deep")
async def healthz_deep():
    """Real health check: probes Postgres + n8n + google-fetch with timeouts.
    Returns per-component status and overall verdict. Dashboard's heartbeat
    indicator should consume this, not /healthz."""
    out: dict[str, Any] = {"checks": {}}
    overall = "ok"

    # Postgres — simple round-trip
    try:
        p = await pool()
        async with p.acquire() as c:
            row = await asyncio.wait_for(c.fetchval("SELECT 1"), timeout=2.0)
        out["checks"]["postgres"] = {"status": "ok"} if row == 1 else {"status": "degraded", "detail": f"got {row!r}"}
    except Exception as e:
        out["checks"]["postgres"] = {"status": "down", "detail": str(e)[:200]}
        overall = "degraded"

    # n8n — its own /healthz
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            r = await client.get("http://homeai-n8n:5678/healthz")
        out["checks"]["n8n"] = {"status": "ok" if r.status_code == 200 else "degraded",
                                 "code": r.status_code}
        if r.status_code != 200 and overall == "ok":
            overall = "degraded"
    except Exception as e:
        out["checks"]["n8n"] = {"status": "down", "detail": str(e)[:200]}
        overall = "degraded"

    # google-fetch — used by gmail-poll-driver
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            r = await client.get("http://google-fetch:8011/healthz")
        out["checks"]["google_fetch"] = {"status": "ok" if r.status_code == 200 else "degraded"}
    except Exception:
        # Not strictly required for dashboard liveness — degrade not fail
        out["checks"]["google_fetch"] = {"status": "down"}

    out["status"] = overall
    return out


@app.get("/api/phases")
async def phases():
    """Phase-gate progress for the master progress bar.
    Reads data/phases.yaml. Computes per-phase % done from gate statuses.
    Status priority: blocked > in_progress > backlog > done."""
    raw = load_yaml("phases.yaml")
    phases_list = raw.get("phases", [])
    out_phases = []
    for ph in phases_list:
        gates = ph.get("gates", [])
        total = len(gates)
        done = sum(1 for g in gates if g.get("status") == "done")
        in_progress = sum(1 for g in gates if g.get("status") == "in_progress")
        blocked = sum(1 for g in gates if g.get("status") == "blocked")
        backlog = total - done - in_progress - blocked

        if blocked > 0 and done < total:
            phase_status = "blocked"
        elif done == total and total > 0:
            phase_status = "done"
        elif in_progress > 0 or done > 0:
            phase_status = "in_progress"
        else:
            phase_status = "backlog"

        pct = round(100 * done / total) if total else 0
        out_phases.append({
            "id": ph.get("id"),
            "name": ph.get("name"),
            "description": ph.get("description"),
            "status": phase_status,
            "percent": pct,
            "counts": {"done": done, "in_progress": in_progress,
                       "blocked": blocked, "backlog": backlog, "total": total},
            "gates": gates,
        })
    return {"phases": out_phases}

@app.get("/api/snapshot")
async def snapshot():
    async def _all():
        progress, dyn, migs, rules, last_bk, spend, alerts, situational = await asyncio.gather(
            compute_phase1_progress(),
            compute_dynamic_counts(),
            compute_migrations_count(),
            compute_alert_rules_count(),
            compute_last_backup(),
            compute_spend(),
            compute_active_alerts(),
            compute_situational(),
        )
        return {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "phase1":      progress,
            "counts":      {**dyn, "migrations": migs, "alert_rules": rules},
            "last_backup": last_bk,
            "spend":       spend,
            "active_alerts": alerts,
            "situational": situational,
            "n8n_base":    N8N_BASE_URL,
            "debt":        load_yaml("debt.yaml").get("items", []),
            "tasks":       load_yaml("tasks.yaml"),
        }
    return JSONResponse(await cached("snapshot", _all))

@app.get("/api/recent")
async def recent():
    return JSONResponse(await cached("recent", lambda: compute_recent_activity()))

@app.get("/api/hardware")
async def hardware():
    return JSONResponse(await cached("hardware", hardware_snapshot, ttl=5))

@app.get("/api/agents")
async def agents():
    return JSONResponse(await cached("agents", ollama_loaded, ttl=8))

# ─── New v3 endpoints ───────────────────────────────────────────

async def compute_velocity_series(days: int = 7) -> list[dict]:
    """Daily velocity (£ saved) for the last N days. Heuristic: 3 min × £20/hr
    per audit_log success row. Velocity is the OPERATIONAL counter — it grows
    as pipelines run successfully."""
    rows = await db_all(f"""
        SELECT date_trunc('day', created_at)::date AS day,
               count(*)::int AS successes
          FROM audit_log
         WHERE result = 'success'
           AND created_at >= NOW() - INTERVAL '{int(days)} days'
      GROUP BY 1
      ORDER BY 1
    """)
    by_day = {r["day"].isoformat(): r["successes"] for r in rows}
    today = datetime.now(timezone.utc).date()
    out = []
    for i in range(days - 1, -1, -1):
        d = (today - timedelta(days=i)).isoformat()
        n = by_day.get(d, 0)
        # 3 min/run * £20/hr = £1/run
        out.append({"day": d, "gbp": float(n)})
    return out

async def compute_context_pressure() -> dict:
    """Token-equivalent size of the 'sovereign memory' files (SPEC + AGENTS).
    Rough estimate: 1 token ≈ 4 chars for English. 200k token cap on
    most Anthropic models."""
    paths = {
        "SPEC.md":  Path("/home_ai/SPEC.md"),
        "AGENTS.md": Path("/home_ai/AGENTS.md"),
        "HOME-AI-STRETCH.md": Path("/home_ai/HOME-AI-STRETCH.md"),
    }
    out = {"files": [], "total_est_tokens": 0, "limit": 200_000, "pct": 0.0}
    total = 0
    for label, p in paths.items():
        if not p.exists():
            continue
        size = p.stat().st_size
        est = size // 4
        total += est
        out["files"].append({
            "name": label,
            "bytes": size,
            "est_tokens": est,
            "lines": sum(1 for _ in p.open()),
        })
    out["total_est_tokens"] = total
    out["pct"] = round(100 * total / out["limit"], 1)
    return out

async def compute_dreaming() -> dict:
    """Current state of Dreaming Workflow H — last run, heuristics file size."""
    last_row = await db_one("""
        SELECT max(created_at) AS last,
               (SELECT ai_parsed FROM audit_log
                 WHERE pipeline='dreaming' ORDER BY id DESC LIMIT 1) AS last_parsed
          FROM audit_log WHERE pipeline = 'dreaming'
    """)
    last_iso = last_row["last"].isoformat() if last_row and last_row["last"] else None

    heuristics_path = Path("/home_ai/storage/dreaming/heuristics.md")
    if not heuristics_path.exists():
        heuristics_path = Path("/home_ai/.claude/dreaming/heuristics.md")
    heur = {"exists": False, "bytes": 0, "preview": ""}
    if heuristics_path.exists():
        text = heuristics_path.read_text()
        heur = {
            "exists": True,
            "bytes": len(text),
            "preview": text[:600],
        }

    # Is dreaming "active" right now? Looking for an in-flight execution
    in_flight = await db_one("""
        SELECT count(*)::int AS n FROM execution_entity
         WHERE "workflowId" = 'dreaming-v1' AND status NOT IN ('success','error')
    """)

    return {
        "last_run":  last_iso,
        "active":    bool(in_flight and in_flight["n"] > 0),
        "heuristics": heur,
    }

@app.get("/api/spend")
async def spend(days: int = Query(7, ge=1, le=90)):
    return JSONResponse(await cached(f"spend_series_{days}",
                                     lambda: compute_velocity_series(days)))

@app.get("/api/context-pressure")
async def context_pressure():
    return JSONResponse(await cached("ctx_pressure", compute_context_pressure, ttl=30))

@app.get("/api/dreaming")
async def dreaming():
    return JSONResponse(await cached("dreaming", compute_dreaming, ttl=15))

# ─── Sovereignty + leaderboard + benchmark control ──────────────

# Approximate token cost (£) for cloud spend savings calculation.
# 1k tokens (mixed in/out) at Anthropic Haiku ~£0.0024/1k → round to £0.01/1k
# for a conservative "saved by going local" estimate per §3 of the brief.
LOCAL_TOKEN_SAVING_GBP_PER_1K = 0.01

async def compute_sovereignty(days: int = 30) -> dict:
    """Local-vs-cloud split + £ saved estimate."""
    rows = await db_all(f"""
        SELECT provider,
               count(*)::int                     AS calls,
               COALESCE(sum(prompt_tokens), 0)   AS in_tok,
               COALESCE(sum(completion_tokens),0) AS out_tok
          FROM ai_usage
         WHERE timestamp >= NOW() - INTERVAL '{int(days)} days'
         GROUP BY provider
    """)
    by_provider = {r["provider"] or "unknown": dict(r) for r in rows}
    local  = by_provider.get("local",      {"calls": 0, "in_tok": 0, "out_tok": 0})
    cloud  = by_provider.get("anthropic",  {"calls": 0, "in_tok": 0, "out_tok": 0})

    # Also pull from audit_log when ai_usage is sparse (so the score isn't 0
    # just because token logging hasn't fully landed yet)
    fallback = await db_all(f"""
        SELECT provider, count(*)::int AS calls
          FROM audit_log
         WHERE created_at >= NOW() - INTERVAL '{int(days)} days'
           AND provider IN ('local','anthropic')
         GROUP BY provider
    """)
    fb_by = {r["provider"]: r["calls"] for r in fallback}
    local_calls = max(local["calls"], fb_by.get("local", 0))
    cloud_calls = max(cloud["calls"], fb_by.get("anthropic", 0))

    total_calls = local_calls + cloud_calls
    sov_pct = round(100 * local_calls / total_calls, 1) if total_calls else 0.0

    local_total_tok = (local["in_tok"] or 0) + (local["out_tok"] or 0)
    saved_gbp = round(local_total_tok / 1000 * LOCAL_TOKEN_SAVING_GBP_PER_1K, 2)

    return {
        "window_days": days,
        "local_calls": local_calls,
        "cloud_calls": cloud_calls,
        "total_calls": total_calls,
        "sovereignty_pct": sov_pct,
        "local_tokens":   local_total_tok,
        "cloud_tokens":   (cloud["in_tok"] or 0) + (cloud["out_tok"] or 0),
        "saved_gbp_estimate": saved_gbp,
    }

async def compute_leaderboard() -> list[dict]:
    """Latest model_scores row per (model, tier), sorted by composite_score desc.
    Includes previous_* columns so the dashboard can render before/after deltas
    from the V20 trigger."""
    rows = await db_all("""
        SELECT DISTINCT ON (model_name, tier)
               model_name, tier,
               composite_score::float, accuracy_score::float,
               speed_score::float, format_score::float,
               avg_speed_tps::float, avg_latency_ms,
               task_count, scored_at,
               previous_composite_score::float AS previous_composite_score,
               previous_accuracy_score::float  AS previous_accuracy_score,
               previous_speed_score::float     AS previous_speed_score,
               previous_format_score::float    AS previous_format_score,
               previous_scored_at
          FROM model_scores
         ORDER BY model_name, tier, scored_at DESC
    """)
    out = [dict(r) for r in rows]
    for r in out:
        for k in ("scored_at", "previous_scored_at"):
            if r.get(k):
                r[k] = r[k].isoformat()
        if r.get("previous_composite_score") is not None and r.get("composite_score") is not None:
            r["delta_composite"] = round(r["composite_score"] - r["previous_composite_score"], 1)
    out.sort(key=lambda r: r.get("composite_score", 0) or 0, reverse=True)
    return out

@app.get("/api/sovereignty")
async def sovereignty(days: int = Query(30, ge=1, le=365)):
    return JSONResponse(await cached(f"sovereignty_{days}",
                                     lambda: compute_sovereignty(days), ttl=10))

@app.get("/api/leaderboard")
async def leaderboard():
    return JSONResponse(await cached("leaderboard", compute_leaderboard, ttl=15))

# ─── 5-tier lifecycle endpoints ─────────────────────────────────

async def compute_lifecycle(days: int = 7) -> dict:
    """Aggregate model_usage_history by context_layer + tier so the dashboard
    can render the dual usage bar (build vs production) and the 5-tier list."""
    rows = await db_all(f"""
        SELECT context_layer, tier, provider, model,
               count(*)::int                    AS calls,
               COALESCE(sum(tokens_in), 0)      AS tok_in,
               COALESCE(sum(tokens_out), 0)     AS tok_out,
               COALESCE(sum(cost_gbp),  0)::float AS cost_gbp,
               max(ts) AS last_seen
          FROM model_usage_history
         WHERE ts >= NOW() - INTERVAL '{int(days)} days'
         GROUP BY context_layer, tier, provider, model
         ORDER BY last_seen DESC
    """)
    layers: dict[str, list[dict]] = {"build": [], "production": [], "migration": []}
    for r in rows:
        d = dict(r)
        if d.get("last_seen"):
            d["last_seen"] = d["last_seen"].isoformat()
        layers.setdefault(d["context_layer"], []).append(d)

    # 5-tier roll-up across both layers
    tier_rows = await db_all(f"""
        SELECT tier,
               count(*)::int                    AS calls,
               COALESCE(sum(cost_gbp),  0)::float AS cost_gbp,
               COALESCE(sum(CASE WHEN provider='local' THEN tokens_in+tokens_out ELSE 0 END), 0) AS local_tokens
          FROM model_usage_history
         WHERE ts >= NOW() - INTERVAL '{int(days)} days'
           AND tier IS NOT NULL
         GROUP BY tier
    """)
    tiers = {r["tier"]: dict(r) for r in tier_rows}

    # Migration log — explicit migration entries OR significant tier-swap events
    mig_rows = await db_all(f"""
        SELECT ts, actor, model, task_summary, metadata
          FROM model_usage_history
         WHERE context_layer = 'migration'
            OR task_summary ILIKE 'migration:%'
            OR task_summary ILIKE 'tier change%'
         ORDER BY ts DESC
         LIMIT 30
    """)
    migrations = []
    for r in mig_rows:
        migrations.append({
            "ts":    r["ts"].isoformat() if r["ts"] else None,
            "actor": r["actor"],
            "model": r["model"],
            "summary": r["task_summary"],
        })

    # Recent activity stream (most recent N — used by the migration log UI)
    recent_rows = await db_all("""
        SELECT ts, context_layer, tier, actor, model, provider,
               task_summary, tokens_in, tokens_out, cost_gbp::float
          FROM model_usage_history
         ORDER BY id DESC
         LIMIT 50
    """)
    recent = [
        {**dict(r), "ts": r["ts"].isoformat() if r["ts"] else None}
        for r in recent_rows
    ]

    return {
        "window_days": days,
        "by_layer":    layers,
        "tiers":       tiers,
        "migrations":  migrations,
        "recent":      recent,
    }

async def compute_5tier_status() -> dict:
    """Walks static_context.model.tiers_v2 + cross-references with
    model_usage_history for MTD activity + cost."""
    cfg_row = await db_one("SELECT value FROM static_context WHERE key='model.tiers_v2'")
    cfg = cfg_row["value"] if cfg_row else {}
    if isinstance(cfg, str):
        import json as _json
        cfg = _json.loads(cfg)

    rows = await db_all("""
        SELECT model,
               count(*)::int AS calls_mtd,
               COALESCE(sum(cost_gbp), 0)::float AS cost_mtd,
               max(ts) AS last_seen
          FROM model_usage_history
         WHERE ts >= date_trunc('month', NOW())
         GROUP BY model
    """)
    by_model = {r["model"]: dict(r) for r in rows}

    out = []
    for tier_key in ["apex", "legacy_apex", "local_logic", "cloud_speed", "local_fast"]:
        tier_cfg = cfg.get(tier_key, {}) if isinstance(cfg, dict) else {}
        model = tier_cfg.get("model") if isinstance(tier_cfg, dict) else None
        stats = by_model.get(model, {}) if model else {}
        out.append({
            "tier":     tier_key,
            "model":    model,
            "provider": tier_cfg.get("provider") if isinstance(tier_cfg, dict) else None,
            "use_for":  tier_cfg.get("use_for")  if isinstance(tier_cfg, dict) else None,
            "calls_mtd": stats.get("calls_mtd", 0),
            "cost_mtd":  round(stats.get("cost_mtd", 0) or 0, 4),
            "last_seen": stats.get("last_seen").isoformat() if stats.get("last_seen") else None,
        })
    return out

@app.get("/api/lifecycle")
async def lifecycle(days: int = Query(7, ge=1, le=90)):
    return JSONResponse(await cached(f"lifecycle_{days}", lambda: compute_lifecycle(days), ttl=10))

@app.get("/api/tiers")
async def tiers():
    return JSONResponse(await cached("tiers", compute_5tier_status, ttl=15))

# ─── VRAM residency: which Ollama model holds VRAM right now ───
async def compute_vram_resident() -> dict:
    """Cross-reference nvidia-smi VRAM totals with Ollama /api/ps loaded models.
    Returns per-model status: 'active' (recently used), 'cached' (loaded but
    idle), 'available' (installed, not loaded). Plus an indication of which
    model is currently 'hot' (highest size_vram_mb in /api/ps)."""
    gpu = _gpu_via_nvidia_smi()
    ps  = await http_json(f"{OLLAMA_URL}/api/ps", timeout=3.0) or {"models": []}
    tags = await http_json(f"{OLLAMA_URL}/api/tags", timeout=3.0) or {"models": []}

    loaded_by_name = {}
    for m in ps.get("models", []):
        name = m.get("name") or m.get("model")
        loaded_by_name[name] = {
            "name":         name,
            "size_mb":      round((m.get("size") or 0) / 1024 / 1024, 1),
            "size_vram_mb": round((m.get("size_vram") or 0) / 1024 / 1024, 1),
            "expires_at":   m.get("expires_at"),
        }

    installed = []
    for m in tags.get("models", []):
        name = m.get("name")
        loaded = loaded_by_name.get(name)
        size_disk_mb = round((m.get("size") or 0) / 1024 / 1024, 1)
        if loaded:
            # Heuristic for active vs cached: expires_at == "0001-..." for keep-alive
            # forever; everything else has a real timestamp. Treat "loaded with
            # non-zero size_vram" as cached; mark 'active' if it's the highest
            # VRAM resident (the most recent + dominant model).
            status = "cached"
            entry = {**loaded, "status": status, "size_disk_mb": size_disk_mb}
        else:
            entry = {"name": name, "size_disk_mb": size_disk_mb,
                     "size_vram_mb": 0, "status": "available"}
        installed.append(entry)

    # Mark hottest loaded model as 'active'
    loaded_sorted = sorted(
        [m for m in installed if m["status"] == "cached"],
        key=lambda m: m.get("size_vram_mb", 0),
        reverse=True
    )
    if loaded_sorted:
        loaded_sorted[0]["status"] = "active"

    return {
        "gpu": gpu[0] if gpu else None,
        "models": installed,
        "loaded_count": len(loaded_by_name),
    }

@app.get("/api/hardware/vram-resident")
async def hardware_vram_resident():
    return JSONResponse(await cached("vram_resident", compute_vram_resident, ttl=5))

# ─── 24h sovereignty trend (per-hour bucket) for sparkline ──────
async def compute_sovereignty_trend(hours: int = 24) -> list[dict]:
    """Per-hour local-vs-cloud call ratio, last N hours."""
    rows = await db_all(f"""
        SELECT date_trunc('hour', created_at) AS bucket,
               count(*) FILTER (WHERE provider = 'local')     AS local_calls,
               count(*) FILTER (WHERE provider = 'anthropic') AS cloud_calls
          FROM audit_log
         WHERE created_at >= NOW() - INTERVAL '{int(hours)} hours'
           AND provider IN ('local','anthropic')
         GROUP BY bucket
         ORDER BY bucket
    """)
    by_bucket = {r["bucket"].replace(tzinfo=timezone.utc).isoformat(): dict(r) for r in rows}
    now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    out = []
    for h in range(hours - 1, -1, -1):
        ts = now - timedelta(hours=h)
        key = ts.isoformat()
        b = by_bucket.get(key, {"local_calls": 0, "cloud_calls": 0})
        total = b["local_calls"] + b["cloud_calls"]
        sov = (100 * b["local_calls"] / total) if total else None
        out.append({
            "hour": ts.isoformat(),
            "local": b["local_calls"],
            "cloud": b["cloud_calls"],
            "sov":   sov,
        })
    return out

@app.get("/api/sovereignty/trend")
async def sovereignty_trend(hours: int = Query(24, ge=1, le=168)):
    return JSONResponse(await cached(f"sov_trend_{hours}",
                                     lambda: compute_sovereignty_trend(hours), ttl=30))

# Benchmark trigger — Quick (webhook) or Deep (docker exec with SSE stream).
import asyncio.subprocess as asp
from fastapi.responses import StreamingResponse

@app.post("/api/benchmark/run")
async def benchmark_run(mode: str = Query("quick", pattern="^(quick|deep)$"),
                        model: str = Query("qwen2.5:7b"),
                        tier: str  = Query("hot", pattern="^(hot|medium|heavy)$")):
    """Quick: trigger the model-evaluator webhook. Deep: not streamable from
    here — use POST /api/benchmark/stream for live STDOUT."""
    if mode == "quick":
        async with httpx.AsyncClient(timeout=180.0) as client:
            r = await client.post("http://homeai-model-evaluator:8008/webhook/model-evaluator-manual")
            return {"mode": "quick", "status_code": r.status_code, "ok": r.status_code == 200}
    else:
        # Don't shell-out from here — point caller at the streaming endpoint
        return {"mode": "deep", "stream_url": f"/api/benchmark/stream?model={model}&tier={tier}"}

# ─────────────────────────────────────────────────────────────────────────────
# U22 — Classifier Playground
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/playground")
async def playground_page():
    return FileResponse(str(STATIC / "playground.html"))


@app.get("/landing")
async def landing_page():
    return FileResponse(str(STATIC / "landing.html"))


@app.post("/api/playground/classify")
async def playground_classify(payload: dict):
    """Run the gmail-ingest-v1 classifier prompt against arbitrary input.
    No DB writes. Returns model raw output + post-heuristic verdict so you can
    iterate on prompt + heuristic without touching production data."""
    from_address = (payload.get("from_address") or "")[:200]
    subject      = (payload.get("subject") or "")[:200]
    body         = (payload.get("body") or "")[:4000]
    model        = (payload.get("model") or "qwen2.5:7b")
    if not body and not subject:
        return JSONResponse({"error": "subject or body required"}, status_code=400)

    # ── Build the same prompt the classifier uses (kept in sync with U14 patch) ──
    system_prompt = (
        "You are an email classification system for Jo, a business owner.\n"
        "Jo runs: The Olde Malthouse pub (Tintagel, Cornwall), a property company (7 properties),\n"
        "and manages personal and family matters.\n\n"
        "Classify into exactly one category:\n"
        "  invoice            — supplier bill REQUESTING payment with line items + a total amount due. Examples: utility bill, supplier invoice, professional services bill. NOT a receipt, NOT a payment-declined notice, NOT a refund.\n"
        "  action-required    — payment declined, login alert, deadline, password reset, anything needing Jo to act now. Includes payment-failure notifications.\n"
        "  report-attachment  — daily/weekly business report (EPOS Z-report, Caterbook occupancy, sales summary).\n"
        "  school-medical     — anything from a school, GP, hospital, or about a child's health/education.\n"
        "  property           — tenant message, repair, viewing, or anything about an Estates property.\n"
        "  pub                — operational pub matters not invoice/report (suppliers ordering, staff, bookings).\n"
        "  fyi                — receipts, marketing, newsletters, non-actionable updates.\n"
        "  junk               — spam, phishing, unsolicited.\n\n"
        "If the email mentions a £ amount but is a RECEIPT, REFUND, or PAYMENT NOTIFICATION (success or failure), it is NOT an invoice — use action-required (failure) or fyi (success).\n\n"
        "Determine entity_id: 1=Trading (pub), 2=Estates (property), 3=Personal, 4=Family\n\n"
        "Return ONLY valid JSON. No markdown. No explanation.\n"
        'Schema: {"category": string, "entity_id": number, "confidence_score": number (0-1), "summary": string (max 100 chars), "requires_human": boolean}'
    )
    user_prompt = f"From: {from_address}\nSubject: {subject}\n\n{body}"

    # ── Call Ollama ────────────────────────────────────────────────────────────
    t0 = time.time()
    raw_response = None
    raw_error    = None
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            r = await client.post(
                "http://homeai-ollama:11434/api/generate",
                json={"model": model, "system": system_prompt, "prompt": user_prompt,
                      "stream": False, "format": "json"},
            )
            r.raise_for_status()
            raw_response = r.json().get("response", "")
    except Exception as e:
        raw_error = str(e)
    duration_ms = int((time.time() - t0) * 1000)

    # ── Parse + apply heuristic (mirrors Parse Ollama Response code) ───────────
    import json as _json
    valid_cats = ['invoice','action-required','report-attachment',
                  'school-medical','property','pub','fyi','junk']
    parsed = None
    parse_error = None
    if raw_response:
        try:
            parsed = _json.loads(raw_response)
        except Exception as e:
            parse_error = str(e)

    category   = (parsed or {}).get("category") if parsed else None
    if category not in valid_cats: category = "fyi"
    entity_id  = (parsed or {}).get("entity_id") if parsed else None
    try: entity_id = int(entity_id) if entity_id in (1,2,3,4) else 3
    except Exception: entity_id = 3
    confidence = (parsed or {}).get("confidence_score") if parsed else None
    try: confidence = max(0.0, min(1.0, float(confidence or 0)))
    except Exception: confidence = 0.0
    summary = str((parsed or {}).get("summary") or "")[:500] if parsed else ""

    # INVOICE_HEURISTIC_v1 — mirrored
    final_category = category
    heuristic_note = None
    if category == 'invoice':
        haystack = (subject + ' ' + body).lower()
        import re as _re
        failure_pat = _re.compile(r"(payment\s+(declined|failed|unsuccessful|rejected|could\s+not))|(card\s+declined)|(unable\s+to\s+process\s+payment)|(transaction\s+failed)")
        receipt_pat = _re.compile(r"(payment\s+received)|(thanks?\s+for\s+your\s+(payment|order))|(your\s+receipt)|(order\s+confirmation)|(refund(ed)?\s+(of|to)\s*£)")
        invoice_pat = _re.compile(r"(amount\s+due)|(payment\s+due)|(invoice\s+number)|(\bvat\b)|(due\s+date)|(please\s+pay)")
        f = bool(failure_pat.search(haystack))
        r = bool(receipt_pat.search(haystack))
        i = bool(invoice_pat.search(haystack))
        if f and not i:
            final_category = 'action-required'
            heuristic_note = 'downgraded invoice→action-required (payment-failure pattern, no invoice keywords)'
        elif r and not i:
            final_category = 'fyi'
            heuristic_note = 'downgraded invoice→fyi (receipt/refund pattern, no invoice keywords)'

    return {
        "input": {"from_address": from_address, "subject": subject,
                  "body_len": len(body), "model": model},
        "ollama": {"duration_ms": duration_ms, "raw_response": raw_response,
                   "raw_error": raw_error, "parse_error": parse_error},
        "parsed": parsed,
        "verdict": {
            "category_from_model": category,
            "final_category":      final_category,
            "entity_id":           entity_id,
            "confidence":          round(confidence, 3),
            "summary":             summary,
            "heuristic_note":      heuristic_note,
        },
    }


# ─────────────────────────────────────────────────────────────────────────────
# U18 — Pub Live Operations Board
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/pub")
async def pub_board():
    return FileResponse(str(STATIC / "pub.html"))


# ─────────────────────────────────────────────────────────────────────────────
# U32 — Unit economics (cross-pipeline view + traffic-light KPIs)
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/economics")
async def economics_page():
    return FileResponse(str(STATIC / "economics.html"))


@app.get("/m")
async def mobile_page():
    return FileResponse(str(STATIC / "m.html"))


# ── U85 Phase D1 — Desktop view (canary) ──────────────────────────
@app.get("/desktop")
async def desktop_root():
    return RedirectResponse(url="/desktop/work/today", status_code=302)


@app.get("/desktop/work/today")
async def desktop_work_today_page():
    return FileResponse(str(STATIC / "desktop-work-today.html"))


@app.get("/desktop/work/docs")
async def desktop_work_docs_page():
    return FileResponse(str(STATIC / "desktop-work-docs.html"))


@app.get("/desktop/work/actions")
async def desktop_work_actions_page():
    return FileResponse(str(STATIC / "desktop-work-actions.html"))


@app.get("/desktop/work/staff")
async def desktop_work_staff_page():
    return FileResponse(str(STATIC / "desktop-work-staff.html"))


@app.get("/desktop/work/email")
async def desktop_work_email_page():
    return FileResponse(str(STATIC / "desktop-work-email.html"))


@app.get("/desktop/work/finance")
async def desktop_work_finance_page():
    return FileResponse(str(STATIC / "desktop-work-finance.html"))


@app.get("/desktop/private/today")
async def desktop_private_today_page():
    return FileResponse(str(STATIC / "desktop-private-today.html"))


@app.get("/desktop/private/docs")
async def desktop_private_docs_page():
    return FileResponse(str(STATIC / "desktop-private-docs.html"))


@app.get("/desktop/private/family")
async def desktop_private_family_page():
    return FileResponse(str(STATIC / "desktop-private-family.html"))


@app.get("/desktop/build/pipelines")
async def desktop_build_pipelines_page():
    return FileResponse(str(STATIC / "desktop-build-pipelines.html"))


@app.get("/desktop/build/models")
async def desktop_build_models_page():
    return FileResponse(str(STATIC / "desktop-build-models.html"))


@app.get("/desktop/build/forensics")
async def desktop_build_forensics_page():
    return FileResponse(str(STATIC / "desktop-build-forensics.html"))


@app.get("/desktop/all")
async def desktop_all_page():
    return FileResponse(str(STATIC / "desktop-all.html"))


# ── U84 Phase 2 — Today screens ───────────────────────────────────
@app.get("/work/today")
async def work_today_page():
    return FileResponse(str(STATIC / "work-today.html"))


@app.get("/private/today")
async def private_today_page():
    return FileResponse(str(STATIC / "private-today.html"))


@app.get("/private/family")
async def private_family_page():
    return FileResponse(str(STATIC / "private-family.html"))


@app.get("/private/email")
async def private_email_page():
    return FileResponse(str(STATIC / "private-email.html"))


@app.get("/private/docs")
async def private_docs_page():
    return FileResponse(str(STATIC / "private-docs.html"))


@app.get("/private/actions")
async def private_actions_page():
    return FileResponse(str(STATIC / "private-actions.html"))


@app.get("/private/more")
async def private_more_page():
    return FileResponse(str(STATIC / "private-more.html"))


# ── U84 Phase 3 — Work · Actions / Docs (page + resolve/snooze API) ─
@app.get("/work/actions")
async def work_actions_page():
    return FileResponse(str(STATIC / "work-actions.html"))


@app.get("/work/docs")
async def work_docs_page():
    return FileResponse(str(STATIC / "work-docs.html"))


@app.get("/work/staff")
async def work_staff_page():
    return FileResponse(str(STATIC / "work-staff.html"))


@app.get("/work/email")
async def work_email_page():
    return FileResponse(str(STATIC / "work-email.html"))


@app.get("/work/finance")
async def work_finance_page():
    return FileResponse(str(STATIC / "work-finance.html"))


@app.get("/work/more")
async def work_more_page():
    return FileResponse(str(STATIC / "work-more.html"))


_ACTION_SOURCES = ("exception", "invoice_review", "bot_instruction", "document_expiry")


@app.post("/api/actions/{source}/{ref}/resolve")
async def actions_resolve(source: str, ref: str, request: Request,
                          body: dict = Body(default={})):
    """Mark an action-queue item resolved. Polymorphic by source.
    Body: {note: '...'}  (note is optional)."""
    if source not in _ACTION_SOURCES:
        return JSONResponse({"error": f"unknown source {source!r}"}, status_code=400)
    note = (body.get("note") or "").strip()[:500]
    resolver = (request.headers.get("Remote-User") or "jo").strip()[:60]

    p = await pool()
    async with p.acquire() as c:
        async with c.transaction():
            await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())

            if source == "exception":
                try:
                    rid = int(ref)
                except ValueError:
                    return JSONResponse({"error": "exception ref must be int"}, status_code=400)
                row = await c.fetchrow("""
                    UPDATE mart.exceptions
                       SET status = 'resolved',
                           resolved_at = now(),
                           resolved_by = $2,
                           resolution_note = COALESCE($3, resolution_note)
                     WHERE id = $1 AND status = 'open'
                     RETURNING id, kind, severity
                """, rid, resolver, note or None)
                if not row:
                    return JSONResponse({"error": "exception not found or already resolved"},
                                        status_code=404)
                return {"resolved": True, "source": source, "ref": ref,
                        "kind": row["kind"], "severity": row["severity"]}

            if source == "invoice_review":
                try:
                    rid = int(ref)
                except ValueError:
                    return JSONResponse({"error": "invoice_review ref must be int"}, status_code=400)
                row = await c.fetchrow("""
                    UPDATE vendor_invoice_inbox
                       SET status = 'extracted'
                     WHERE id = $1 AND status = 'needs_review'
                     RETURNING id, vendor_name, subject
                """, rid)
                if not row:
                    return JSONResponse({"error": "invoice not found or not in needs_review"},
                                        status_code=404)
                return {"resolved": True, "source": source, "ref": ref,
                        "vendor": row["vendor_name"]}

            if source == "bot_instruction":
                try:
                    rid = int(ref)
                except ValueError:
                    return JSONResponse({"error": "bot_instruction ref must be int"}, status_code=400)
                row = await c.fetchrow("""
                    UPDATE bot_instructions
                       SET status = 'done'
                     WHERE id = $1 AND status = 'pending'
                     RETURNING id, raw_subject
                """, rid)
                if not row:
                    return JSONResponse({"error": "instruction not found or not pending"},
                                        status_code=404)
                return {"resolved": True, "source": source, "ref": ref}

            if source == "document_expiry":
                return JSONResponse(
                    {"error": "document_expiry resolves on renewal — update the document directly"},
                    status_code=400)

    return JSONResponse({"error": "unreachable"}, status_code=500)


@app.post("/api/actions/{source}/{ref}/snooze")
async def actions_snooze(source: str, ref: str, request: Request,
                         body: dict = Body(default={})):
    """Snooze an action until a given date. For mart.exceptions only at first
    (other sources don't have a snooze field). Body: {until: 'YYYY-MM-DD'}."""
    if source != "exception":
        return JSONResponse({"error": f"snooze not supported for source {source!r}"},
                            status_code=400)
    until_raw = (body.get("until") or "").strip()
    if not until_raw:
        return JSONResponse({"error": "until date required (YYYY-MM-DD)"}, status_code=400)
    try:
        from datetime import date as _date
        until = _date.fromisoformat(until_raw)
    except ValueError:
        return JSONResponse({"error": "until must be ISO date"}, status_code=400)
    try:
        rid = int(ref)
    except ValueError:
        return JSONResponse({"error": "exception ref must be int"}, status_code=400)

    p = await pool()
    async with p.acquire() as c:
        async with c.transaction():
            await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())
            row = await c.fetchrow("""
                UPDATE mart.exceptions
                   SET status = 'suppressed',
                       resolution_note = COALESCE(resolution_note,'') ||
                                         E'\nsnoozed to ' || $2::text
                 WHERE id = $1 AND status = 'open'
                 RETURNING id
            """, rid, until.isoformat())
            if not row:
                return JSONResponse({"error": "exception not found or already closed"},
                                    status_code=404)
            return {"snoozed": True, "source": source, "ref": ref, "until": until.isoformat()}


# ── U84 Phase 5 — Build hub ───────────────────────────────────────
@app.get("/build/pipelines")
async def build_pipelines_page():
    return FileResponse(str(STATIC / "build-pipelines.html"))


@app.get("/build/models")
async def build_models_page():
    return FileResponse(str(STATIC / "build-models.html"))


@app.get("/build/forensics")
async def build_forensics_page():
    return FileResponse(str(STATIC / "build-forensics.html"))


# ── U84 Phase 6 — /all sitemap ────────────────────────────────────
@app.get("/all")
async def all_sitemap_page():
    return FileResponse(str(STATIC / "all-sitemap.html"))


@app.get("/api/all/sitemap")
async def all_sitemap():
    """Sitemap: every GET route + every approved slug + every public view.
    Used by /all page for discoverability."""
    # Routes
    pages = []
    for r in app.routes:
        # FastAPI route objects vary; only include those with a path + GET method
        path = getattr(r, "path", None)
        methods = getattr(r, "methods", None) or set()
        if not path or "GET" not in methods:
            continue
        if path.startswith("/api/") or path.startswith("/static") or path == "/openapi.json":
            continue
        if path in ("/docs", "/redoc"):
            continue
        if "{" in path:  # parameterised — skip from sitemap
            continue
        pages.append({"path": path})
    pages = sorted({p["path"] for p in pages})
    pages = [{"path": p} for p in pages]

    # Slugs + views
    p_ = await pool()
    async with p_.acquire() as c:
        async with c.transaction():
            await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())
            slug_rows = await c.fetch("""
                SELECT slug, display_name, description, realm
                FROM query_whitelist
                WHERE active = true AND approved_at IS NOT NULL
                ORDER BY slug
            """)
            view_rows = await c.fetch("""
                SELECT schemaname, viewname
                FROM pg_views
                WHERE schemaname IN ('public','mart')
                  AND viewname LIKE 'v_%'
                ORDER BY schemaname, viewname
            """)

    return {
        "pages": pages,
        "slugs": [
            {"slug": r["slug"], "display_name": r["display_name"],
             "description": r["description"], "realm": r["realm"]}
            for r in slug_rows
        ],
        "views": [
            {"schema": r["schemaname"], "name": r["viewname"]}
            for r in view_rows
        ],
    }


@app.get("/api/all/search")
async def all_search(q: str = ""):
    """Search the sitemap. Trgm similarity over page paths, slug names,
    view names. Returns top 20 ranked."""
    q = (q or "").strip().lower()
    if len(q) < 2:
        return {"results": []}

    p_ = await pool()
    results: list[dict] = []
    async with p_.acquire() as c:
        async with c.transaction():
            await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())
            # Slugs by similarity
            slug_rows = await c.fetch("""
                SELECT slug, display_name, description,
                       greatest(similarity(slug, $1),
                                similarity(coalesce(display_name,''), $1),
                                similarity(coalesce(description,''),  $1)) AS score
                FROM query_whitelist
                WHERE active = true AND approved_at IS NOT NULL
                ORDER BY score DESC NULLS LAST
                LIMIT 10
            """, q)
            for r in slug_rows:
                if (r["score"] or 0) < 0.1:
                    continue
                results.append({
                    "kind": "slug", "label": r["slug"],
                    "detail": r["display_name"] or r["description"] or "",
                    "score": float(r["score"] or 0),
                    "href": f"/api/finance/slug/{r['slug']}",
                })

            # Views by similarity
            view_rows = await c.fetch("""
                SELECT schemaname, viewname,
                       similarity(viewname, $1) AS score
                FROM pg_views
                WHERE schemaname IN ('public','mart') AND viewname LIKE 'v_%'
                ORDER BY score DESC NULLS LAST
                LIMIT 10
            """, q)
            for r in view_rows:
                if (r["score"] or 0) < 0.1:
                    continue
                results.append({
                    "kind": "view",
                    "label": f"{r['schemaname']}.{r['viewname']}",
                    "detail": "",
                    "score": float(r["score"] or 0),
                    "href": "",
                })

    # Routes by simple substring match
    for r in app.routes:
        path = getattr(r, "path", None)
        if not path or "{" in path or path.startswith("/api/") or path.startswith("/static"):
            continue
        if q in path.lower():
            results.append({
                "kind": "page", "label": path, "detail": "",
                "score": 0.5 if path == "/" + q else 0.3,
                "href": path,
            })

    # De-dupe + sort
    seen = set()
    deduped = []
    for r in sorted(results, key=lambda x: -x["score"]):
        key = (r["kind"], r["label"])
        if key in seen:
            continue
        seen.add(key)
        deduped.append(r)
    return {"results": deduped[:20]}


@app.get("/vehicles")
async def vehicles_page():
    return FileResponse(str(STATIC / "vehicles.html"))


@app.get("/agents-ops")
async def agents_ops_page():
    return FileResponse(str(STATIC / "agents-ops.html"))


@app.get("/api/agents/services")
async def api_agents_services():
    """U72 T3 — health overview of long-running services backed by DB state.
    No docker socket access; signals come from row recency + open queues."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SELECT home_ai.set_realm('work')")
        await c.execute("SET LOCAL app.current_entity = 'all'")

        # bot-responder — last bot_feedback + pending instructions
        bot_last_reply = await c.fetchval(
            "SELECT max(created_at) FROM bot_feedback")
        bot_pending = await c.fetchval(
            "SELECT count(*) FROM bot_instructions WHERE status='pending'")

        # invoice pipeline
        latest_vii = await c.fetchval(
            "SELECT max(received_at) FROM vendor_invoice_inbox")
        vii_pending = await c.fetchval(
            "SELECT count(*) FROM vendor_invoice_inbox WHERE status='new'")

        # paperless ingest activity (last 24h via documents.created_at)
        paperless_last = await c.fetchval(
            "SELECT max(created_at) FROM documents WHERE paperless_id IS NOT NULL")
        paperless_24h = await c.fetchval(
            "SELECT count(*) FROM documents WHERE paperless_id IS NOT NULL "
            "AND created_at > now() - interval '24 hours'")

        # touchoffice
        to_last_scrape = await c.fetchval("SELECT max(scraped_at) FROM touchoffice_scrapes")

        # dojo settlements
        dojo_last_date = await c.fetchval(
            "SELECT max(transaction_date) FROM staging.payments WHERE source='dojo'")

        # critical-listener proxy: open critical exceptions count
        open_critical = await c.fetchval(
            "SELECT count(*) FROM mart.exceptions "
            "WHERE severity='critical' AND status='open'")

        # till reconciliation freshness
        latest_till = await c.fetchval("SELECT max(recon_date) FROM till_reconciliation")

    def _age(dt):
        if dt is None:
            return None
        if isinstance(dt, date) and not isinstance(dt, datetime):
            days = (date.today() - dt).days
            return f"{days}d" if days >= 0 else f"in {-days}d"
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        secs = int((datetime.now(timezone.utc) - dt).total_seconds())
        if secs < 60:    return f"{secs}s"
        if secs < 3600:  return f"{secs//60}m"
        if secs < 86400: return f"{secs//3600}h"
        return f"{secs//86400}d"

    return {
        "services": [
            {"name": "bot-responder",
             "last_action_at": bot_last_reply.isoformat() if bot_last_reply else None,
             "last_action_age": _age(bot_last_reply),
             "queue":   bot_pending or 0,
             "queue_label": "pending instructions"},
            {"name": "invoice-pipeline",
             "last_action_at": latest_vii.isoformat() if latest_vii else None,
             "last_action_age": _age(latest_vii),
             "queue":   vii_pending or 0,
             "queue_label": "unprocessed invoices"},
            {"name": "paperless-ingest",
             "last_action_at": paperless_last.isoformat() if paperless_last else None,
             "last_action_age": _age(paperless_last),
             "queue":   paperless_24h or 0,
             "queue_label": "docs in last 24h"},
            {"name": "touchoffice-scraper",
             "last_action_at": to_last_scrape.isoformat() if to_last_scrape else None,
             "last_action_age": _age(to_last_scrape),
             "queue":   None,
             "queue_label": ""},
            {"name": "dojo-staging",
             "last_action_at": dojo_last_date.isoformat() if dojo_last_date else None,
             "last_action_age": _age(dojo_last_date),
             "queue":   None,
             "queue_label": ""},
            {"name": "critical-listener",
             "last_action_at": None,  # we don't log fires to DB yet
             "last_action_age": None,
             "queue":   open_critical or 0,
             "queue_label": "open critical exceptions"},
            {"name": "till-reconciliation",
             "last_action_at": latest_till.isoformat() if latest_till else None,
             "last_action_age": _age(latest_till),
             "queue":   None,
             "queue_label": ""},
        ],
    }


@app.get("/dojo")
async def dojo_page():
    return FileResponse(str(STATIC / "dojo.html"))


@app.get("/api/dojo/daily")
async def api_dojo_daily(days: int = 90):
    """Per-site Dojo daily totals from v_dojo_daily. WORK realm only —
    OWNER also sees these via the realm policy."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = '1'")
        rows = await c.fetch("""
          SELECT date, site, sales_count, refund_count, declined_count,
                 gross_sales, refunds, tips, cashback,
                 dojo_charges, fee_vat, net_to_bank
            FROM v_dojo_daily
           WHERE date >= CURRENT_DATE - ($1::int)
           ORDER BY date DESC, site
        """, days)
        totals = await c.fetchrow("""
          SELECT
            COUNT(*) FILTER (WHERE transaction_type='Sale'
                               AND transaction_outcome='Authorised')           AS sales_count,
            COUNT(*) FILTER (WHERE transaction_type='Refund'
                               AND transaction_outcome='Authorised')           AS refund_count,
            COALESCE(SUM(transaction_amount) FILTER (WHERE transaction_type='Sale'
                                  AND transaction_outcome='Authorised'),0)     AS gross_sales,
            COALESCE(SUM(transaction_amount) FILTER (WHERE transaction_type='Refund'
                                  AND transaction_outcome='Authorised'),0)     AS refunds,
            COALESCE(SUM(gratuity_amount) FILTER (WHERE transaction_type='Sale'
                                  AND transaction_outcome='Authorised'),0)     AS tips,
            COALESCE(SUM(total_transaction_charge),0)                          AS dojo_charges,
            COALESCE(SUM(fee_vat),0)                                           AS fee_vat,
            MAX(imported_at)::text                                             AS last_import,
            MIN(transaction_date)::text                                        AS earliest,
            MAX(transaction_date)::text                                        AS latest
            FROM dojo_transactions
           WHERE transaction_date >= CURRENT_DATE - ($1::int)
        """, days)

    def _row(r):
        out = {}
        for k, v in dict(r).items():
            if hasattr(v, "isoformat"): out[k] = v.isoformat()
            elif hasattr(v, "to_eng_string"): out[k] = str(v)
            else: out[k] = v
        return out

    return {
        "window_days": days,
        "totals":      _row(totals),
        "rows":        [_row(r) for r in rows],
    }


@app.get("/api/m/mobile")
async def api_m_mobile():
    """Compact roll-up for the phone landing page."""
    from datetime import datetime, timezone
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        flagged_7d = await c.fetchval(
          "SELECT COUNT(*) FROM till_reconciliation WHERE status='flagged' AND recon_date >= CURRENT_DATE - 7")
        latest = await c.fetchval(
          "SELECT MAX(recon_date) FROM till_reconciliation WHERE status='flagged'")
        alerts = await c.fetchval(
          "SELECT COUNT(*) FROM system_alerts WHERE status='firing' AND acknowledged=false")
        pending = await c.fetchval(
          "SELECT COUNT(*) FROM bot_instructions WHERE status='pending'")
        to_last  = await c.fetchval(
          "SELECT MAX(scraped_at) FROM touchoffice_scrapes WHERE success=true")
        cb_last  = await c.fetchval(
          "SELECT MAX(received_at) FROM caterbook_email_reports")
        wf_last  = await c.fetchval(
          "SELECT MAX(started_at) FROM workforce_sync_log WHERE http_status=200")

    def age(ts):
        if ts is None: return None
        now = datetime.now(ts.tzinfo or timezone.utc)
        d = now - ts
        h = int(d.total_seconds() / 3600)
        if h < 1: return f"{int(d.total_seconds()/60)}m"
        if h < 24: return f"{h}h"
        return f"{h//24}d"

    return {
      "flagged_7d": int(flagged_7d or 0),
      "latest_variance_date": latest.isoformat() if latest else "",
      "firing_alerts": int(alerts or 0),
      "pending_instructions": int(pending or 0),
      "ages": {"to": age(to_last), "cb": age(cb_last), "wf": age(wf_last)},
    }


@app.get("/api/kpi/pending-instructions")
async def api_kpi_pending_instructions():
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        n = await c.fetchval("SELECT COUNT(*) FROM bot_instructions WHERE status='pending'")
    return {"pending": int(n or 0)}


_INVOICE_STORAGE_ROOT = "/home_ai/storage/invoices"


@app.get("/api/gp/rolling")
async def api_gp_rolling(date_from: str = "", date_to: str = "",
                         smoothing: int = 14, smoothed: bool = True):
    """U46/U47 — rolling-window GP over any date range. Defaults to last 30 days
    with 14d invoice smoothing (set smoothed=false to compare against raw)."""
    from datetime import date as _date, timedelta as _td
    if not date_from or not date_to:
        t = _date.today(); date_from_d = t - _td(days=30); date_to_d = t
    else:
        date_from_d = _date.fromisoformat(date_from); date_to_d = _date.fromisoformat(date_to)
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        if smoothed:
            row = await c.fetchrow(
              "SELECT * FROM gp_window_smoothed($1::date, $2::date, $3)",
              date_from_d, date_to_d, smoothing,
            )
        else:
            row = await c.fetchrow(
              "SELECT * FROM gp_window($1::date, $2::date)",
              date_from_d, date_to_d,
            )
    if not row:
        return {"window": {"from": date_from_d.isoformat(), "to": date_to_d.isoformat()}, "data": None}
    out = {}
    for k, v in dict(row).items():
        if hasattr(v, "isoformat"): out[k] = v.isoformat()
        elif hasattr(v, "to_eng_string"): out[k] = float(v)
        else: out[k] = v
    # Build per-stream tiles: rev, cost, gp_pct, amber flag
    coverage = out.get("coverage_ratio") or 1.0
    amber = coverage < 0.4
    pub = float(out.get("pub_net_sales") or 0)
    tiles = {
      "drink": {
        "revenue":  round(pub * 0.60, 2),
        "cost":     round(float(out.get("wet_cost") or 0), 2),
        "gp_pct":   out.get("pub_drink_gp_pct"),
        "amber":    amber,
      },
      "food": {
        "revenue":  round(pub * 0.40, 2),
        "cost":     round(float(out.get("dry_cost") or 0), 2),
        "gp_pct":   out.get("pub_food_gp_pct"),
        "amber":    amber,
      },
      "cafe": {
        "revenue":  round(float(out.get("sandwich_net_sales") or 0), 2),
        "cost":     round(float(out.get("cafe_cost") or 0), 2),
        "gp_pct":   out.get("cafe_gp_pct"),
        "no_cost_data": (float(out.get("cafe_cost") or 0) == 0),
        "amber":    amber,
      },
      "overall": {
        "revenue":  round(float(out.get("total_revenue") or 0), 2),
        "cost":     round(float(out.get("total_cost") or 0), 2),
        "gp_pct":   out.get("overall_gp_pct"),
        "amber":    amber,
      },
    }
    return {"data": out, "tiles": tiles, "smoothed": smoothed,
            "coverage_ratio": coverage, "amber_low_coverage": amber}


@app.get("/api/gp/daily")
async def api_gp_daily(date_from: str = "", date_to: str = "", site: str = "all"):
    """U45 — daily GP% series for the invoices header strip.
    Returns one row per date in the window, with drink/food/cafe/overall GP%."""
    from datetime import date as _date, timedelta as _td
    if not date_from or not date_to:
        t = _date.today()
        date_from_d = t - _td(days=14)
        date_to_d   = t
    else:
        date_from_d = _date.fromisoformat(date_from)
        date_to_d   = _date.fromisoformat(date_to)
    date_from = date_from_d.isoformat()
    date_to   = date_to_d.isoformat()
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        rows = await c.fetch("""
          SELECT report_date, pub_net_sales, sandwich_net_sales,
                 wet_cost, dry_cost, cafe_cost, overhead_cost,
                 pub_drink_gp_pct, pub_food_gp_pct, cafe_gp_pct, overall_gp_pct
            FROM v_daily_gp
           WHERE report_date BETWEEN $1::date AND $2::date
           ORDER BY report_date ASC
        """, date_from_d, date_to_d)

    def _row(r):
        out = {}
        for k, v in dict(r).items():
            if hasattr(v, "isoformat"): out[k] = v.isoformat()
            elif hasattr(v, "to_eng_string"): out[k] = float(v)
            else: out[k] = v
        return out
    items = [_row(r) for r in rows]
    # Latest row (today/most recent)
    latest = items[-1] if items else {}
    # Rolling 7-day averages (last 7 with non-null GP per stream)
    def avg(field):
        vals = [r[field] for r in items if r.get(field) is not None][-7:]
        if not vals: return None
        return round(sum(vals) / len(vals), 1)
    return {
        "items": items,
        "latest": latest,
        "rolling_7d": {
            "drink": avg("pub_drink_gp_pct"),
            "food":  avg("pub_food_gp_pct"),
            "cafe":  avg("cafe_gp_pct"),
            "overall": avg("overall_gp_pct"),
        },
        "site": site,
    }


@app.get("/api/classifier/uncertain")
async def api_classifier_uncertain(limit: int = 30):
    """U47a — low-confidence classifier queue. Surfaces emails the AI flagged
    as uncertain so Jo can confirm/correct in one click."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        rows = await c.fetch("""
          SELECT email_id, gmail_message_id, account, from_address, from_name,
                 subject, classification, confidence_score, requires_human,
                 action_required,
                 to_char(received_at,'YYYY-MM-DD HH24:MI') AS received_at,
                 age_days
          FROM v_classifier_uncertain LIMIT $1
        """, limit)
    items = []
    for r in rows:
        d = dict(r)
        if d.get("confidence_score") is not None:
            d["confidence_score"] = float(d["confidence_score"])
        items.append(d)
    return {"items": items, "count": len(items)}


@app.post("/api/classifier/feedback")
async def api_classifier_feedback(body: dict):
    """U47a — Jo submits a correction or confirmation for an uncertain email."""
    email_id = body.get("email_id")
    corrected = (body.get("corrected_class") or "").strip()
    notes = (body.get("notes") or "").strip()
    if not email_id or (not corrected and not notes):
        return {"ok": False, "error": "email_id + (corrected_class or notes) required"}
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        orig = await c.fetchrow(
          "SELECT classification, confidence_score FROM emails WHERE id = $1", email_id
        )
        if not orig:
            return {"ok": False, "error": f"email {email_id} not found"}
        fb_id = await c.fetchval("""
          INSERT INTO bot_feedback
            (email_id, domain, original_class, corrected_class,
             original_conf, notes)
          VALUES ($1, 'classifier', $2, $3, $4, $5)
          RETURNING id
        """, email_id, orig["classification"],
             corrected or orig["classification"],
             orig["confidence_score"], notes or "(confirmed by user)")
    return {"ok": True, "feedback_id": fb_id}


@app.get("/api/email-tasks/open")
async def api_email_tasks_open(limit: int = 30):
    """U46 — open email tasks ranked by urgency (age × severity)."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        rows = await c.fetch("""
          SELECT id, email_id, account, subject, task_type, severity,
                 to_char(detected_at,'YYYY-MM-DD HH24:MI') AS detected_at,
                 due_by, from_address, from_name,
                 to_char(received_at,'YYYY-MM-DD HH24:MI') AS received_at,
                 age_days, urgency_score, days_overdue
          FROM v_email_tasks_open
          LIMIT $1
        """, limit)
    items = []
    for r in rows:
        d = dict(r)
        if d.get("due_by") and hasattr(d["due_by"], "isoformat"):
            d["due_by"] = d["due_by"].isoformat()
        items.append(d)
    return {"items": items, "count": len(items)}


@app.get("/api/weather/5day")
async def api_weather_5day():
    """U46 — 5-day forecast + last-7-day actuals for Mission Control weather tile."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        fc = await c.fetch("""
          SELECT forecast_date, rain_mm, max_temp_c, min_temp_c, max_wind_mph, alert_categories
          FROM v_weather_5day
        """)
        actuals = await c.fetch("""
          SELECT observation_date, hours_sunshine, rain_mm, avg_temp_c, peak_temp_c, max_wind_mph
          FROM weather_daily
          WHERE observation_date >= CURRENT_DATE - 7
          ORDER BY observation_date DESC
        """)
    def _ser(r):
        out = {}
        for k, v in dict(r).items():
            if hasattr(v, "isoformat"): out[k] = v.isoformat()
            elif hasattr(v, "__float__") and not isinstance(v, (int, bool)): out[k] = float(v)
            else: out[k] = v
        return out
    return {
      "forecast": [_ser(r) for r in fc],
      "actuals":  [_ser(r) for r in actuals],
    }


@app.get("/api/invoice/{invoice_id}/pdf")
async def api_invoice_pdf(invoice_id: int):
    """U44 — serve the stored PDF for a vendor_invoice_inbox row.
    Path-traversal guarded: resolves the recorded path and confirms it stays
    inside /home_ai/storage/invoices.
    U61 fallback: when first_attachment_path is NULL the row may still have a
    PDF on disk at /home_ai/data/invoice-pdfs/{id}.pdf (where invoice-pipeline
    drops attachments before vii rows get their path field). Serve from there
    when present."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = '1'")
        path = await c.fetchval(
            "SELECT first_attachment_path FROM vendor_invoice_inbox WHERE id=$1",
            invoice_id,
        )
    if not path:
        fallback = f"/home_ai/data/invoice-pdfs/{invoice_id}.pdf"
        if _os.path.exists(fallback):
            return FileResponse(fallback, media_type="application/pdf",
                                filename=f"{invoice_id}.pdf")
        return JSONResponse({"error": "no PDF on disk for this invoice (may not yet be extracted)"}, status_code=404)
    real = _os.path.realpath(path)
    if not real.startswith(_os.path.realpath(_INVOICE_STORAGE_ROOT) + "/"):
        return JSONResponse({"error": "path traversal blocked"}, status_code=403)
    if not _os.path.exists(real):
        return JSONResponse({"error": "file not found on disk"}, status_code=404)
    return FileResponse(real, media_type="application/pdf",
                        filename=_os.path.basename(real))


# ─────────────────────────────────────────────────────────────────────────────
# U61 T3 — email full-text search across every mailbox
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/search")
async def search_page():
    return FileResponse(str(STATIC / "search.html"))


# ─────────────────────────────────────────────────────────────────────────────
# U61 T6 — feed coverage tile
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/api/coverage/summary")
async def api_coverage_summary():
    rows = await db_all("SELECT * FROM v_feed_coverage_summary")
    return [_isoify(dict(r)) for r in rows]


@app.get("/api/coverage/recent-gaps")
async def api_coverage_recent_gaps(limit: int = Query(50, ge=1, le=500)):
    rows = await db_all(
        "SELECT * FROM v_feed_coverage_recent_gaps LIMIT $1", limit)
    return [_isoify(dict(r)) for r in rows]


@app.get("/coverage")
async def coverage_page():
    return FileResponse(str(STATIC / "coverage.html"))


# ─────────────────────────────────────────────────────────────────────────────
# U64 — FTS research endpoint (vector embeddings in U65)
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/research")
async def research_page():
    return FileResponse(str(STATIC / "research.html"))


async def _ollama_embed(text: str, model: str = "nomic-embed-text",
                          mode: str = "query") -> list[float]:
    """Call homeai-ollama for an embedding. `mode` is 'query' or 'document' —
    nomic-embed-text v1.5 wants task-specific prefixes for sharp retrieval.
    Returns [] on failure."""
    prefix = "search_query: " if mode == "query" else "search_document: "
    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            r = await client.post(
                "http://homeai-ollama:11434/api/embeddings",
                json={"model": model, "prompt": prefix + text[:6000]})
        if r.status_code != 200:
            return []
        return r.json().get("embedding") or []
    except Exception:
        return []


def _cosine(a: list[float], b: list[float]) -> float:
    """Cosine similarity over two equal-length float vectors."""
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sa = sb = 0.0
    for x, y in zip(a, b):
        dot += x * y
        sa  += x * x
        sb  += y * y
    if sa <= 0 or sb <= 0:
        return 0.0
    return dot / ((sa ** 0.5) * (sb ** 0.5))


def _normalise(scores: dict) -> dict:
    """Map dict<id → score> to 0..1 by min/max within the dict."""
    if not scores:
        return {}
    vals = list(scores.values())
    lo, hi = min(vals), max(vals)
    if hi - lo < 1e-9:
        return {k: 1.0 if v > 0 else 0.0 for k, v in scores.items()}
    return {k: (v - lo) / (hi - lo) for k, v in scores.items()}


@app.post("/api/research/ask")
async def api_research_ask(body: dict = Body(...)):
    question = (body.get("question") or "").strip()
    if not question:
        return JSONResponse({"error": "missing 'question'"}, status_code=400)
    sources = body.get("sources") or ["email", "invoice_line", "document"]
    top_k   = int(body.get("top_k") or 12)
    # 50/50 FTS/cosine — nomic-embed-text gives much sharper retrieval than
    # qwen-as-embedding; this default lets the dense pass pull its weight
    # while FTS keeps proper-noun matches honest.
    fts_weight = float(body.get("fts_weight") or 0.5)
    fts_weight = max(0.0, min(1.0, fts_weight))

    anth = await _vault_read("anthropic")
    api_key = (anth or {}).get("api_key")
    if not api_key:
        return JSONResponse({"error": "anthropic key not available"}, status_code=503)

    # ── Lexical (FTS) pass ──────────────────────────────────────────────
    stopwords = {"a","an","and","are","as","at","be","by","for","from","how",
                 "in","is","it","of","on","or","that","the","this","to","was",
                 "were","what","when","where","which","who","why","with","i",
                 "me","my","much","did","do","does","done","have","has","had",
                 "you","your","we","our","tell","show","find","list"}
    terms = [t.strip(".,?!\"'") for t in re.split(r"\s+", question.lower())]
    terms = [t for t in terms if t and len(t) > 2 and t not in stopwords]
    or_query = " | ".join(t.replace(":", "") for t in terms) or question

    fts_rows = await db_all("""
        WITH q AS (SELECT to_tsquery('english', $1) AS tsq)
        SELECT source_table, source_id, title, account, entity_id, realm,
               event_at,
               ts_rank_cd(ts, q.tsq) AS rank,
               ts_headline('english',
                           COALESCE(body, title, ''),
                           q.tsq,
                           'MaxFragments=2, MaxWords=22, MinWords=6, '
                           'StartSel=<<, StopSel=>>') AS snippet
          FROM v_research_corpus, q
         WHERE ts @@ q.tsq
           AND source_table = ANY($2::text[])
         ORDER BY rank DESC, event_at DESC NULLS LAST
         LIMIT 50
    """, or_query, sources)
    fts_by_id  = {(r["source_table"], r["source_id"]): r for r in fts_rows}
    fts_scores = {(r["source_table"], r["source_id"]): float(r["rank"]) for r in fts_rows}

    # ── Dense (vector) pass ─────────────────────────────────────────────
    qvec = await _ollama_embed(question)
    vec_rows = []
    if qvec:
        vec_rows = await db_all("""
            SELECT source_kind AS source_table, source_id, embedding
              FROM search_vectors
             WHERE model = 'nomic-embed-text'
               AND source_kind = ANY($1::text[])
        """, sources)

    vec_scores = {}
    for r in vec_rows:
        emb = r["embedding"]
        if emb:
            vec_scores[(r["source_table"], r["source_id"])] = _cosine(qvec, list(emb))

    # ── Hybrid blend ────────────────────────────────────────────────────
    # Union the candidate set; missing-on-one-side gets 0 on that side.
    candidates = set(fts_scores) | set(vec_scores)
    nf = _normalise(fts_scores)
    nv = _normalise(vec_scores)
    hybrid = {
        k: fts_weight * nf.get(k, 0.0) + (1 - fts_weight) * nv.get(k, 0.0)
        for k in candidates
    }
    top = sorted(hybrid.items(), key=lambda kv: kv[1], reverse=True)[:top_k]

    # Resolve passage records: prefer the FTS row (it has snippet); fall back
    # to a synthesised record from v_research_corpus for vector-only hits.
    missing_ids = [k for k, _ in top if k not in fts_by_id]
    extra_rows = []
    if missing_ids:
        st_array = list({k[0] for k in missing_ids})
        id_array = list({k[1] for k in missing_ids})
        extra_rows = await db_all("""
            SELECT source_table, source_id, title, body, account, entity_id, realm, event_at
              FROM v_research_corpus
             WHERE source_table = ANY($1::text[])
               AND source_id    = ANY($2::bigint[])
        """, st_array, id_array)
    extra_by_id = {(r["source_table"], r["source_id"]): r for r in extra_rows}

    passages = []
    for (st, sid), score in top:
        if (st, sid) in fts_by_id:
            row = dict(fts_by_id[(st, sid)])
        elif (st, sid) in extra_by_id:
            r = extra_by_id[(st, sid)]
            row = dict(r)
            row["rank"]    = 0.0
            row["snippet"] = (r["body"] or r["title"] or "")[:240]
        else:
            continue
        row["hybrid_score"] = round(score, 4)
        row["cosine"]       = round(vec_scores.get((st, sid), 0.0), 4)
        row["fts_rank"]     = round(fts_scores.get((st, sid), 0.0), 4)
        passages.append(_isoify(row))
    if not passages:
        return {
            "question": question, "n_passages": 0, "passages": [],
            "narrative": "No passages matched that query across emails, "
                          "invoice line items, or documents. Try a broader phrase.",
        }

    # Build context for Sonnet
    ctx_lines = []
    for i, p in enumerate(passages, 1):
        ctx_lines.append(
            f"[{i}] ({p['source_table']}#{p['source_id']}) "
            f"{p.get('event_at') or ''} {p['title'] or ''}\n"
            f"    snippet: {p['snippet']}"
        )
    context = "\n".join(ctx_lines)

    system = (
        "You are Jo's research assistant. You answer questions using ONLY the "
        "passages provided. Always cite passages by their [N] index. If the "
        "passages don't contain the answer, say so plainly — do not invent "
        "facts. Money is in GBP, formatted £x,xxx.xx. Keep the answer to "
        "1-3 short paragraphs."
    )

    payload = {
        "model": "claude-sonnet-4-6",
        "max_tokens": 800,
        "system": system,
        "messages": [{
            "role": "user",
            "content":
                f"Question: {question}\n\nPassages:\n{context}\n\n"
                f"Cite the passages used by their [N] index.",
        }],
    }

    headers = {
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    }
    async with httpx.AsyncClient(timeout=60.0) as client:
        r = await client.post("https://api.anthropic.com/v1/messages",
                              headers=headers, json=payload)
    if r.status_code != 200:
        return JSONResponse(
            {"error": "anthropic API error", "status": r.status_code,
             "body": r.text[:300]},
            status_code=502)
    j = r.json()
    narrative = "".join(b.get("text", "") for b in (j.get("content") or [])
                         if b.get("type") == "text").strip()
    return {
        "question": question,
        "n_passages": len(passages),
        "passages": passages,
        "narrative": narrative or "(no narrative)",
    }


# ─────────────────────────────────────────────────────────────────────────────
# U62 T1 — calendar
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/api/calendar/upcoming")
async def api_calendar_upcoming(days: int = Query(30, ge=1, le=180)):
    rows = await db_all("""
        SELECT id, source_account, title, location, start_at, end_at, all_day,
               organiser_email, realm
          FROM calendar_events
         WHERE start_at >= NOW() - INTERVAL '1 day'
           AND start_at <= NOW() + ($1 || ' days')::interval
           AND status <> 'cancelled'
         ORDER BY start_at ASC
    """, str(days))
    return {"n": len(rows), "rows": [_isoify(dict(r)) for r in rows]}


# ─────────────────────────────────────────────────────────────────────────────
# U62 T2 — tasks
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/tasks")
async def tasks_page():
    return FileResponse(str(STATIC / "tasks.html"))


@app.get("/api/tasks/list")
async def api_tasks_list(status: str = Query("open,in_progress,snoozed")):
    statuses = [s.strip() for s in status.split(",") if s.strip()]
    if not statuses:
        statuses = ["open"]
    rows = await db_all("""
        SELECT * FROM v_tasks_unified
         WHERE status = ANY($1::text[])
    """, statuses)
    return {"n": len(rows), "rows": [_isoify(dict(r)) for r in rows]}


@app.post("/api/tasks/create")
async def api_tasks_create(payload: dict = Body(...)):
    title = (payload.get("title") or "").strip()
    if not title:
        return JSONResponse({"error": "title required"}, status_code=400)
    body     = (payload.get("body") or "").strip() or None
    priority = (payload.get("priority") or "normal").strip()
    due_at   = payload.get("due_at") or None
    realm    = (payload.get("realm") or "owner").strip()
    entity   = payload.get("entity_id")

    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET LOCAL app.current_entity = 'all'")
        await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())
        task_id = await c.fetchval("""
            INSERT INTO tasks (source, title, body, priority, due_at, entity_id, realm)
            VALUES ('manual', $1, $2, $3, $4::timestamptz, $5, $6)
            RETURNING id
        """, title[:500], body, priority, due_at, entity, realm)
    return {"ok": True, "id": task_id}


@app.post("/api/tasks/{task_id}/complete")
async def api_tasks_complete(task_id: int):
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET LOCAL app.current_entity = 'all'")
        await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())
        n = await c.execute("""
            UPDATE tasks
               SET status='done', completed_at=NOW(), updated_at=NOW()
             WHERE id = $1 AND status <> 'done'
        """, task_id)
    return {"ok": True, "updated": n}


@app.post("/api/tasks/{task_id}/snooze")
async def api_tasks_snooze(task_id: int, payload: dict = Body(...)):
    snooze_until = payload.get("snooze_until")
    if not snooze_until:
        return JSONResponse({"error": "snooze_until required (ISO timestamp)"}, status_code=400)
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET LOCAL app.current_entity = 'all'")
        await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())
        await c.execute("""
            UPDATE tasks
               SET status='snoozed', snoozed_until=$2::timestamptz, updated_at=NOW()
             WHERE id = $1
        """, task_id, snooze_until)
    return {"ok": True}


@app.post("/api/tasks/{task_id}/reopen")
async def api_tasks_reopen(task_id: int):
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET LOCAL app.current_entity = 'all'")
        await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())
        await c.execute("""
            UPDATE tasks
               SET status='open', completed_at=NULL, updated_at=NOW()
             WHERE id = $1
        """, task_id)
    return {"ok": True}


# ─────────────────────────────────────────────────────────────────────────────
# U62 T4 — document expiry alerts
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/api/documents/expiry-due")
async def api_documents_expiry_due():
    rows = await db_all("SELECT * FROM v_documents_expiry_due")
    return {"n": len(rows), "rows": [_isoify(dict(r)) for r in rows]}


# ─────────────────────────────────────────────────────────────────────────────
# U67 — reconciliation page (exceptions + drill-in ask + new rule)
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/reconciliation")
async def reconciliation_page():
    return FileResponse(str(STATIC / "reconciliation.html"))


@app.get("/api/reconciliation/exceptions")
async def api_reconciliation_exceptions():
    """Currently-open reconciliation exceptions from:
      * reconciliation_flags  (free-form flags incl. card_dojo_vs_touchoffice)
      * till_reconciliation   (cashing-up variance — status='flagged')
      * v_card_reconciliation (latest mismatch days, summary view)
      * bank_transaction_rules (the active rule registry)
    """
    flags = await db_all("""
        SELECT id, flag_type, description, status, entity_id, realm,
               bank_transaction_id, created_at
          FROM reconciliation_flags
         WHERE status = 'open'
         ORDER BY created_at DESC
         LIMIT 100
    """)
    till = await db_all("""
        SELECT id, recon_date, session, z_reading, card_total,
               cash_counted, expected_cash, variance, variance_pct, status
          FROM till_reconciliation
         WHERE status = 'flagged'
         ORDER BY recon_date DESC
         LIMIT 50
    """)
    card_recon = await db_all("""
        SELECT date, site, touchoffice_card, dojo_gross, delta, status
          FROM v_card_reconciliation
         WHERE status <> 'ok'
         ORDER BY date DESC
         LIMIT 30
    """)
    rules = await db_all("""
        SELECT id, priority, name, description_re, type_in, amount_op,
               amount_value, category, confidence, notes, realm
          FROM bank_transaction_rules
         ORDER BY priority, id
    """)
    return {
        "flags":      [_isoify(dict(r)) for r in flags],
        "till":       [_isoify(dict(r)) for r in till],
        "card_recon": [_isoify(dict(r)) for r in card_recon],
        "rules":      [_isoify(dict(r)) for r in rules],
    }


@app.post("/api/reconciliation/flags/{flag_id}/resolve")
async def api_reconciliation_flag_resolve(flag_id: int, payload: dict = Body(...)):
    note = (payload.get("note") or "").strip()[:1000]
    p = await pool()
    async with p.acquire() as c:
        async with c.transaction():
            await c.execute("SET LOCAL app.current_entity = 'all'")
            await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())
            await c.execute("""
                UPDATE reconciliation_flags
                   SET status = 'resolved',
                       description = description ||
                         E'\n[RESOLVED ' || to_char(NOW(), 'YYYY-MM-DD') ||
                         ' jo] ' || $2
                 WHERE id = $1 AND status = 'open'
            """, flag_id, note or "(no note)")
    return {"ok": True, "id": flag_id}


@app.post("/api/reconciliation/rules")
async def api_reconciliation_rule_create(payload: dict = Body(...)):
    """Insert a new bank_transaction_rules row. Used from /reconciliation UI
    when Jo wants to teach the system how to handle a new pattern."""
    name = (payload.get("name") or "").strip()
    category = (payload.get("category") or "").strip()
    description_re = payload.get("description_re") or None
    type_in_raw = payload.get("type_in")
    if isinstance(type_in_raw, str):
        type_in = [t.strip() for t in type_in_raw.split(",") if t.strip()]
    elif isinstance(type_in_raw, list):
        type_in = type_in_raw
    else:
        type_in = None
    amount_op = payload.get("amount_op") or None
    amount_value = payload.get("amount_value")
    priority = int(payload.get("priority") or 50)
    confidence = float(payload.get("confidence") or 0.9)
    notes = (payload.get("notes") or "").strip() or None
    realm = (payload.get("realm") or _current_realm.get() or "owner").strip()

    if not name or not category:
        return JSONResponse({"error": "name and category required"}, status_code=400)
    valid = {"card_settlement","cash_deposit","customer_payment","vendor_payment",
             "payroll","tax_payment","bank_fee","interest_charged","interest_credit",
             "inter_entity_transfer","direct_debit","loan_repayment",
             "rent_received","rent_paid","transfer_uncategorised","refund","other"}
    if category not in valid:
        return JSONResponse({"error": f"category must be one of: {sorted(valid)}"},
                            status_code=400)

    p = await pool()
    async with p.acquire() as c:
        async with c.transaction():
            await c.execute("SET LOCAL app.current_entity = 'all'")
            await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())
            rule_id = await c.fetchval("""
                INSERT INTO bank_transaction_rules
                    (priority, name, description_re, type_in, amount_op,
                     amount_value, category, confidence, notes, realm)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
                RETURNING id
            """, priority, name, description_re, type_in, amount_op,
                 amount_value, category, confidence, notes, realm)
    return {"ok": True, "id": rule_id}


# ─────────────────────────────────────────────────────────────────────────────
# U66 — whole-system bot ask (used by Telegram free-text + future channels)
# ─────────────────────────────────────────────────────────────────────────────
# Unlike /api/finance/ask (finance-slug subset), this loads EVERY approved
# query_whitelist slug in the caller's realm AND exposes a `queue_instruction`
# tool that drops free-text instructions into bot_instructions for the
# existing bot-responder pipeline.

_RO_POOL: asyncpg.Pool | None = None

async def _ro_pool() -> asyncpg.Pool:
    """Lazy-init pool with homeai_readonly role. Cannot INSERT/UPDATE/DELETE
    (CREATE etc.) — protects free-text SQL from accidentally mutating state.
    Statement timeout 5s, row limit imposed at query time."""
    global _RO_POOL
    if _RO_POOL is not None:
        return _RO_POOL
    sec = await _vault_read("postgres-roles")
    ro_pw = (sec or {}).get("homeai_readonly")
    if not ro_pw:
        raise RuntimeError("homeai_readonly password not in vault")
    dsn = f"postgresql://homeai_readonly:{ro_pw}@homeai-postgres:5432/homeai"
    _RO_POOL = await asyncpg.create_pool(
        dsn, min_size=1, max_size=3,
        server_settings={"statement_timeout": "5000"})
    return _RO_POOL


# Curated table catalog — surfaces the most-useful tables/views to the bot's
# SQL writer. The model can also call describe_table for full column lists.
_BOT_TABLE_CATALOG = """\
FINANCE
  bank_accounts (id, entity_id, bank_name, account_name, account_number, sort_code, account_type, realm)
  bank_transactions (id, bank_account_id, entity_id, transaction_date, description, amount, balance, category, realm)
  card_statements (bank_account_id, statement_date, period_start, period_end, opening_balance, payments_credited, spending_charged, closing_balance, min_payment, credit_limit)
  account_transfers (src_txn_id, dst_txn_id, amount, transfer_date, confidence)
  v_finance_kpis (total_cash_balance, total_credit_card_debt, net_worth, mtd_in/out, interest_paid_12m, fees_paid_12m)
  v_account_balances_now (bank_account_id, account_name, account_type, balance, is_liability, as_of_date)
  v_inter_entity_owings (entity_a_id, entity_b_id, n_transfers, gross_a_to_b, gross_b_to_a, net_flow_a_to_b)

WORKFORCE
  workforce_users (external_id, full_name, preferred_name, email, base_pay_rate, active, hire_date)
  workforce_shifts (user_external_id, location_external_id, shift_date, start_time, end_time, hours_worked, cost_estimate)
  workforce_timesheets (user_external_id, period_start, period_end, hours_total, cost_total)
  staff_meta (user_external_id, hourly_rate_pence, on_cost_pct, role_tags, source)
  v_workforce_shifts_costed (shift_id, user_external_id, shift_date, hours_worked, shift_cost)

SALES
  touchoffice_fixed_totals (site, report_date, totaliser_id, label, quantity, value)
    -- site values: 'malthouse' (pub) | 'sandwich' (cafe)
    -- totaliser_id: 1=NET sales, 2=GROSS Sales, 4=CASH in Drawer,
    -- 6=CREDIT in Drawer, 12=TOTAL in Drawer, 19=Covers
    -- `value` is GBP numeric (NOT pence) for money rows; quantity is count
  touchoffice_department_sales (site, report_date, department, quantity, value)
  touchoffice_plu_sales (site, report_date, plu_id, plu_name, quantity, value)
  dojo_transactions (transaction_date, transaction_time, site, transaction_amount, payment_method, transaction_type, transaction_outcome)
    -- site values for dojo: 'pub' | 'cafe' (NOT malthouse/sandwich)
    -- Use transaction_amount > 0 AND transaction_outcome='Approved' for real takings.
  v_dojo_daily (date, site, n_txns, gross_sales)

ACCOMMODATION
  caterbook_room_nights (ref, room, guest_name, room_type, rate_code, night_date, rate_per_night)
  caterbook_daily_snapshots (snapshot_date, total_in_house, revenue_in_house, arrivals_count, departures_count)
  caterbook_bookings (ref, room, guest_name, arrival_date, departure_date, rate_total)
  v_daily_accom_revenue (date, revenue_gbp, room_nights_sold)

INVOICES & PURCHASES
  vendor_invoice_inbox (id, entity_id, vendor_domain, vendor_name, subject, received_at, amount_seen, invoice_date, has_pdf, site, notes)
  vendor_invoice_lines (invoice_id, line_no, description, qty, unit_price, line_net, canonical_id)
  product_canonical (id, family, name, default_unit)
  v_invoice_lines_resolved (line_id, invoice_id, invoice_date, vendor, canonical_family, canonical_name, qty, line_net)

EMAIL / COMMS
  emails (id, gmail_message_id, account, from_address, subject, received_at, body_text, classification, tsv)
  email_tasks (subject, task_type, severity, due_by, status)
  telegram_outbox (source, severity, body_preview, sent_at, suppressed)
  bot_instructions (id, source, lane, status, raw_subject, raw_text, received_at)

TASKS & CALENDAR
  tasks (id, source, title, body, priority, status, due_at, realm)
  calendar_events (source_account, gcal_event_id, title, start_at, end_at, location)
  v_tasks_unified, v_calendar_upcoming

DOCUMENTS
  documents (id, title, category, file_path, ocr_text, linked_table, linked_id, entity_id, realm)
  v_documents_linked, v_documents_expiry_due

VEHICLES / PROPERTIES / FAMILY
  vehicles (id, registration, make_model, mot_due, insurance_renewal, road_tax_due)
  properties (id, address_line1, postcode_full, purchase_date, purchase_price)
  children (id, name, date_of_birth, school_name)

SYSTEM / SUPPORT
  entities (id, name)
  system_alerts (id, name, severity, status, fired_at, acknowledged)
  audit_log (id, action, source, payload, created_at)
  feed_coverage (feed_name, expected_date, row_count, status)
  events / events_2026_NN (id, event_type, status, payload, created_at)
  dead_letter (id, pipeline, resolved, last_attempt_at)
  ai_usage (provider, model, input_tokens, output_tokens, cost_pence, created_at)

CONVENTIONS
  - Most tables have a `realm` column (owner/work/family/shared). RLS is on.
  - Money columns: numeric(12,2), GBP, unless `_pence` suffix.
  - Dates: YYYY-MM-DD. Timestamps: timestamptz UTC.
  - Joins for workforce: workforce_shifts.user_external_id = workforce_users.external_id.
  - Joins for invoice lines: vendor_invoice_lines.invoice_id = vendor_invoice_inbox.id.
"""


def _is_safe_select(sql: str) -> tuple[bool, str]:
    """Allow SELECT / WITH / EXPLAIN only. Reject anything else."""
    s = sql.strip().rstrip(";").strip()
    if not s:
        return False, "empty"
    head = re.split(r"\s+", s, maxsplit=1)[0].upper()
    if head not in ("SELECT", "WITH", "EXPLAIN"):
        return False, f"only SELECT/WITH/EXPLAIN allowed, got {head}"
    # Reject obviously-destructive keywords even inside CTEs / subqueries.
    bad = re.search(r"\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|TRUNCATE|GRANT|REVOKE|COPY|VACUUM|REINDEX)\b",
                    s, re.I)
    if bad:
        return False, f"contains forbidden keyword: {bad.group(1)}"
    # Reject SET / RESET — the bot must not flip RLS context.
    if re.search(r"\b(SET|RESET)\b\s+(?!LOCAL)", s, re.I):
        return False, "SET/RESET not allowed"
    return True, ""


@app.post("/api/bot/ask")
async def api_bot_ask(body: dict = Body(...)):
    question = (body.get("question") or "").strip()
    channel  = (body.get("channel") or "telegram").strip()
    if not question:
        return JSONResponse({"error": "missing 'question'"}, status_code=400)

    anth = await _vault_read("anthropic")
    api_key = (anth or {}).get("api_key")
    if not api_key:
        return JSONResponse({"error": "anthropic key not available"}, status_code=503)

    caller_realm = _current_realm.get() or "owner"

    # Load every approved slug visible to the caller's realm.
    p = await pool()
    async with p.acquire() as c:
        rows = await c.fetch("""
            SELECT id, slug, display_name, description, intent_examples,
                   sql_template, param_schema, result_format, realm
              FROM query_whitelist
             WHERE active = true AND approved_at IS NOT NULL
               AND ($1 = 'owner' OR realm = $1 OR realm = 'shared')
             ORDER BY slug
        """, caller_realm)
    slugs = []
    for r in rows:
        slugs.append({
            "slug":            r["slug"],
            "display_name":    r["display_name"],
            "description":     r["description"],
            "intent_examples": list(r["intent_examples"] or []),
            "sql_template":    r["sql_template"],
            "param_schema":    (r["param_schema"] if isinstance(r["param_schema"], dict)
                                else json.loads(r["param_schema"] or "{}")),
        })

    # Build tools: one per slug + queue_instruction.
    tools = []
    for s in slugs:
        props, required = {}, []
        for name, spec in (s["param_schema"] or {}).items():
            t = spec.get("type", "string")
            jt = {"int":"integer","float":"number","bool":"boolean",
                  "enum":"string","string":"string","str":"string"}.get(t,"string")
            prop = {"type": jt}
            if "default" in spec:
                prop["description"] = f"default {spec['default']}"
            if spec.get("required"):
                required.append(name)
            props[name] = prop
        tools.append({
            "name": s["slug"],
            "description": (s["description"] or "")
                + (("\nExamples: " + "; ".join(s["intent_examples"]))
                   if s["intent_examples"] else ""),
            "input_schema": {"type":"object","properties":props,"required":required},
        })

    tools.append({
        "name": "describe_table",
        "description":
            "Return the column list (name, type, nullable) for a public-schema "
            "table or view. Use this when you need to know exact column names "
            "before writing run_query SQL.",
        "input_schema": {
            "type":"object",
            "properties":{
                "table":{"type":"string","description":"table or view name (no schema prefix)"},
            },
            "required":["table"],
        },
    })

    tools.append({
        "name": "run_query",
        "description":
            "Run a read-only SELECT (or WITH … SELECT) against the homeai "
            "database. Use this for ANY question that the curated slug tools "
            "above can't answer specifically — e.g. 'how many shifts has Tom "
            "worked', 'top 5 vendors by cost this month', 'which days had "
            "highest pub gross', 'show me the last 5 invoices from St "
            "Austell'. Rules:\n"
            "  - SELECT / WITH / EXPLAIN only. No writes.\n"
            "  - ALWAYS include LIMIT 200 unless aggregating.\n"
            "  - Use the table catalog in the system prompt. Call "
            "describe_table first if unsure of columns.\n"
            "  - Money columns are GBP numeric(12,2) unless `_pence`.\n"
            "  - Sets a 5s statement timeout — keep queries simple.",
        "input_schema": {
            "type":"object",
            "properties":{
                "sql":{"type":"string","description":"the SELECT statement"},
                "purpose":{"type":"string","description":"one-line reason — logged for audit"},
            },
            "required":["sql"],
        },
    })

    tools.append({
        "name": "queue_instruction",
        "description":
            "Queue a free-text instruction for the human operator to action later. "
            "USE THIS only when the user explicitly asks for something to be DONE "
            "(e.g. 'run the touchoffice backfill', 'send Jane an email', 'build "
            "me a new dashboard tile'). Do NOT use for questions — use a data tool "
            "for those. Returns the queued bot_instructions row id.",
        "input_schema": {
            "type":"object",
            "properties":{
                "text":{"type":"string","description":"the user's verbatim instruction"},
                "lane":{"type":"string","enum":["query","data","unknown"],
                        "description":"'data' for write/system actions, 'query' otherwise"},
                "summary":{"type":"string","description":"one-line summary for the queue"},
            },
            "required":["text","summary"],
        },
    })

    system = ("You are jolyboxbot, Jo's whole-system assistant via Telegram. "
              "Jo runs a pub (Atlantic Road Trading), a property company "
              "(Atlantic Road Estates), and family/personal affairs. ALWAYS "
              "use a data tool for questions — never invent figures. The "
              "curated slug tools handle common questions; for deep / "
              "ad-hoc queries, use describe_table then run_query against "
              "the database directly. Use queue_instruction ONLY when Jo "
              "asks for something to be DONE. Keep replies 1-3 short "
              "paragraphs. Money is GBP, format £x,xxx.xx.\n\n"
              "Database table catalog:\n" + _BOT_TABLE_CATALOG)

    messages = [{"role": "user", "content": question}]
    headers = {
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    }
    tool_results = []
    instruction_id = None

    async with httpx.AsyncClient(timeout=90.0) as client:
        for _turn in range(6):
            payload = {
                "model": "claude-sonnet-4-6",
                "max_tokens": 1600,
                "system": system,
                "tools": tools,
                "messages": messages,
            }
            r = await client.post("https://api.anthropic.com/v1/messages",
                                  headers=headers, json=payload)
            if r.status_code != 200:
                return JSONResponse({"error":"anthropic API error",
                                     "status":r.status_code,
                                     "body":r.text[:400]}, status_code=502)
            resp = r.json()
            blocks = resp.get("content") or []
            messages.append({"role":"assistant","content":blocks})

            if resp.get("stop_reason") != "tool_use":
                narrative = "".join(b.get("text","") for b in blocks
                                     if b.get("type")=="text").strip()
                return {"question":question, "channel":channel,
                        "narrative":narrative or "(no narrative)",
                        "tool_results":tool_results,
                        "instruction_id":instruction_id}

            tu_msgs = []
            for tu in [b for b in blocks if b.get("type")=="tool_use"]:
                name = tu.get("name")
                if name == "describe_table":
                    table = ((tu.get("input") or {}).get("table") or "").strip()
                    if not re.match(r"^[a-zA-Z_][a-zA-Z0-9_]*$", table):
                        tu_msgs.append({"type":"tool_result","tool_use_id":tu["id"],
                                        "is_error":True,"content":"bad table name"})
                        continue
                    cols = await db_all("""
                        SELECT column_name, data_type, is_nullable
                          FROM information_schema.columns
                         WHERE table_schema='public' AND table_name=$1
                         ORDER BY ordinal_position
                    """, table)
                    if not cols:
                        tu_msgs.append({"type":"tool_result","tool_use_id":tu["id"],
                                        "content":f"no such table or view: {table}"})
                        continue
                    out = "\n".join(f"  {c['column_name']:30s} {c['data_type']}"
                                     + (" NULL" if c['is_nullable']=='YES' else "")
                                     for c in cols)
                    tu_msgs.append({"type":"tool_result","tool_use_id":tu["id"],
                                    "content":f"Columns of {table}:\n{out}"})
                    tool_results.append({"slug":"describe_table","table":table,
                                          "n_columns":len(cols)})
                    continue

                if name == "run_query":
                    inp = tu.get("input") or {}
                    sql = (inp.get("sql") or "").strip()
                    purpose = (inp.get("purpose") or "")[:300]
                    ok_sql, why = _is_safe_select(sql)
                    if not ok_sql:
                        tu_msgs.append({"type":"tool_result","tool_use_id":tu["id"],
                                        "is_error":True,
                                        "content":f"rejected: {why}"})
                        tool_results.append({"slug":"run_query","sql":sql[:200],
                                              "rejected":why})
                        continue
                    # Add LIMIT if missing (lazy heuristic — skip if aggregating)
                    sql_to_run = sql.rstrip(";").strip()
                    if " LIMIT " not in sql_to_run.upper() \
                            and " GROUP BY " not in sql_to_run.upper() \
                            and " HAVING "   not in sql_to_run.upper():
                        sql_to_run += " LIMIT 200"
                    try:
                        ro = await _ro_pool()
                        async with ro.acquire() as ro_conn:
                            async with ro_conn.transaction(readonly=True):
                                # Pin RLS context for the bot caller.
                                await ro_conn.execute(
                                    "SET LOCAL app.current_entity = 'all'")
                                await ro_conn.execute(
                                    "SELECT home_ai.set_realm($1)", caller_realm)
                                rows = await ro_conn.fetch(sql_to_run)
                        # Audit
                        try:
                            await db_one("""
                                INSERT INTO audit_log
                                    (action, source, payload)
                                VALUES ('bot_run_query', 'api/bot/ask',
                                        jsonb_build_object(
                                          'channel', $1::text,
                                          'sql', $2::text,
                                          'purpose', $3::text,
                                          'n_rows', $4::int))
                            """, channel, sql_to_run, purpose, len(rows))
                        except Exception:
                            pass
                        preview = [_isoify(dict(r)) for r in rows[:50]]
                        tu_msgs.append({"type":"tool_result","tool_use_id":tu["id"],
                                        "content":json.dumps(
                                          {"n_rows":len(rows), "rows":preview},
                                          default=str)[:8000]})
                        tool_results.append({"slug":"run_query",
                                              "sql":sql_to_run[:500],
                                              "n_rows":len(rows),
                                              "rows":preview})
                    except Exception as e:
                        msg = str(e)[:400]
                        tu_msgs.append({"type":"tool_result","tool_use_id":tu["id"],
                                        "is_error":True,
                                        "content":f"SQL error: {msg}"})
                        tool_results.append({"slug":"run_query","sql":sql_to_run[:200],
                                              "error":msg})
                    continue

                if name == "queue_instruction":
                    inp = tu.get("input") or {}
                    text = (inp.get("text") or "").strip()
                    lane = (inp.get("lane") or "data").strip()
                    summary = (inp.get("summary") or "").strip()
                    if not text:
                        tu_msgs.append({"type":"tool_result","tool_use_id":tu["id"],
                                        "is_error":True, "content":"text required"})
                        continue
                    async with p.acquire() as c:
                        async with c.transaction():
                            await c.execute("SET LOCAL app.current_entity = '3'")
                            await c.execute("SELECT home_ai.set_realm($1)", caller_realm)
                            bi_id = await c.fetchval("""
                                INSERT INTO bot_instructions
                                    (source, source_id, from_user, sender_email,
                                     received_at, raw_subject, raw_text,
                                     lane, status, entity_id, realm)
                                VALUES ('telegram', NULL, 'jo-telegram',
                                        'jolyon.sandercock@gmail.com',
                                        now(), $1, $2, $3, 'pending', 3, $4)
                                RETURNING id
                            """, summary[:200], text[:4000], lane, caller_realm)
                    instruction_id = bi_id
                    tool_results.append({"slug":"queue_instruction",
                                          "instruction_id":bi_id,
                                          "lane":lane, "summary":summary})
                    tu_msgs.append({"type":"tool_result","tool_use_id":tu["id"],
                                    "content":json.dumps({"queued_id":bi_id,
                                                          "lane":lane})})
                    continue

                slug_row = next((s for s in slugs if s["slug"] == name), None)
                if not slug_row:
                    tu_msgs.append({"type":"tool_result","tool_use_id":tu["id"],
                                    "is_error":True,"content":f"unknown tool {name!r}"})
                    continue
                ok, bound = _bind_params(slug_row["param_schema"], tu.get("input") or {})
                if not ok:
                    tu_msgs.append({"type":"tool_result","tool_use_id":tu["id"],
                                    "is_error":True,"content":f"param error: {bound}"})
                    continue
                try:
                    run = await _run_slug(slug_row, bound)
                except Exception as e:
                    tu_msgs.append({"type":"tool_result","tool_use_id":tu["id"],
                                    "is_error":True,"content":f"SQL error: {e}"})
                    continue
                tool_results.append(run)
                preview = run["rows"][:30]
                tu_msgs.append({"type":"tool_result","tool_use_id":tu["id"],
                                "content":json.dumps({"n_rows":run["n_rows"],
                                                      "rows":preview},
                                                      default=str)[:7000]})
            messages.append({"role":"user","content":tu_msgs})

    return {"question":question, "channel":channel,
            "narrative":"(tool-loop did not converge in 3 turns)",
            "tool_results":tool_results,
            "instruction_id":instruction_id}


# ─────────────────────────────────────────────────────────────────────────────
# U61 T4 — document upload, OCR, entity linking
# ─────────────────────────────────────────────────────────────────────────────

from fastapi import UploadFile, File
import hashlib as _hashlib

_DOCS_ROOT = "/home_ai/storage/documents"
# OCR-tolerant plate match. Position 3-4 expects digits — but OCR commonly
# reads `1`→`I`, `0`→`O`, `5`→`S`, `8`→`B`. After capturing, _norm_plate
# rewrites those before the DB lookup. Also covers the old-format
# `\d{3}[A-Z]{3}` (e.g. 131JOM sunbeam) and `[A-Z]{3}\d{3}[A-Z]?` (3-letter prefix).
_PLATE_RE = re.compile(
    r"\b("
    r"[A-Z]{2}[\dIOSBLZ]{2}\s?[A-Z]{3}"     # WF14 FNP / WFI4FNP after fix
    r"|\d{3}[A-Z]{3}"                        # 131JOM
    r"|[A-Z]{3}\s?\d{1,3}[A-Z]?"             # ABC 123, ABC1234
    r")\b"
)

# OCR-confusable digit map (common Tesseract mis-reads)
_OCR_DIGIT_FIX = str.maketrans({"I": "1", "O": "0", "S": "5", "B": "8",
                                "L": "1", "Z": "2"})


def _norm_plate(s: str) -> str:
    raw = re.sub(r"\s+", "", (s or "").upper())
    return raw


def _plate_candidates(raw: str) -> list[str]:
    """Return the plate plus OCR-tolerant variants. For 'WFI4FNP' we want
    ['WFI4FNP', 'WF14FNP'] so the DB lookup finds the registered 'WF14FNP'."""
    raw = _norm_plate(raw)
    candidates = {raw}
    # Fix digit-confusables ONLY in positions where we'd expect digits.
    # Current UK format: AB12 CDE — positions 2-3 (0-indexed) are digits.
    if len(raw) >= 7 and raw[:2].isalpha() and raw[5:].isalpha():
        fixed = raw[:2] + raw[2:4].translate(_OCR_DIGIT_FIX) + raw[4:]
        candidates.add(fixed)
    # Old format 123ABC — positions 0-2 digits
    if len(raw) >= 6 and raw[:3].isdigit() is False:
        fixed = raw[:3].translate(_OCR_DIGIT_FIX) + raw[3:]
        candidates.add(fixed)
    return list(candidates)


async def _extract_ocr_text(content: bytes, mime_type: str) -> str:
    """Call pdfplumber service for PDFs. For images, return empty for now
    (Paperless-ngx will handle full OCR in Track 4b)."""
    if mime_type.startswith("application/pdf"):
        try:
            async with httpx.AsyncClient(timeout=60) as client:
                r = await client.post(
                    "http://homeai-pdfplumber:8003/extract-pdf",
                    files={"file": ("upload.pdf", content, "application/pdf")})
                r.raise_for_status()
                return r.json().get("text", "") or ""
        except Exception:
            return ""
    return ""


async def _link_to_entity(conn, ocr_text: str, title: str) -> tuple[str | None, int | None, str | None, int | None]:
    """Return (linked_table, linked_id, linked_by, entity_id) or all-None."""
    haystack = (ocr_text or "") + " " + (title or "")

    # 1. Plate regex → vehicles.registration (OCR-tolerant)
    for m in _PLATE_RE.finditer(haystack.upper()):
        for plate in _plate_candidates(m.group(1)):
            veh = await conn.fetchrow("""
                SELECT id, entity_id, registration, make_model
                  FROM vehicles
                 WHERE upper(replace(registration, ' ', '')) = $1
                 LIMIT 1
            """, plate)
            if veh:
                return ("vehicles", veh["id"], "auto:plate_regex", veh["entity_id"])

    # 2. Postcode → properties.postcode_full (if such column / table exists)
    postcode_re = re.compile(r"\b([A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2})\b", re.I)
    pc_match = postcode_re.search(haystack.upper())
    if pc_match:
        pc = re.sub(r"\s+", "", pc_match.group(1).upper())
        prop = await conn.fetchrow("""
            SELECT id, entity_id FROM properties
             WHERE upper(replace(coalesce(postcode, ''), ' ', '')) = $1
             LIMIT 1
        """, pc)
        if prop:
            return ("properties", prop["id"], "auto:postcode", prop["entity_id"])

    # 3. Child name → children.name (longer names only). children has no
    # entity_id column so the entity column is left NULL for child matches.
    kids = await conn.fetch(
        "SELECT id, name FROM children WHERE length(name) > 4")
    for k in kids:
        if k["name"] and k["name"].lower() in haystack.lower():
            return ("children", k["id"], "auto:name", None)

    # 4. Bank sort code + account number → bank_accounts (NatWest current /
    #    savings). UK sort code format `\d{2}-\d{2}-\d{2}` (or run-together
    #    via OCR), account number 8 digits within 200 chars of the sort code.
    sc_re = re.compile(r"\b(\d{2}[-\s]?\d{2}[-\s]?\d{2})\b")
    acct_re = re.compile(r"\b(\d{8})\b")
    for sc_m in sc_re.finditer(haystack):
        sc = re.sub(r"\D", "", sc_m.group(1))
        if len(sc) != 6:
            continue
        # Look for an 8-digit acct number near this sort code (±200 chars)
        start = max(0, sc_m.start() - 200)
        end = min(len(haystack), sc_m.end() + 200)
        window = haystack[start:end]
        for acct_m in acct_re.finditer(window):
            acct = acct_m.group(1)
            ba = await conn.fetchrow("""
                SELECT id, entity_id FROM bank_accounts
                 WHERE replace(coalesce(sort_code,''), '-', '') = $1
                   AND replace(coalesce(account_number,''), ' ', '') = $2
                 LIMIT 1
            """, sc, acct)
            if ba:
                return ("bank_accounts", ba["id"], "auto:sort_code+account",
                        ba["entity_id"])

    # 5. Credit-card masked PAN `\d{4}\s?\*{4,}\s?\d{4}` or `\*{4,}\d{4}`
    #    → bank_accounts.account_number containing the last-4 (CCs stored
    #    with masked account_number like '4929********1234').
    last4_re = re.compile(r"(?:\*{4,}|x{4,}|·{4,})\s?(\d{4})\b", re.I)
    last4s = set(last4_re.findall(haystack))
    # Also catch the unmasked-but-clearly-card "ending 1234" or "last 4 1234"
    end_re = re.compile(r"(?:ending|last\s*4\s*digits?[: ]*|card\s*ending)\s*[: ]*\*?(\d{4})\b", re.I)
    for m in end_re.finditer(haystack):
        last4s.add(m.group(1))
    for last4 in last4s:
        ba = await conn.fetchrow("""
            SELECT id, entity_id FROM bank_accounts
             WHERE account_type = 'credit_card'
               AND right(replace(coalesce(account_number,''), ' ', ''), 4) = $1
             LIMIT 1
        """, last4)
        if ba:
            return ("bank_accounts", ba["id"], "auto:card_last4",
                    ba["entity_id"])

    # 6. Mortgage lender + account_ref → mortgage_accounts
    #    Match well-known UK lender names and a nearby account_ref.
    lender_patterns = {
        "Principality":  r"\bPRINCIPALITY\b",
        "Halifax":       r"\bHALIFAX\b",
        "NatWest":       r"\bNATWEST\b",
        "Nationwide":    r"\bNATIONWIDE\b",
        "Santander":     r"\bSANTANDER\b",
        "Barclays":      r"\bBARCLAYS\b",
        "HSBC":          r"\bHSBC\b",
        "Lloyds":        r"\bLLOYDS\b",
        "TSB":           r"\bTSB\b",
        "RBS":           r"\bROYAL\s+BANK\s+OF\s+SCOTLAND\b|\bRBS\b",
        "Virgin Money":  r"\bVIRGIN\s+MONEY\b",
        "Coventry":      r"\bCOVENTRY\s+BUILDING\s+SOCIETY\b|\bCOVENTRY\b",
        "Skipton":       r"\bSKIPTON\b",
        "Yorkshire":     r"\bYORKSHIRE\s+BUILDING\s+SOCIETY\b",
    }
    H_UPPER = haystack.upper()
    for lender_name, pat in lender_patterns.items():
        if re.search(pat, H_UPPER):
            # Look for a plausible account ref: 6-12 digits, optionally with -
            for ref_m in re.finditer(r"\b(\d[\d-]{5,15}\d)\b", haystack):
                ref = re.sub(r"\D", "", ref_m.group(1))
                if len(ref) < 6 or len(ref) > 14:
                    continue
                ma = await conn.fetchrow("""
                    SELECT id, borrower_entity_id FROM mortgage_accounts
                     WHERE lender ILIKE $1
                       AND replace(coalesce(account_ref,''),'-','') = $2
                     LIMIT 1
                """, f"%{lender_name}%", ref)
                if ma:
                    return ("mortgage_accounts", ma["id"],
                            f"auto:lender+ref:{lender_name}",
                            ma["borrower_entity_id"])
            # Lender matched but no ref hit — fall through to confidence-low link
            ma = await conn.fetchrow("""
                SELECT id, borrower_entity_id FROM mortgage_accounts
                 WHERE lender ILIKE $1
                 ORDER BY id DESC
                 LIMIT 1
            """, f"%{lender_name}%")
            if ma:
                return ("mortgage_accounts", ma["id"],
                        f"auto:lender_only:{lender_name}",
                        ma["borrower_entity_id"])
            break  # lender matched but no mortgage on file

    # 7. Utility provider + account number → property_utilities → property
    utility_patterns = [
        ("electricity", r"\bBRITISH\s+GAS\b|\bOCTOPUS\s+ENERGY\b|\bEDF\s+ENERGY\b|\bE\.ON\b|\bEON\b|\bOVO\s+ENERGY\b|\bSCOTTISH\s+POWER\b|\bSO\s+ENERGY\b|\bBULB\b|\bN POWER\b"),
        ("gas",         r"\bCALOR\s+GAS\b|\bFLOGAS\b"),
        ("water",       r"\bSOUTH\s+WEST\s+WATER\b|\bTHAMES\s+WATER\b|\bSEVERN\s+TRENT\b|\bANGLIAN\s+WATER\b|\bYORKSHIRE\s+WATER\b|\bWESSEX\s+WATER\b|\bAFFINITY\s+WATER\b"),
        ("broadband",   r"\bBT\s+(?:GROUP|BUSINESS|BROADBAND)\b|\bVIRGIN\s+MEDIA\b|\bSKY\s+BROADBAND\b|\bPLUSNET\b|\bTALKTALK\b|\bZEN\s+INTERNET\b"),
        ("council_tax", r"\bCORNWALL\s+COUNCIL\b|\bCOUNCIL\s+TAX\b"),
        ("oil",         r"\bMITCHELL\s+&\s+WEBBER\b|\bWATSON\s+(?:FUELS|PETROLEUM)\b|\bCERTAS\b|\bRIX\s+PETROLEUM\b"),
    ]
    for kind, pat in utility_patterns:
        if re.search(pat, H_UPPER):
            # Try account_number match in property_utilities
            for ref_m in re.finditer(r"\b(\d[\d/-]{5,18}\d)\b", haystack):
                ref = re.sub(r"\D", "", ref_m.group(1))
                if len(ref) < 6:
                    continue
                pu = await conn.fetchrow("""
                    SELECT pu.property_id, p.entity_id
                      FROM property_utilities pu
                      JOIN properties p ON p.id = pu.property_id
                     WHERE replace(coalesce(pu.account_number,''),'-','') = $1
                        OR replace(coalesce(pu.mpan_or_mprn,''),' ','') = $1
                     LIMIT 1
                """, ref)
                if pu:
                    return ("properties", pu["property_id"],
                            f"auto:utility:{kind}", pu["entity_id"])
            # Lender-only: fall through to Layer 3 (Haiku) — don't guess
            break

    # 8. HMRC UTR / VAT no → entities
    utr_m = re.search(r"\b(\d{10})\b(?:\s*(?:UTR|TAXPAYER))", H_UPPER) \
            or re.search(r"(?:UTR|TAXPAYER|Unique\s+Tax)[\s:]+(\d{10})\b", haystack, re.I)
    if utr_m:
        utr = utr_m.group(1)
        e = await conn.fetchrow("SELECT id FROM entities WHERE utr = $1", utr)
        if e:
            return ("entities", e["id"], "auto:hmrc_utr", e["id"])

    vat_m = re.search(r"\b(?:GB)?\s*(\d{9,11})\b(?:\s*VAT)|VAT\s*(?:no|number)[\s:]+(?:GB)?\s*(\d{9,11})",
                       haystack, re.I)
    if vat_m:
        vat = (vat_m.group(1) or vat_m.group(2) or "").strip()
        if vat:
            e = await conn.fetchrow(
                "SELECT id FROM entities WHERE replace(coalesce(vat_number,''),' ','') LIKE $1",
                f"%{vat}")
            if e:
                return ("entities", e["id"], "auto:hmrc_vat", e["id"])

    return (None, None, None, None)


@app.get("/documents")
async def documents_page():
    return FileResponse(str(STATIC / "documents.html"))


@app.post("/api/documents/ingest-from-paperless")
async def api_documents_ingest_from_paperless(payload: dict = Body(...)):
    """U70 T1: Paperless post-consume webhook.

    Expected payload (from scripts/paperless-post-consume.sh):
      {
        "paperless_id":    int,         # Paperless document ID
        "title":           str,
        "original_path":   str,         # path inside paperless container
        "mime_type":       str,
        "sha256":          str,         # of the original file
        "ocr_text":        str,         # Paperless-extracted (Tesseract by default)
        "tags":            [str],
        "correspondent":   str | null,
        "document_type":   str | null,  # 'invoice'|'receipt'|'bill'|'letter'|...
        "secret":          str,         # shared secret from secret/paperless/webhook
      }
    """
    # Shared-secret check
    expected = await _vault_read("paperless/webhook")
    expected_secret = (expected or {}).get("secret") or os.environ.get("PAPERLESS_WEBHOOK_SECRET")
    if not expected_secret:
        return JSONResponse({"error": "webhook secret not configured"}, status_code=503)
    if payload.get("secret") != expected_secret:
        return JSONResponse({"error": "unauthorised"}, status_code=401)

    paperless_id = payload.get("paperless_id")
    if not paperless_id:
        return JSONResponse({"error": "paperless_id required"}, status_code=400)

    title       = (payload.get("title") or f"paperless-{paperless_id}").strip()[:200]
    ocr_text    = payload.get("ocr_text") or ""
    mime        = payload.get("mime_type") or "application/octet-stream"
    # Empty sha would collide on the partial unique index — keep NULL.
    sha         = (payload.get("sha256") or "").strip() or None
    doc_type    = (payload.get("document_type") or "").lower()
    category    = doc_type if doc_type else "paperless"
    correspondent = (payload.get("correspondent") or "").strip()

    p = await pool()
    async with p.acquire() as c:
        async with c.transaction():
            await c.execute("SET LOCAL app.current_entity = 'all'")
            await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())

            # Idempotent on paperless_id (preferred) or sha256 (fallback)
            existing = await c.fetchval(
                "SELECT id FROM documents WHERE paperless_id = $1", paperless_id)
            if not existing and sha:
                existing = await c.fetchval(
                    "SELECT id FROM documents WHERE sha256 = $1", sha)
            if existing:
                return {"ok": True, "id": existing, "duplicate": True}

            linked_table, linked_id, linked_by, ent_id = await _link_to_entity(
                c, ocr_text, f"{title} {correspondent}")
            doc_id = await c.fetchval("""
                INSERT INTO documents
                    (entity_id, category, title, status,
                     paperless_id, file_path, mime_type, sha256, ocr_text,
                     linked_table, linked_id, linked_by, uploaded_by, realm)
                VALUES ($1, $2, $3, 'active',
                        $4, $5, $6, $7, $8,
                        $9, $10, $11, 'paperless',
                        COALESCE($12, 'family'))
                RETURNING id
            """, ent_id, category, title,
                 paperless_id, payload.get("original_path"), mime, sha, ocr_text,
                 linked_table, linked_id, linked_by, None)

            # U70 T2: invoice-shaped Paperless docs flow into vendor_invoice_inbox
            # so the existing Haiku line-extractor picks them up. NOT NULLs:
            #   idempotency_key, source_email_id, account, vendor_domain, subject,
            #   received_at, entity_id (default 1), status (default 'new').
            invoice_id = None
            if doc_type in ("invoice", "receipt", "bill"):
                cols = await _columns_of(c, 'vendor_invoice_inbox')
                if 'paperless_doc_id' in cols:
                    idem      = f"paperless:{paperless_id}"
                    source_id = f"paperless:{paperless_id}"
                    invoice_id = await c.fetchval("""
                        INSERT INTO vendor_invoice_inbox
                            (idempotency_key, source_email_id, account,
                             vendor_domain, vendor_name, subject,
                             received_at, body_text, has_pdf,
                             pipeline_version, paperless_doc_id, realm)
                        VALUES ($1, $2, 'paperless',
                                $3, $4, $5,
                                now(), $6, true,
                                'paperless:u70', $7, 'work')
                        ON CONFLICT (idempotency_key) DO NOTHING
                        RETURNING id
                    """, idem, source_id,
                         correspondent or 'paperless',
                         correspondent or 'Paperless ingest',
                         title,
                         ocr_text[:5000],
                         doc_id)

            # U80 — auto-parse Principality mortgage statements + populate
            # mortgage_statement_periods. Triggers on category='mortgage_statement'
            # OR when OCR has the Principality statement signature.
            mortgage_periods = []
            mortgage_unknown_refs = []
            looks_mortgage = (
                category == 'mortgage_statement' or
                ('PRINCIPALITY' in ocr_text.upper() and 'LOAN ACCOUNT' in ocr_text.upper())
            )
            if looks_mortgage:
                for stmt in _parse_principality_statements(ocr_text):
                    m_id = await c.fetchval(
                        "SELECT id FROM mortgage_accounts WHERE account_ref = $1",
                        stmt['loan_ref'])
                    if not m_id:
                        mortgage_unknown_refs.append(stmt['loan_ref'])
                        continue
                    await c.execute("""
                        INSERT INTO mortgage_statement_periods
                            (mortgage_account_id, document_id, page_in_letter,
                             period_start, period_end,
                             balance_opening, balance_closing, realm)
                        VALUES ($1, $2, $3, $4, $5, $6, $7, 'work')
                        ON CONFLICT (mortgage_account_id, period_start) DO NOTHING
                    """, m_id, doc_id, stmt['page'], stmt['period_start'],
                         stmt['period_end'], stmt['balance_opening'],
                         stmt['balance_closing'])
                    # If this is the latest statement we've seen for an active
                    # loan, roll its current_balance forward.
                    # NB: cast on the IS NOT NULL clause so asyncpg can infer
                    # the parameter type (AmbiguousParameterError otherwise).
                    if stmt['balance_closing'] is not None:
                        await c.execute("""
                            UPDATE mortgage_accounts
                               SET current_balance = $1,
                                   balance_as_of   = $2
                             WHERE id = $3
                               AND closed_date IS NULL
                               AND (balance_as_of IS NULL OR balance_as_of < $2)
                        """, stmt['balance_closing'], stmt['period_end'], m_id)
                    mortgage_periods.append({
                        'loan_ref':  stmt['loan_ref'],
                        'period':    stmt['period_end'].isoformat(),
                        'balance':   float(stmt['balance_closing']) if stmt['balance_closing'] is not None else None,
                    })

    return {
        "ok": True, "id": doc_id, "duplicate": False,
        "vendor_invoice_inbox_id": invoice_id,
        "linked_table": linked_table, "linked_id": linked_id, "linked_by": linked_by,
        "ocr_chars": len(ocr_text),
        "mortgage_periods_inserted": mortgage_periods,
        "mortgage_unknown_refs":     mortgage_unknown_refs,
    }


def _parse_principality_statements(ocr_text: str) -> list[dict]:
    """U80: extract every loan-period section from a Principality statement
    OCR text. Each section starts with the canonical anchor:

        Loan <ref> Statement Period: <DD/MM/YYYY> to <DD/MM/YYYY> Page Number : <N>

    Returns one dict per match with loan_ref / period_start / period_end /
    page / balance_opening / balance_closing. Balances are pulled from the
    'Balance Brought Forward' and 'Balance Carried Forward' lines within
    the next ~2000 chars of the section.
    """
    import re
    from datetime import date
    out = []
    anchor = re.compile(
        r'[Ll]oan\s+([0-9]{4,}[-/0-9]*)\s+'
        r'[Ss]tatement\s+[Pp]eriod[:\s]+'
        r'(\d{1,2}/\d{1,2}/\d{4})\s+to\s+(\d{1,2}/\d{1,2}/\d{4})\s+'
        r'[Pp]age\s+[Nn]umber\s*:?\s*(\d+)',
        re.I)
    money_re = re.compile(r'([\d,]+\.\d{2})')

    def _uk_date(s: str):
        d, m, y = s.split('/')
        return date(int(y), int(m), int(d))
    def _money(s: str):
        return float(s.replace(',', ''))

    for hit in anchor.finditer(ocr_text):
        section = ocr_text[hit.end(): hit.end() + 2000]
        bopen = bclose = None
        bo = re.search(r'Balance\s+Brought\s+Forward[\s|]+' + money_re.pattern, section, re.I)
        if bo: bopen = _money(bo.group(1))
        bc = re.search(r'Balance\s+Carried\s+Forward[\s|]+' + money_re.pattern, section, re.I)
        if bc: bclose = _money(bc.group(1))
        try:
            out.append({
                'loan_ref':        hit.group(1).strip(),
                'period_start':    _uk_date(hit.group(2)),
                'period_end':      _uk_date(hit.group(3)),
                'page':            int(hit.group(4)),
                'balance_opening': bopen,
                'balance_closing': bclose,
            })
        except (ValueError, TypeError):
            continue
    return out


async def _columns_of(conn, table: str) -> set[str]:
    """Tiny helper: column-name set for a public.<table>. Cached at first call."""
    rows = await conn.fetch("""
        SELECT column_name FROM information_schema.columns
         WHERE table_schema='public' AND table_name=$1
    """, table)
    return {r["column_name"] for r in rows}


@app.post("/api/documents/upload")
async def api_documents_upload(
    file: UploadFile = File(...),
    title: str = Query(""),
    category: str = Query(""),
):
    """Upload a document — PDF or image. We OCR it (PDFs only for now via
    pdfplumber; image OCR is queued for the Paperless-ngx pipeline) and
    try to auto-link to a vehicle/property/child by content scan.
    Stored at /home_ai/storage/documents/<sha256>.<ext>."""
    content = await file.read()
    if len(content) > 50 * 1024 * 1024:
        return JSONResponse({"error": "file too large (max 50MB)"}, status_code=413)
    sha = _hashlib.sha256(content).hexdigest()
    mime = file.content_type or "application/octet-stream"
    ext = {"application/pdf": "pdf", "image/jpeg": "jpg",
           "image/png": "png", "image/tiff": "tiff"}.get(mime, "bin")
    _os.makedirs(_DOCS_ROOT, exist_ok=True)
    file_path = f"{_DOCS_ROOT}/{sha}.{ext}"
    if not _os.path.exists(file_path):
        with open(file_path, "wb") as f:
            f.write(content)

    ocr_text = await _extract_ocr_text(content, mime)
    title = (title or file.filename or "untitled").strip()[:200]
    category = (category or "uncategorised").strip()[:80]

    p = await pool()
    async with p.acquire() as c:
        async with c.transaction():
            await c.execute("SET LOCAL app.current_entity = 'all'")
            await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())

            # Idempotent on sha256
            existing = await c.fetchval(
                "SELECT id FROM documents WHERE sha256 = $1", sha)
            if existing:
                return {"ok": True, "id": existing, "duplicate": True}

            linked_table, linked_id, linked_by, ent_id = await _link_to_entity(
                c, ocr_text, title)
            doc_id = await c.fetchval("""
                INSERT INTO documents
                    (entity_id, category, title, status,
                     file_path, mime_type, sha256, ocr_text,
                     linked_table, linked_id, linked_by, uploaded_by, realm)
                VALUES ($1, $2, $3, 'active',
                        $4, $5, $6, $7,
                        $8, $9, $10, 'jo',
                        COALESCE($11, 'family'))
                RETURNING id
            """, ent_id, category, title, file_path, mime, sha, ocr_text,
                 linked_table, linked_id, linked_by,
                 # realm derived from linked entity if known, else family
                 None)
    return {
        "ok": True, "id": doc_id, "sha256": sha,
        "linked_table": linked_table, "linked_id": linked_id, "linked_by": linked_by,
        "ocr_chars": len(ocr_text),
    }


@app.get("/api/documents/list")
async def api_documents_list(limit: int = Query(100, ge=1, le=500)):
    rows = await db_all("""
        SELECT id, title, category, mime_type, file_path,
               linked_table, linked_id, linked_by, entity_id, realm,
               LENGTH(coalesce(ocr_text,'')) AS ocr_chars,
               created_at
          FROM documents
         ORDER BY created_at DESC
         LIMIT $1
    """, limit)
    return {"n": len(rows), "rows": [_isoify(dict(r)) for r in rows]}


@app.get("/api/documents/by-link/{table}/{linked_id}")
async def api_documents_by_link(table: str, linked_id: int):
    if table not in ("vehicles", "properties", "children", "invoices", "employees"):
        return JSONResponse({"error": "unknown table"}, status_code=400)
    rows = await db_all("""
        SELECT id, title, category, mime_type, file_path, linked_by,
               LENGTH(coalesce(ocr_text,'')) AS ocr_chars, created_at
          FROM documents
         WHERE linked_table = $1 AND linked_id = $2
         ORDER BY created_at DESC
    """, table, linked_id)
    return {"n": len(rows), "rows": [_isoify(dict(r)) for r in rows]}


@app.get("/api/documents/{doc_id}/file")
async def api_documents_file(doc_id: int):
    row = await db_one(
        "SELECT file_path, mime_type, title FROM documents WHERE id = $1", doc_id)
    if not row or not row["file_path"]:
        return JSONResponse({"error": "not found"}, status_code=404)
    real = _os.path.realpath(row["file_path"])
    # Paperless-ingested docs live under /usr/src/paperless/media but we only
    # have /home_ai/storage/documents on disk for direct-uploads. For paperless
    # rows, redirect to the Paperless API instead.
    if not real.startswith(_os.path.realpath(_DOCS_ROOT) + "/"):
        return JSONResponse({"error": "path traversal blocked"}, status_code=403)
    if not _os.path.exists(real):
        return JSONResponse({"error": "file missing on disk"}, status_code=404)
    return FileResponse(real, media_type=row["mime_type"] or "application/octet-stream",
                        filename=row["title"] or _os.path.basename(real))


# ─────────────────────────────────────────────────────────────────────────────
# U68 T4 — review queue + manual link endpoints
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/api/documents/review-queue")
async def api_documents_review_queue():
    """Docs that the linker couldn't auto-attach OR the Haiku classifier
    rated below 0.85 confidence. Drives the 'Needs your eye' tab on /documents."""
    rows = await db_all("""
        SELECT v.*,
               -- Resolve human-readable label for the suggested link
               CASE v.suggested_link_table
                 WHEN 'vehicles' THEN
                   (SELECT registration || ' (' || make_model || ')'
                      FROM vehicles WHERE id = v.suggested_link_id)
                 WHEN 'properties' THEN
                   (SELECT address_line1 || ' ' || coalesce(postcode,'')
                      FROM properties WHERE id = v.suggested_link_id)
                 WHEN 'bank_accounts' THEN
                   (SELECT bank_name || ' ' || account_name
                      FROM bank_accounts WHERE id = v.suggested_link_id)
                 WHEN 'mortgage_accounts' THEN
                   (SELECT lender || ' ' || coalesce(account_ref,'')
                      FROM mortgage_accounts WHERE id = v.suggested_link_id)
                 WHEN 'entities' THEN
                   (SELECT name FROM entities WHERE id = v.suggested_link_id)
                 WHEN 'children' THEN
                   (SELECT name FROM children WHERE id = v.suggested_link_id)
                 ELSE NULL
               END AS suggested_link_label
          FROM v_documents_needing_review v
         ORDER BY confidence DESC NULLS LAST, created_at DESC
         LIMIT 200
    """)
    return {"n": len(rows), "rows": [_isoify(dict(r)) for r in rows]}


@app.get("/api/documents/link-options")
async def api_documents_link_options(table: str = Query(...)):
    """List candidate rows for the manual-link picker on /documents."""
    if table == "vehicles":
        rows = await db_all(
            "SELECT id, registration || ' — ' || make_model AS label FROM vehicles ORDER BY registration")
    elif table == "properties":
        rows = await db_all(
            "SELECT id, COALESCE(address_line1, 'property #' || id) || ' ' || COALESCE(postcode,'') AS label FROM properties ORDER BY address_line1")
    elif table == "bank_accounts":
        rows = await db_all(
            "SELECT id, bank_name || ' — ' || account_name AS label FROM bank_accounts ORDER BY bank_name, account_name")
    elif table == "mortgage_accounts":
        rows = await db_all(
            "SELECT id, lender || ' — ' || COALESCE(account_ref,'(no ref)') AS label FROM mortgage_accounts ORDER BY lender")
    elif table == "entities":
        rows = await db_all(
            "SELECT id, name AS label FROM entities ORDER BY id")
    elif table == "children":
        rows = await db_all(
            "SELECT id, name AS label FROM children ORDER BY name")
    else:
        return JSONResponse({"error": f"unknown table {table!r}"}, status_code=400)
    return {"table": table, "rows": [_isoify(dict(r)) for r in rows]}


@app.post("/api/documents/{doc_id}/link")
async def api_documents_link(doc_id: int, payload: dict = Body(...)):
    """Manually attach a document to a record. Also marks the classification
    queue row as 'manual_applied'."""
    table = (payload.get("table") or "").strip()
    linked_id = payload.get("linked_id")
    if table and table not in ("vehicles","properties","bank_accounts",
                                "mortgage_accounts","entities","children"):
        return JSONResponse({"error":"invalid table"}, status_code=400)
    if not table:
        # Clear the link
        table = None
        linked_id = None
    elif linked_id is None:
        return JSONResponse({"error":"linked_id required when setting table"}, status_code=400)
    p = await pool()
    async with p.acquire() as c:
        async with c.transaction():
            await c.execute("SET LOCAL app.current_entity = 'all'")
            await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())
            ok = await c.fetchval("""
                UPDATE documents
                   SET linked_table = $2,
                       linked_id    = $3,
                       linked_by    = COALESCE($4, 'manual:jo'),
                       updated_at   = NOW()
                 WHERE id = $1
                RETURNING id
            """, doc_id, table, int(linked_id) if linked_id else None,
                 'manual:jo')
            if ok:
                await c.execute("""
                    UPDATE documents_classification_queue
                       SET status='manual_applied',
                           review_resolution='manual_confirmed',
                           reviewed_by='jo',
                           reviewed_at=NOW()
                     WHERE document_id=$1
                """, doc_id)
    if not ok:
        return JSONResponse({"error":"doc not found"}, status_code=404)
    return {"ok": True, "id": doc_id, "linked_table": table, "linked_id": linked_id}


@app.post("/api/documents/{doc_id}/reject")
async def api_documents_reject(doc_id: int, payload: dict = Body(default={})):
    """Reject the suggested classification — leaves doc unlinked but marked
    so it doesn't keep appearing in the review queue."""
    reason = (payload.get("reason") or "").strip()[:500]
    p = await pool()
    async with p.acquire() as c:
        async with c.transaction():
            await c.execute("SET LOCAL app.current_entity = 'all'")
            await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())
            await c.execute("""
                INSERT INTO documents_classification_queue
                    (document_id, status, review_resolution, reviewed_by,
                     reviewed_at, summary)
                VALUES ($1, 'rejected', 'rejected', 'jo', NOW(), $2)
                ON CONFLICT (document_id) DO UPDATE
                   SET status='rejected', review_resolution='rejected',
                       reviewed_by='jo', reviewed_at=NOW(),
                       summary=COALESCE(EXCLUDED.summary,
                                         documents_classification_queue.summary)
            """, doc_id, reason or None)
    return {"ok": True}


@app.get("/api/emails/search")
async def api_emails_search(
    q: str = Query("", min_length=0, max_length=500),
    account: str = Query(""),
    from_date: str = Query(""),
    to_date: str = Query(""),
    limit: int = Query(50, ge=1, le=500),
):
    """Full-text search across emails. q is a websearch query string
    (supports quoted phrases, OR, -negation). When q matches anything that
    looks like an account/sort code (digits with separators) we also do a
    trigram ILIKE fallback so partial number strings hit."""
    q = (q or "").strip()
    if not q:
        return {"q": q, "n_rows": 0, "rows": []}

    where_extra = []
    args = []
    arg_n = 1

    args.append(q)              # $1 — for websearch_to_tsquery
    arg_n += 1
    args.append(f"%{q}%")       # $2 — for ILIKE fallback
    arg_n += 1

    if account:
        where_extra.append(f"AND e.account = ${arg_n}")
        args.append(account)
        arg_n += 1
    if from_date:
        where_extra.append(f"AND e.received_at >= ${arg_n}::date")
        args.append(from_date)
        arg_n += 1
    if to_date:
        where_extra.append(f"AND e.received_at <= (${arg_n}::date + INTERVAL '1 day')")
        args.append(to_date)
        arg_n += 1
    extra = " ".join(where_extra)
    args.append(limit)

    sql = f"""
        SELECT e.id, e.gmail_message_id, e.account, e.from_address, e.from_name,
               e.subject, e.received_at, e.has_attachment, e.realm,
               ts_rank_cd(e.tsv, websearch_to_tsquery('english', $1)) AS rank,
               ts_headline('english', COALESCE(e.body_text, e.subject, ''),
                           websearch_to_tsquery('english', $1),
                           'MaxFragments=2, MaxWords=20, MinWords=5,
                            StartSel=<mark>, StopSel=</mark>') AS snippet
          FROM emails e
         WHERE (
                e.tsv @@ websearch_to_tsquery('english', $1)
             OR e.subject  ILIKE $2
             OR e.body_text ILIKE $2
             OR e.from_address ILIKE $2
         )
         {extra}
         ORDER BY rank DESC, e.received_at DESC
         LIMIT ${arg_n}
    """
    rows = await db_all(sql, *args)
    return {"q": q, "n_rows": len(rows),
            "rows": [_isoify(dict(r)) for r in rows]}


# ─────────────────────────────────────────────────────────────────────────────
# U61 T2 — invoice line items, preview image, plain-text notes
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/api/invoices/{invoice_id}/lines")
async def api_invoice_lines(invoice_id: int):
    """List line items for an invoice, joined to product_canonical."""
    rows = await db_all("""
        SELECT line_id, line_no, raw_description, qty, unit, unit_price,
               line_net, line_vat, line_gross,
               canonical_id, canonical_family, canonical_name,
               extracted_by, extraction_confidence
          FROM v_invoice_lines_resolved
         WHERE invoice_id = $1
         ORDER BY line_no
    """, invoice_id)
    return {"invoice_id": invoice_id, "n_lines": len(rows),
            "lines": [_isoify(dict(r)) for r in rows]}


@app.get("/api/invoices/{invoice_id}/preview-image")
async def api_invoice_preview_image(invoice_id: int, width: int = 1200):
    """Page-1 PNG render, cached on disk under /home_ai/storage/invoice-previews/."""
    cache_dir = "/home_ai/storage/invoice-previews"
    _os.makedirs(cache_dir, exist_ok=True)
    cache_path = f"{cache_dir}/{invoice_id}_{int(width)}.png"
    if _os.path.exists(cache_path):
        return FileResponse(cache_path, media_type="image/png")

    # Locate PDF — same fallback logic as /api/invoice/{id}/pdf.
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = '1'")
        path = await c.fetchval(
            "SELECT first_attachment_path FROM vendor_invoice_inbox WHERE id=$1",
            invoice_id)
    pdf_path = None
    if path:
        real = _os.path.realpath(path)
        if real.startswith(_os.path.realpath(_INVOICE_STORAGE_ROOT) + "/") \
                and _os.path.exists(real):
            pdf_path = real
    if not pdf_path:
        fallback = f"/home_ai/data/invoice-pdfs/{invoice_id}.pdf"
        if _os.path.exists(fallback):
            pdf_path = fallback
    if not pdf_path:
        return JSONResponse({"error": "no PDF on disk"}, status_code=404)

    # Call pdfplumber service.
    try:
        async with httpx.AsyncClient(timeout=30) as client:
            with open(pdf_path, "rb") as f:
                r = await client.post(
                    "http://homeai-pdfplumber:8003/render-page1-png",
                    files={"file": (f"{invoice_id}.pdf", f, "application/pdf")},
                    params={"width": int(width)})
            r.raise_for_status()
            with open(cache_path, "wb") as out:
                out.write(r.content)
    except Exception as e:
        return JSONResponse({"error": f"render failed: {e}"}, status_code=500)
    return FileResponse(cache_path, media_type="image/png")


@app.put("/api/invoices/{invoice_id}/notes")
async def api_invoice_notes_put(invoice_id: int, payload: dict = Body(...)):
    """Append a plain-text note to vendor_invoice_inbox.notes. Format:
       [YYYY-MM-DD username] <text>
       Notes are append-only; the textarea on the UI loads the full history."""
    text = (payload.get("notes") or payload.get("text") or "").strip()
    if not text or len(text) < 1:
        return JSONResponse({"error": "empty note"}, status_code=400)
    if len(text) > 2000:
        text = text[:2000]
    user = (payload.get("user") or "jo").strip() or "jo"
    today = datetime.now().strftime("%Y-%m-%d")
    line = f"[{today} {user}] {text}\n"
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = '1'")
        await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())
        existing = await c.fetchval(
            "SELECT notes FROM vendor_invoice_inbox WHERE id=$1", invoice_id)
        if existing is None and (await c.fetchval(
                "SELECT 1 FROM vendor_invoice_inbox WHERE id=$1", invoice_id)) is None:
            return JSONResponse({"error": "invoice not found"}, status_code=404)
        new_notes = (existing or "") + line
        await c.execute("UPDATE vendor_invoice_inbox SET notes=$1 WHERE id=$2",
                        new_notes, invoice_id)
    return {"ok": True, "notes": new_notes}


@app.get("/api/invoices/{invoice_id}/notes")
async def api_invoice_notes_get(invoice_id: int):
    notes = await db_one(
        "SELECT notes FROM vendor_invoice_inbox WHERE id=$1", invoice_id)
    if not notes:
        return JSONResponse({"error": "invoice not found"}, status_code=404)
    return {"invoice_id": invoice_id, "notes": notes["notes"] or ""}


@app.post("/api/invoice/{invoice_id}/feedback")
async def api_invoice_feedback(invoice_id: int, payload: dict):
    """U44 — record plain-text user feedback about an invoice. Sonnet applier
    (cron 21:30) reads new rows and classifies into action types (flag_as_statement,
    flag_as_ignored, recategorise, add_vendor_rule). Never auto-applies — Jo
    approves via Action Queue."""
    text = (payload.get("text") or "").strip()
    if not text or len(text) < 3:
        return {"ok": False, "error": "feedback text required (3+ chars)"}
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity='1'")
        # Confirm invoice exists
        exists = await c.fetchval("SELECT 1 FROM vendor_invoice_inbox WHERE id=$1", invoice_id)
        if not exists:
            return {"ok": False, "error": f"invoice id={invoice_id} not found"}
        feedback_id = await c.fetchval("""
          INSERT INTO invoice_feedback (invoice_id, feedback_text)
          VALUES ($1, $2) RETURNING id
        """, invoice_id, text[:2000])
    return {"ok": True, "feedback_id": feedback_id}


@app.get("/api/reviews/queue")
async def api_reviews_queue():
    """U39 — Action Queue feed for guest reviews. Returns drafted-but-not-actioned
    reviews newest first, plus the latest draft text per review."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        rows = await c.fetch("""
          SELECT gr.source, gr.review_id, gr.location, gr.rating, gr.reviewer_name,
                 gr.body, gr.posted_at, gr.status,
                 rd.id AS draft_id, rd.draft_text, rd.created_at AS drafted_at,
                 rd.approved_at, rd.posted_at AS draft_posted_at, rd.rejected_at,
                 rd.edited_text
            FROM guest_reviews gr
       LEFT JOIN LATERAL (
              SELECT id, draft_text, created_at, approved_at, posted_at, rejected_at, edited_text
                FROM review_drafts rd2
               WHERE rd2.source = gr.source AND rd2.review_id = gr.review_id
               ORDER BY rd2.id DESC LIMIT 1
            ) rd ON true
           WHERE gr.status IN ('drafted', 'new', 'approved')
           ORDER BY gr.rating ASC NULLS LAST, gr.posted_at DESC NULLS LAST
           LIMIT 50
        """)

    def _row(r):
        out = {}
        for k, v in dict(r).items():
            if hasattr(v, "isoformat"): out[k] = v.isoformat()
            else: out[k] = v
        return out
    items = [_row(r) for r in rows]
    return {
        "items":         items,
        "pending_count": sum(1 for i in items if i.get("status") == "drafted" and not i.get("approved_at") and not i.get("rejected_at")),
        "low_star_count": sum(1 for i in items if (i.get("rating") or 5) <= 3),
    }


@app.post("/api/reviews/approve")
async def api_reviews_approve(payload: dict):
    """U39 — Approve (with optional edit) or reject a draft.
    Payload: {"draft_id": int, "action": "approve"|"reject"|"edit", "edited_text": str (optional), "reason": str (optional)}"""
    draft_id    = payload.get("draft_id")
    action      = payload.get("action")
    edited_text = payload.get("edited_text")
    reason      = payload.get("reason")
    if not draft_id or action not in ("approve", "reject", "edit"):
        return {"ok": False, "error": "draft_id + action ∈ {approve,reject,edit} required"}
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity='1'")
        async with c.transaction():
            if action == "approve":
                await c.execute("""
                  UPDATE review_drafts SET approved_at=now(),
                         edited_text=COALESCE($2, edited_text)
                   WHERE id=$1
                """, draft_id, edited_text)
                await c.execute("""
                  UPDATE guest_reviews gr SET status='approved'
                    FROM review_drafts rd WHERE rd.id=$1
                     AND gr.source=rd.source AND gr.review_id=rd.review_id
                """, draft_id)
            elif action == "edit":
                await c.execute("""
                  UPDATE review_drafts SET edited_text=$2 WHERE id=$1
                """, draft_id, edited_text or "")
            else:  # reject
                await c.execute("""
                  UPDATE review_drafts SET rejected_at=now(), rejection_reason=$2 WHERE id=$1
                """, draft_id, reason)
                await c.execute("""
                  UPDATE guest_reviews gr SET status='rejected'
                    FROM review_drafts rd WHERE rd.id=$1
                     AND gr.source=rd.source AND gr.review_id=rd.review_id
                """, draft_id)
    return {"ok": True, "action": action}


@app.post("/api/reviews/mark_posted")
async def api_reviews_mark_posted(payload: dict):
    """U39 — Jo manually posts the response to Google/TripAdvisor, then clicks 'mark posted'."""
    draft_id = payload.get("draft_id")
    if not draft_id: return {"ok": False, "error": "draft_id required"}
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity='1'")
        async with c.transaction():
            await c.execute("UPDATE review_drafts SET posted_at=now() WHERE id=$1", draft_id)
            await c.execute("""
              UPDATE guest_reviews gr SET status='posted'
                FROM review_drafts rd WHERE rd.id=$1
                 AND gr.source=rd.source AND gr.review_id=rd.review_id
            """, draft_id)
    return {"ok": True}


@app.get("/api/drift/current")
async def api_drift_current():
    """v_ai_worker_drift consumer — current AI worker drift status.
    Returns top 5 worst drifters and a flagged count."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        rows = await c.fetch("""
          SELECT ai_worker, ai_model, today_avg_conf, baseline_avg_conf,
                 baseline_stddev, delta_stddev, today_n, baseline_n, flagged
            FROM v_ai_worker_drift
           ORDER BY flagged DESC, delta_stddev ASC NULLS LAST
           LIMIT 5
        """)

    def _row(r):
        out = {}
        for k, v in dict(r).items():
            out[k] = float(v) if hasattr(v, "to_eng_string") else v
        return out

    items = [_row(r) for r in rows]
    return {
        "items":         items,
        "flagged_count": sum(1 for i in items if i.get("flagged")),
    }


@app.get("/api/dreaming/heuristics")
async def api_dreaming_heuristics():
    """Recent dreaming proposals + run history."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        proposals = await c.fetch("""
          SELECT id, scope, ai_worker, observation, suggested_rule, severity, status, generated_at
            FROM dreaming_heuristics
           ORDER BY id DESC LIMIT 20
        """)
        runs = await c.fetch("""
          SELECT id, started_at, finished_at, patterns_found, proposals_new, error_message
            FROM dreaming_runs ORDER BY id DESC LIMIT 7
        """)

    def _row(r):
        out = {}
        for k, v in dict(r).items():
            if hasattr(v, "isoformat"): out[k] = v.isoformat()
            else: out[k] = v
        return out
    return {
        "proposals": [_row(r) for r in proposals],
        "runs":      [_row(r) for r in runs],
        "counts":    {
            "proposed":  sum(1 for r in proposals if r["status"]=="proposed"),
            "accepted":  sum(1 for r in proposals if r["status"]=="accepted"),
            "rejected":  sum(1 for r in proposals if r["status"]=="rejected"),
        },
    }


@app.get("/api/anomalies")
async def api_anomalies():
    """KPI anomalies: today vs 7-day rolling avg, flag if outside ±50%.
    Catches silent extraction failures (empty PDF, missed email, zero values)."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        rows = await c.fetch("""
          SELECT metric, report_date, today_value, rolling_avg_7d,
                 rolling_stddev_7d, sample_n, delta_pct, flagged, severity
            FROM v_kpi_anomalies
        """)

    def _row(r):
        out = {}
        for k, v in dict(r).items():
            if hasattr(v, "isoformat"): out[k] = v.isoformat()
            elif hasattr(v, "to_eng_string"): out[k] = float(v)
            else: out[k] = v
        return out

    items = [_row(r) for r in rows]
    return {
        "items":         items,
        "flagged_count": sum(1 for i in items if i.get("flagged")),
        "max_severity":  max((i.get("severity") or 0) for i in items) if items else 0,
    }


@app.get("/api/kpi/sparklines")
async def api_kpi_sparklines(days: int = 14):
    """7-14d series for the top KPIs surfaced in the ribbon. Used for
    inline SVG sparklines next to each headline number."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        rows = await c.fetch("""
          SELECT report_date,
                 total_revenue,
                 labour_cost_est,
                 in_house_count,
                 pub_net_sales,
                 sandwich_net_sales,
                 accom_revenue
            FROM v_daily_unit_economics
           WHERE report_date >= CURRENT_DATE - ($1::int)
           ORDER BY report_date ASC
        """, days)

    def _f(v): return float(v) if v is not None else None

    return {
        "days":     days,
        "dates":    [r["report_date"].isoformat() for r in rows],
        "revenue":  [_f(r["total_revenue"])      for r in rows],
        "labour":   [_f(r["labour_cost_est"])    for r in rows],
        "in_house": [_f(r["in_house_count"])     for r in rows],
        "pub":      [_f(r["pub_net_sales"])      for r in rows],
        "cafe":     [_f(r["sandwich_net_sales"]) for r in rows],
        "accom":    [_f(r["accom_revenue"])      for r in rows],
    }


@app.get("/api/vehicles")
async def api_vehicles():
    """U51 T5 — vehicles + 30-day expiry alerts. U66 — also surfaces docs
    linked to each vehicle (auto-linked at upload by plate regex, or manual)."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())
        rows = await c.fetch("""
          SELECT v.id, v.registration, v.make_model, v.year_built, v.v5c_doc_ref,
                 v.mot_due, v.insurance_renewal, v.road_tax_due,
                 v.service_due_date, v.service_due_miles, v.current_miles,
                 v.entity_id, v.notes, v.updated_at,
                 COALESCE(d.n, 0) AS doc_count
            FROM vehicles v
            LEFT JOIN (
                SELECT linked_id, COUNT(*) AS n
                  FROM documents
                 WHERE linked_table = 'vehicles'
                 GROUP BY linked_id
            ) d ON d.linked_id = v.id
            ORDER BY v.registration
        """)
        alerts = await c.fetch("""
          SELECT vehicle_id, registration, make_model, kind, due, days_until
            FROM v_vehicle_alerts
        """)
        docs = await c.fetch("""
          SELECT id, title, category, linked_id, linked_by, created_at,
                 mime_type, LENGTH(coalesce(ocr_text, '')) AS ocr_chars
            FROM documents
           WHERE linked_table = 'vehicles'
           ORDER BY linked_id, created_at DESC
        """)

    def _row(r):
        out = {}
        for k, v in dict(r).items():
            if hasattr(v, "isoformat"): out[k] = v.isoformat()
            else: out[k] = v
        return out

    return {"rows":   [_row(r) for r in rows],
            "alerts": [_row(a) for a in alerts],
            "docs":   [_row(d) for d in docs]}


# ─── U54 D — Manager notes + till-reconciliation resolve ─────────
from fastapi import Body

@app.post("/api/manager-notes")
async def api_manager_notes_create(payload: dict = Body(...)):
    """U54 D: post a manager note for a date (any author can write).
    Body: {note_date: 'YYYY-MM-DD', body: '...', author?: '...', tags?: [...]}"""
    note_date_str = (payload.get("note_date") or "").strip()
    body = (payload.get("body") or "").strip()
    author = (payload.get("author") or "web-/m").strip()
    tags = payload.get("tags") or []
    if not note_date_str or not body:
        return JSONResponse({"error": "note_date and body required"}, status_code=400)
    try:
        note_date = datetime.strptime(note_date_str, "%Y-%m-%d").date()
    except ValueError:
        return JSONResponse({"error": "note_date must be YYYY-MM-DD"}, status_code=400)
    p = await pool()
    async with p.acquire() as c:
        async with c.transaction():
            await c.execute("SELECT home_ai.set_realm('work')")
            await c.execute("SET LOCAL app.current_entity = '1'")
            row = await c.fetchrow("""
              INSERT INTO manager_notes (entity_id, note_date, body, author, tags)
              VALUES (1, $1, $2, $3, $4::jsonb)
              RETURNING id, note_date, body, author, created_at
            """, note_date, body, author, json.dumps(tags))
    return {"id": row["id"], "note_date": row["note_date"].isoformat(),
            "body": row["body"], "author": row["author"],
            "created_at": row["created_at"].isoformat()}


@app.get("/api/manager-notes")
async def api_manager_notes_list(days: int = 14):
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = '1'")
        rows = await c.fetch("""
          SELECT id, note_date, body, author, created_at
            FROM manager_notes
           WHERE note_date >= CURRENT_DATE - ($1::int)
           ORDER BY note_date DESC, created_at DESC
           LIMIT 30
        """, days)
    return {"rows": [{"id": r["id"],
                       "note_date": r["note_date"].isoformat(),
                       "body": r["body"],
                       "author": r["author"],
                       "created_at": r["created_at"].isoformat()} for r in rows]}


@app.post("/api/till-recon")
async def api_till_recon_create(payload: dict = Body(...)):
    """U71 T1: record a till-reconciliation row from /m.
    Body: {site, recon_date, session, z_reading, card_total, cash_counted,
           float_returned, staff_notes}. site ∈ {pub,cafe,other}."""
    site = (payload.get("site") or "pub").strip().lower()
    if site not in ("pub", "cafe", "other"):
        return JSONResponse({"error": "site must be pub|cafe|other"}, status_code=400)
    recon_date_str = (payload.get("recon_date") or "").strip()
    if not recon_date_str:
        return JSONResponse({"error": "recon_date required"}, status_code=400)
    try:
        recon_date = datetime.strptime(recon_date_str, "%Y-%m-%d").date()
    except ValueError:
        return JSONResponse({"error": "recon_date must be YYYY-MM-DD"}, status_code=400)
    session = (payload.get("session") or "day").strip().lower() or "day"

    def _num(k):
        v = payload.get(k)
        if v in (None, ""):
            return None
        try:
            return float(v)
        except (TypeError, ValueError):
            return None

    z_reading     = _num("z_reading")
    card_total    = _num("card_total")
    cash_counted  = _num("cash_counted")
    float_returned= _num("float_returned")
    expected_cash = _num("expected_cash")
    staff_notes   = (payload.get("staff_notes") or "").strip() or None

    # Variance computed only when we have both expected and counted.
    variance = None
    variance_pct = None
    status = 'ok'
    if cash_counted is not None and expected_cash is not None:
        variance = round(cash_counted - expected_cash, 2)
        if expected_cash:
            variance_pct = round(variance / expected_cash * 100.0, 3)
        if abs(variance) > 5:
            status = 'flagged'

    idem = f"manual:{site}:{recon_date_str}:{session}"

    p = await pool()
    async with p.acquire() as c:
        async with c.transaction():
            await c.execute("SELECT home_ai.set_realm('work')")
            await c.execute("SET LOCAL app.current_entity = '1'")
            row = await c.fetchrow("""
                INSERT INTO till_reconciliation
                    (idempotency_key, recon_date, session, site,
                     z_reading, card_total, cash_counted, float_returned,
                     expected_cash, variance, variance_pct, status, staff_notes,
                     entity_id, realm)
                VALUES ($1, $2, $3, $4,
                        $5, $6, $7, $8,
                        $9, $10, $11, $12, $13,
                        1, 'work')
                ON CONFLICT (idempotency_key) DO UPDATE
                   SET z_reading     = EXCLUDED.z_reading,
                       card_total    = EXCLUDED.card_total,
                       cash_counted  = EXCLUDED.cash_counted,
                       float_returned= EXCLUDED.float_returned,
                       expected_cash = EXCLUDED.expected_cash,
                       variance      = EXCLUDED.variance,
                       variance_pct  = EXCLUDED.variance_pct,
                       status        = EXCLUDED.status,
                       staff_notes   = EXCLUDED.staff_notes
                RETURNING id, recon_date, site, session, variance, status
            """, idem, recon_date, session, site,
                 z_reading, card_total, cash_counted, float_returned,
                 expected_cash, variance, variance_pct, status, staff_notes)
    return {"id": row["id"], "recon_date": row["recon_date"].isoformat(),
            "site": row["site"], "session": row["session"],
            "variance": float(row["variance"]) if row["variance"] is not None else None,
            "status": row["status"]}


@app.post("/api/till-recon/{recon_id}/resolve")
async def api_till_recon_resolve(recon_id: int, payload: dict = Body(default={})):
    """U54 D: mark a flagged till_reconciliation row as resolved with a note."""
    note = (payload.get("note") or "").strip()
    if not note:
        return JSONResponse({"error": "note required"}, status_code=400)
    p = await pool()
    async with p.acquire() as c:
        async with c.transaction():
            await c.execute("SELECT home_ai.set_realm('work')")
            await c.execute("SET LOCAL app.current_entity = '1'")
            row = await c.fetchrow("""
              UPDATE till_reconciliation
                 SET status='resolved',
                     staff_notes = COALESCE(staff_notes || E'\\n', '') ||
                                   '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || '] ' || $2
               WHERE id = $1 AND status='flagged'
               RETURNING id, recon_date, status
            """, recon_id, note)
    if row is None:
        return JSONResponse({"error": "not found or already resolved"}, status_code=404)
    return {"id": row["id"], "recon_date": row["recon_date"].isoformat(),
            "status": row["status"]}


@app.get("/api/economics/overview")
async def api_economics_overview(days: int = 90):
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        kpi = await c.fetchrow("SELECT * FROM v_live_ops_kpis")
        rows = await c.fetch("""
          SELECT * FROM v_daily_unit_economics
           WHERE report_date >= CURRENT_DATE - ($1::int)
           ORDER BY report_date DESC
        """, days)
        thresholds = await c.fetch("SELECT * FROM ops_thresholds")

    def _row(r):
        if r is None: return None
        out = {}
        for k, v in dict(r).items():
            if hasattr(v, "isoformat"): out[k] = v.isoformat()
            elif hasattr(v, "to_eng_string"): out[k] = str(v)
            else: out[k] = v
        return out

    return {
        "window_days": days,
        "kpi":         _row(kpi),
        "rows":        [_row(r) for r in rows],
        "thresholds":  [_row(t) for t in thresholds],
    }


# ─────────────────────────────────────────────────────────────────────────────
# U31 — Viewer endpoints (email, pdf, snapshot) for table click-through
# ─────────────────────────────────────────────────────────────────────────────
import re as _re
import os as _os

_GOOGLE_FETCH_URL = "http://google-fetch:8011"
_SNAPSHOT_ROOTS = (
    "/home_ai/storage/scraper-debug",
    "/home_ai/storage/caterbook-samples",
)


def _safe_under(path: str) -> str | None:
    """Resolve `path` against the snapshot roots; return absolute path only if
    it stays inside one of them. Else None (block traversal)."""
    p = _os.path.realpath(path)
    for root in _SNAPSHOT_ROOTS:
        if p.startswith(_os.path.realpath(root) + "/"):
            return p
    return None


@app.get("/viewer/email/{account}/{message_id}")
async def viewer_email(account: str, message_id: str):
    """Render a Gmail message body inline. HTML is wrapped in a sandboxed
    iframe to neutralise external content. Plain-text fallback rendered as
    <pre> below."""
    import httpx, base64, html as _html
    async with httpx.AsyncClient(timeout=15) as c:
        r = await c.get(f"{_GOOGLE_FETCH_URL}/message/{account}/{message_id}")
    if r.status_code != 200:
        return HTMLResponse(f"<p>Failed to fetch: HTTP {r.status_code}</p>",
                            status_code=r.status_code)
    msg = r.json()
    hdrs = {h["name"].lower(): h["value"] for h in msg.get("payload", {}).get("headers", [])}
    subject = hdrs.get("subject", "(no subject)")
    from_  = hdrs.get("from", "(no sender)")
    date   = hdrs.get("date", "")

    text_body = None
    html_body = None
    def walk(part):
        nonlocal text_body, html_body
        mt = part.get("mimeType", "")
        body = part.get("body") or {}
        if body.get("data"):
            b = body["data"]; pad = "=" * (-len(b) % 4)
            try:
                decoded = base64.urlsafe_b64decode(b + pad).decode("utf-8", errors="replace")
            except Exception:
                decoded = ""
            if mt == "text/plain" and text_body is None: text_body = decoded
            elif mt == "text/html" and html_body is None: html_body = decoded
        for sub in part.get("parts", []) or []:
            walk(sub)
    walk(msg.get("payload", {}))

    # iframe-sandbox the HTML body — neutralises forms, scripts, top-level navs
    safe_html = (html_body or "").replace("</body", "").replace("</html", "")
    iframe_doc = f"""
<!doctype html><html><head><meta charset="utf-8"></head>
<body style="font-family:system-ui;color:#1e293b;background:#fff;margin:8px">{safe_html}</body></html>
"""
    iframe_src = "data:text/html;base64," + base64.b64encode(iframe_doc.encode()).decode()

    page = f"""<!doctype html>
<html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{_html.escape(subject)}</title>
<script src="https://cdn.tailwindcss.com"></script>
<style>body{{background:radial-gradient(ellipse at top,#0f172a,#020617 60%);min-height:100vh;color:#e2e8f0;font-family:system-ui}}</style>
</head>
<body>
<div class="max-w-4xl mx-auto p-4 md:p-6 space-y-4">
  <div class="glass" style="background:rgba(15,23,42,0.7);backdrop-filter:blur(10px);border:1px solid rgba(148,163,184,0.15);border-radius:12px;padding:1rem">
    <div class="text-xs uppercase tracking-wide text-slate-400">Email</div>
    <h1 class="text-xl font-semibold">{_html.escape(subject)}</h1>
    <div class="text-sm text-slate-400 mt-1">From: <span class="font-mono">{_html.escape(from_)}</span></div>
    <div class="text-sm text-slate-400">Date: <span class="font-mono">{_html.escape(date)}</span></div>
    <div class="text-xs text-slate-500 mt-2">message_id: <span class="font-mono">{_html.escape(message_id)}</span></div>
  </div>
  <div class="glass" style="background:rgba(15,23,42,0.7);backdrop-filter:blur(10px);border:1px solid rgba(148,163,184,0.15);border-radius:12px;overflow:hidden">
    {"<iframe sandbox style='width:100%;min-height:500px;border:0;background:#fff' src='" + iframe_src + "'></iframe>" if html_body else ""}
    {("<pre style='padding:1rem;white-space:pre-wrap;font-size:0.875rem;color:#cbd5e1;background:rgba(2,6,23,0.4)'>" + _html.escape(text_body or "(no plain-text body)") + "</pre>") if (text_body and not html_body) else ""}
  </div>
</div></body></html>"""
    return HTMLResponse(page)


@app.get("/viewer/snapshot/{filename}")
async def viewer_snapshot(filename: str):
    """Stream an HTML or PNG snapshot file from the whitelisted directories."""
    candidate = None
    for root in _SNAPSHOT_ROOTS:
        candidate_path = _os.path.join(root, filename)
        if _safe_under(candidate_path) and _os.path.exists(candidate_path):
            candidate = candidate_path; break
    if candidate is None:
        raise HTTPException(404, "snapshot not found")
    return FileResponse(candidate)


@app.get("/viewer/pdf")
async def viewer_pdf(path: str):
    """Stream a PDF — `path` must resolve under a whitelisted root."""
    safe = _safe_under(path)
    if safe is None or not safe.endswith(".pdf") or not _os.path.exists(safe):
        raise HTTPException(404, "pdf not found")
    return FileResponse(safe, media_type="application/pdf")


# ─────────────────────────────────────────────────────────────────────────────
# U30 — Workforce.com (Tanda) labour data
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/workforce")
async def workforce_page():
    return FileResponse(str(STATIC / "workforce.html"))


@app.get("/api/workforce/overview")
async def api_workforce_overview(days: int = 30):
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        coverage = await c.fetchrow("""
          SELECT COUNT(*) AS shifts,
                 COUNT(DISTINCT user_external_id) AS staff,
                 ROUND(SUM(hours_worked)::numeric, 1) AS total_hours,
                 MIN(shift_date) AS earliest, MAX(shift_date) AS latest
            FROM workforce_shifts
        """)
        per_day = await c.fetch("""
          SELECT shift_date, COUNT(*) AS shifts,
                 ROUND(SUM(hours_worked)::numeric, 1) AS hours,
                 COUNT(DISTINCT user_external_id) AS staff
            FROM workforce_shifts
           WHERE shift_date >= CURRENT_DATE - ($1::int)
           GROUP BY shift_date ORDER BY shift_date DESC
        """, days)
        per_dept = await c.fetch("""
          SELECT s.department_external_id AS dept,
                 d.name AS dept_name,
                 d.team,
                 COUNT(*) AS shifts,
                 ROUND(SUM(s.hours_worked)::numeric, 1) AS hours,
                 COUNT(DISTINCT s.user_external_id) AS staff
            FROM workforce_shifts s
            LEFT JOIN workforce_departments d ON d.external_id = s.department_external_id
           WHERE s.shift_date >= CURRENT_DATE - ($1::int)
           GROUP BY s.department_external_id, d.name, d.team
           ORDER BY hours DESC NULLS LAST
        """, days)
        per_team = await c.fetch("""
          SELECT team,
                 ROUND(SUM(hours)::numeric, 1)             AS hours,
                 ROUND(SUM(cost_with_oncost)::numeric, 2)  AS cost_with_oncost,
                 SUM(staff_count)                          AS staff_count,
                 ROUND(AVG(avg_cost_per_hr)::numeric, 2)   AS avg_cost_per_hr
            FROM v_daily_labour_by_team
           WHERE report_date >= CURRENT_DATE - ($1::int)
           GROUP BY team
           ORDER BY hours DESC NULLS LAST
        """, days)
        top_staff = await c.fetch("""
          SELECT s.user_external_id, s.full_name,
                 COUNT(*)                                AS shifts,
                 ROUND(SUM(s.hours_worked)::numeric, 1)  AS hours,
                 ROUND(SUM(s.shift_cost)::numeric, 0)    AS shift_cost
            FROM v_workforce_shifts_costed s
           WHERE s.shift_date >= CURRENT_DATE - ($1::int)
           GROUP BY s.user_external_id, s.full_name
           ORDER BY hours DESC NULLS LAST LIMIT 20
        """, days)
        recent_sync = await c.fetch("""
          SELECT endpoint, http_status, records_seen, records_inserted, records_updated,
                 error_message, runtime_ms, started_at
            FROM workforce_sync_log
           ORDER BY started_at DESC LIMIT 20
        """)

    def _row(r):
        out = {}
        for k, v in dict(r).items():
            if hasattr(v, "isoformat"): out[k] = v.isoformat()
            elif hasattr(v, "to_eng_string"): out[k] = str(v)
            else: out[k] = v
        return out

    return {
        "window_days": days,
        "coverage":    _row(coverage) if coverage else {},
        "per_day":     [_row(r) for r in per_day],
        "per_dept":    [_row(r) for r in per_dept],
        "per_team":    [_row(r) for r in per_team],
        "top_staff":   [_row(r) for r in top_staff],
        "recent_sync": [_row(r) for r in recent_sync],
    }


@app.get("/api/workforce/rota_today")
async def api_workforce_rota_today():
    """U45/U47b — who's on today (or the most-recently-loaded shift date if
    today's rota hasn't synced yet). Returns shifts with names, team, cost."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = '1'")
        # Pick the target date: today if any shift exists, else the latest date with data
        target = await c.fetchval("""
          SELECT MAX(shift_date) FROM workforce_shifts
          WHERE shift_date <= CURRENT_DATE
        """)
        if target is None:
            return {"items": [], "total_hours": 0, "total_cost": 0, "staff_count": 0,
                    "shift_date": None, "is_today": False}
        rows = await c.fetch("""
          SELECT s.id, s.shift_date,
                 s.full_name AS name, s.preferred_name,
                 s.team AS dept_name, s.team,
                 s.start_time, s.end_time, s.hours_worked,
                 s.shift_cost AS cost_with_oncost,
                 s.cost_source
            FROM v_workforce_shifts_costed s
           WHERE s.shift_date = $1
           ORDER BY s.team, s.start_time
        """, target)
    def _row(r):
        out = {}
        for k, v in dict(r).items():
            if hasattr(v, "isoformat"): out[k] = v.isoformat()
            elif hasattr(v, "to_eng_string"): out[k] = float(v)
            else: out[k] = v
        return out
    items = [_row(r) for r in rows]
    total_hours = sum(i.get("hours_worked") or 0 for i in items)
    total_cost  = sum(i.get("cost_with_oncost") or 0 for i in items)
    from datetime import date as _d2
    return {
        "items": items,
        "total_hours": round(total_hours, 1),
        "total_cost":  round(total_cost, 2),
        "staff_count": len(items),
        "shift_date":  target.isoformat() if target else None,
        "is_today":    target == _d2.today() if target else False,
    }


@app.get("/api/workforce/income_vs_cost")
async def api_workforce_income_vs_cost(date_from: str = "", date_to: str = ""):
    """U45 — per-team labour cost vs the income stream it serves.
    Cafe team ↔ sandwich_net_sales
    Front-of-house + Kitchen ↔ pub_net_sales (food + drink combined)
    Housekeeping ↔ accom_revenue"""
    from datetime import date as _d, timedelta as _td
    if not date_from or not date_to:
        t = _d.today(); date_from_d = t - _td(days=7); date_to_d = t
    else:
        date_from_d = _d.fromisoformat(date_from); date_to_d = _d.fromisoformat(date_to)
    date_from = date_from_d.isoformat(); date_to = date_to_d.isoformat()
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = '1'")
        team_rows = await c.fetch("""
          SELECT team, SUM(hours)::numeric(12,2) AS hours, SUM(cost_with_oncost)::numeric(12,2) AS cost
            FROM v_daily_labour_by_team
           WHERE report_date BETWEEN $1::date AND $2::date
           GROUP BY team
        """, date_from_d, date_to_d)
        rev_row = await c.fetchrow("""
          SELECT SUM(pub_net_sales)::numeric(12,2)      AS pub_total,
                 SUM(sandwich_net_sales)::numeric(12,2) AS cafe_total,
                 SUM(accom_revenue)::numeric(12,2)      AS accom_total
            FROM v_daily_unit_economics
           WHERE report_date BETWEEN $1::date AND $2::date
        """, date_from_d, date_to_d)
    teams = {r["team"]: dict(r) for r in team_rows}
    def f(v): return float(v) if v is not None else 0.0
    rev = dict(rev_row) if rev_row else {}
    cafe_cost  = f(teams.get("cafe", {}).get("cost"))
    foh_cost   = f(teams.get("front_of_house", {}).get("cost"))
    kitchen_cost = f(teams.get("kitchen", {}).get("cost"))
    house_cost = f(teams.get("accommodation", {}).get("cost"))
    cafe_inc   = f(rev.get("cafe_total"))
    pub_inc    = f(rev.get("pub_total"))
    accom_inc  = f(rev.get("accom_total"))
    def pct(num, denom): return round(100*num/denom, 1) if denom > 0 else None
    return {
        "from": date_from, "to": date_to,
        "cafe":          {"income": cafe_inc,  "cost": cafe_cost,  "pct": pct(cafe_cost, cafe_inc)},
        "foh_kitchen":   {"income": pub_inc,   "cost": foh_cost + kitchen_cost,  "pct": pct(foh_cost+kitchen_cost, pub_inc)},
        "kitchen_food":  {"income": pub_inc * 0.4,  "cost": kitchen_cost,  "pct": pct(kitchen_cost, pub_inc*0.4),
                          "note": "Food assumed 40% of pub_net — proxy until department_sales mapping confirmed"},
        "foh_drink":     {"income": pub_inc * 0.6,  "cost": foh_cost,     "pct": pct(foh_cost, pub_inc*0.6),
                          "note": "Drink assumed 60% of pub_net — proxy"},
        "housekeeping":  {"income": accom_inc, "cost": house_cost, "pct": pct(house_cost, accom_inc)},
    }


@app.get("/api/workforce/forecast_vs_actual")
async def api_workforce_forecast_vs_actual(days: int = 14):
    """U47b — forecast (sum of shifts) vs actual (workforce_timesheets) per week.
    workforce_timesheets is period-level so we collapse shifts into the same
    timesheet windows for a like-for-like comparison."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = '1'")
        rows = await c.fetch("""
          WITH ts AS (
            SELECT period_start, period_end,
                   SUM(hours_total) AS actual_hours,
                   SUM(cost_total)  AS actual_cost
              FROM workforce_timesheets
             WHERE period_end >= CURRENT_DATE - ($1::int)
             GROUP BY period_start, period_end
          ),
          fc AS (
            SELECT ts.period_start, ts.period_end,
                   SUM(s.hours_worked) AS forecast_hours,
                   SUM(s.shift_cost)   AS forecast_cost
              FROM ts
              LEFT JOIN v_workforce_shifts_costed s
                ON s.shift_date BETWEEN ts.period_start AND ts.period_end
             GROUP BY ts.period_start, ts.period_end
          )
          SELECT ts.period_start, ts.period_end,
                 fc.forecast_hours, fc.forecast_cost,
                 ts.actual_hours, ts.actual_cost,
                 (ts.actual_hours - fc.forecast_hours)             AS hours_variance,
                 (ts.actual_cost  - fc.forecast_cost)              AS cost_variance,
                 CASE WHEN fc.forecast_cost > 0
                      THEN ROUND(100*(ts.actual_cost - fc.forecast_cost)/fc.forecast_cost, 1)
                 END                                               AS cost_variance_pct
            FROM ts JOIN fc USING (period_start, period_end)
           ORDER BY ts.period_end DESC
        """, days)
    items = []
    for r in rows:
        d = dict(r)
        for k, v in d.items():
            if hasattr(v, "isoformat"): d[k] = v.isoformat()
            elif hasattr(v, "to_eng_string"): d[k] = float(v)
        items.append(d)
    note = ("Forecast = sum of workforce_shifts (rota) in the timesheet window. "
            "Actual = workforce_timesheets.")
    if not items:
        note = ("⚠ No timesheet data yet — Tanda /api/v2/timesheets sync is not "
                "configured. Only the /shifts endpoint (rota) is being pulled, "
                "so we can't compute variance until the timesheets sync is enabled.")
    return {"days": days, "items": items, "note": note}


@app.get("/api/workforce/sales_per_hour")
async def api_workforce_sales_per_hour(date_from: str = "", date_to: str = ""):
    """U47b — per-staff attributable sales leaderboard over a window.
    Sales apportioned by each staff member's share of their team's daily hours.
    FoH gets a shared_attribution flag because they handle both food and drink."""
    from datetime import date as _d, timedelta as _td
    if not date_from or not date_to:
        t = _d.today(); date_from_d = t - _td(days=7); date_to_d = t
    else:
        date_from_d = _d.fromisoformat(date_from); date_to_d = _d.fromisoformat(date_to)
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = '1'")
        rows = await c.fetch(
          "SELECT * FROM staff_sales_window($1::date, $2::date)",
          date_from_d, date_to_d,
        )
    items = []
    rank_by_team = {}
    for r in rows:
        d = dict(r)
        for k, v in d.items():
            if hasattr(v, "to_eng_string"): d[k] = float(v)
        team = d.get("team")
        rank_by_team.setdefault(team, 0)
        rank_by_team[team] += 1
        d["rank_within_team"] = rank_by_team[team]
        items.append(d)
    return {
        "from":  date_from_d.isoformat(),
        "to":    date_to_d.isoformat(),
        "items": items,
        "count": len(items),
        "note":  "FoH staff have shared_attribution=true (food + drink). Sales apportioned by share of team daily hours.",
    }


@app.get("/api/accommodation/adr")
async def api_accommodation_adr(date_from: str = "", date_to: str = ""):
    """U45 — Average Daily Rate + max/min per room over the window."""
    from datetime import date as _d, timedelta as _td
    if not date_from or not date_to:
        t = _d.today(); date_from_d = t - _td(days=30); date_to_d = t
    else:
        date_from_d = _d.fromisoformat(date_from); date_to_d = _d.fromisoformat(date_to)
    date_from = date_from_d.isoformat(); date_to = date_to_d.isoformat()
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = '1'")
        adr_row = await c.fetchrow("""
          SELECT
            ROUND(AVG(rate_per_night) FILTER (WHERE rate_per_night > 0)::numeric, 2) AS adr,
            ROUND(AVG(rate_per_night)::numeric, 2) AS adr_inc_zero,
            COUNT(*) FILTER (WHERE rate_per_night > 0) AS nights_paid,
            COUNT(*) AS nights_total
          FROM caterbook_room_nights
          WHERE night_date BETWEEN $1::date AND $2::date
        """, date_from_d, date_to_d)
        per_room = await c.fetch("""
          SELECT room,
                 MIN(rate_per_night) FILTER (WHERE rate_per_night > 0) AS min_rate,
                 MAX(rate_per_night) AS max_rate,
                 ROUND(AVG(rate_per_night) FILTER (WHERE rate_per_night > 0)::numeric, 2) AS avg_rate,
                 COUNT(*) AS nights
            FROM caterbook_room_nights
           WHERE night_date BETWEEN $1::date AND $2::date
           GROUP BY room ORDER BY room
        """, date_from_d, date_to_d)

    def _row(r):
        out = {}
        for k, v in dict(r).items():
            if hasattr(v, "isoformat"): out[k] = v.isoformat()
            elif hasattr(v, "to_eng_string"): out[k] = float(v)
            else: out[k] = v
        return out
    return {
        "from": date_from, "to": date_to,
        "adr": _row(adr_row) if adr_row else {},
        "per_room": [_row(r) for r in per_room],
    }


@app.get("/api/accommodation/occupancy_now")
async def api_accommodation_occupancy_now():
    """U45 — current occupancy grid: list of rooms + whether each is occupied tonight."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = '1'")
        # Today's snapshot has arrivals + stayovers JSON; departures have already left.
        snap = await c.fetchrow("""
          SELECT report_date, arrivals, stayovers, departures, in_house_count
            FROM caterbook_daily_snapshots
           ORDER BY report_date DESC LIMIT 1
        """)
        total_rooms = await c.fetchval(
          "SELECT value_num::int FROM ops_constants WHERE key='inn_total_rooms'")
    if not snap:
        return {"items": [], "total_rooms": total_rooms or 9}
    arrivals = snap["arrivals"] or []
    stayovers = snap["stayovers"] or []
    # Each in-house room is identified by room name + guest
    occupied = {}
    import json as _json
    for src, label in [(arrivals, 'arrival'), (stayovers, 'stayover')]:
        if isinstance(src, str):
            try: src = _json.loads(src)
            except: src = []
        for g in src or []:
            room = g.get("room")
            if not room: continue
            occupied[room] = {"guest": g.get("guest"), "status": label,
                              "depart": g.get("dep"), "balance": g.get("balance")}
    # All room labels seen historically + the 9 numbered + Flat
    known_rooms = ["Rm1","Rm2","Rm3","Rm4","Rm5","Rm6","Rm7","Rm8","suite-9","Flat"]
    items = []
    for r in known_rooms:
        if r in occupied:
            items.append({"room": r, "occupied": True, **occupied[r]})
        else:
            items.append({"room": r, "occupied": False})
    return {
        "snapshot_date": snap["report_date"].isoformat(),
        "in_house_count": snap["in_house_count"],
        "total_rooms": total_rooms or 9,
        "items": items,
    }


# ─────────────────────────────────────────────────────────────────────────────
# U29 — Vendor invoice triage (light-touch inbox)
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/invoices")
async def invoices_page():
    return FileResponse(str(STATIC / "invoices.html"))


@app.get("/invoices/needs-review")
async def invoices_needs_review_page():
    return FileResponse(str(STATIC / "invoices-needs-review.html"))


@app.get("/api/invoices/needs-review")
async def api_invoices_needs_review():
    """U75 — slim feed of vendor_invoice_inbox rows in 'needs_review' for the
    triage page. Returns all rows regardless of date so backlog is visible."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        rows = await c.fetch("""
          SELECT id, vendor_name, vendor_domain, subject, received_at::date AS received_date,
                 invoice_date, amount_seen, net_amount, vat_amount, gross_amount,
                 extraction_method, extraction_confidence, has_pdf, attachment_count,
                 first_attachment_path, paperless_doc_id
            FROM vendor_invoice_inbox
           WHERE status = 'needs_review'
           ORDER BY received_at DESC NULLS LAST
        """)
    out = []
    for r in rows:
        row = {}
        for k, v in dict(r).items():
            if hasattr(v, 'isoformat'):    row[k] = v.isoformat()
            elif hasattr(v, 'to_eng_string'): row[k] = str(v)
            else: row[k] = v
        out.append(row)
    return {"n": len(out), "rows": out}


@app.post("/api/invoices/{invoice_id}/mark")
async def api_invoices_mark(invoice_id: int, payload: dict = Body(...)):
    """U75 — change vendor_invoice_inbox.status. Body: {status: 'extracted'|'ignored'|'needs_review'|'new'}"""
    new_status = (payload.get("status") or "").strip().lower()
    if new_status not in ('extracted', 'ignored', 'needs_review', 'new'):
        return JSONResponse({"error": "status must be one of extracted|ignored|needs_review|new"}, status_code=400)
    p = await pool()
    async with p.acquire() as c:
        async with c.transaction():
            await c.execute("SELECT home_ai.set_realm('work')")
            await c.execute("SET LOCAL app.current_entity = 'all'")
            row = await c.fetchrow("""
                UPDATE vendor_invoice_inbox
                   SET status = $1
                 WHERE id = $2
                 RETURNING id, status
            """, new_status, invoice_id)
    if not row:
        return JSONResponse({"error": "not found"}, status_code=404)
    return {"id": row["id"], "status": row["status"]}


@app.get("/api/invoices/list")
async def api_invoices_list(
    days: int = 90,
    status: str = "",
    date_from: str = "",
    date_to: str = "",
    site: str = "all",          # all | pub | cafe
):
    """U45 — accepts either `days=N` (legacy) or `date_from`/`date_to` (ISO),
    and a site filter that maps to entity_id (pub=1, cafe=1 with cafe bucket filter)."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        # Date window: explicit from/to wins; else fall back to `days`.
        #
        # U84 (2026-05-16): For an explicit from/to window the filter uses
        # the INVOICE date (delivery_date preferred, else invoice_date) —
        # NEVER received_at. Rows with no extracted invoice date are excluded
        # so a Jan invoice imported in March doesn't pollute the Jan filter.
        # For the rolling "last N days" view we keep received_at since the
        # intent is "stuff that arrived recently."
        from datetime import date as _date
        if date_from and date_to:
            date_clause = "COALESCE(delivery_date, invoice_date) BETWEEN $1::date AND $2::date"
            date_args = [_date.fromisoformat(date_from), _date.fromisoformat(date_to)]
            window_label = f"{date_from} → {date_to}"
        else:
            date_clause = "received_at >= CURRENT_DATE - ($1::int)"
            date_args = [days]
            window_label = f"last {days} days"

        # Site filter: pub = pub-kitchen + wet/dry + head office;
        #              cafe = anything tagged site='cafe' (incl. MAL125 rows
        #              backfilled in V103) or category_canonical='cafe_stock';
        #              all  = everything.
        site_clause = ""
        if site == "cafe":
            site_clause = " AND (site = 'cafe' OR category_canonical = 'cafe_stock')"
        elif site == "pub":
            site_clause = (" AND (site = 'pub'"
                           " OR (site IS NULL"
                           "     AND (category_canonical <> 'cafe_stock' OR category_canonical IS NULL)"
                           "     AND entity_id = 1))")
        # status filter
        status_clause = ""
        extra_args = []
        if status:
            status_clause = f" AND status = ${len(date_args) + 1}"
            extra_args = [status]

        rows = await c.fetch(f"""
          SELECT id, source_email_id, account, vendor_domain, vendor_name,
                 vendor_category, category_canonical, subject, received_at, amount_seen,
                 net_amount, vat_amount, gross_amount, currency,
                 invoice_date, delivery_date, due_date, status, is_statement,
                 has_pdf, attachment_count, first_attachment_path,
                 linked_invoice_id, notes
            FROM vendor_invoice_inbox
           WHERE {date_clause}
           {site_clause}
           {status_clause}
           -- U84: ORDER BY prefers invoice/delivery date; falls back to
           -- received_at as a tiebreaker so undated rows still sort sanely
           -- (display will say '—' for the date, so user knows the row lacks it).
           ORDER BY COALESCE(delivery_date, invoice_date) DESC NULLS LAST,
                    received_at DESC
           LIMIT 500
        """, *date_args, *extra_args)
        by_vendor = await c.fetch("""
          SELECT vendor_domain, COUNT(*) AS n,
                 COUNT(*) FILTER (WHERE status='new')  AS pending,
                 COUNT(*) FILTER (WHERE status='paid') AS paid,
                 SUM(amount_seen) FILTER (WHERE amount_seen IS NOT NULL) AS total_seen
            FROM vendor_invoice_inbox
           WHERE received_at >= CURRENT_DATE - ($1::int)
           GROUP BY vendor_domain ORDER BY n DESC
        """, days)
        by_category = await c.fetch("""
          SELECT vendor_category, COUNT(*) AS n,
                 COUNT(*) FILTER (WHERE status='new')  AS pending,
                 SUM(amount_seen) FILTER (WHERE amount_seen IS NOT NULL) AS total_seen,
                 ARRAY_AGG(DISTINCT vendor_domain) AS vendors
            FROM vendor_invoice_inbox
           WHERE received_at >= CURRENT_DATE - ($1::int)
           GROUP BY vendor_category ORDER BY total_seen DESC NULLS LAST, n DESC
        """, days)
        totals = await c.fetchrow("""
          SELECT COUNT(*) AS total,
                 COUNT(*) FILTER (WHERE status='new') AS pending,
                 SUM(amount_seen) FILTER (WHERE amount_seen IS NOT NULL) AS sum_seen,
                 COUNT(DISTINCT vendor_category) AS categories
            FROM vendor_invoice_inbox
           WHERE received_at >= CURRENT_DATE - ($1::int)
        """, days)

    def _row(r):
        out = {}
        for k, v in dict(r).items():
            if hasattr(v, "isoformat"): out[k] = v.isoformat()
            elif hasattr(v, "to_eng_string"): out[k] = str(v)
            else: out[k] = v
        return out

    return {
        "window_days": days,
        "totals":      _row(totals) if totals else {},
        "by_vendor":   [_row(r) for r in by_vendor],
        "by_category": [_row(r) for r in by_category],
        "invoices":    [_row(r) for r in rows],
    }


# ─────────────────────────────────────────────────────────────────────────────
# U28 — Caterbook email-driven accommodation data (Pipeline 6)
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/caterbook")
async def caterbook_page():
    return FileResponse(str(STATIC / "caterbook.html"))


@app.get("/api/caterbook/overview")
async def api_caterbook_overview(days: int = 30):
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        coverage = await c.fetchrow("""
          SELECT COUNT(DISTINCT report_date) AS days_loaded,
                 MIN(report_date) AS earliest,
                 MAX(report_date) AS latest,
                 COUNT(*) AS email_count
            FROM caterbook_email_reports
        """)
        latest = await c.fetchrow("""
          SELECT report_date, arrivals, stayovers, departures,
                 arrivals_count, stayovers_count, departures_count,
                 in_house_count, revenue_in_house
            FROM caterbook_daily_snapshots
           ORDER BY report_date DESC LIMIT 1
        """)
        per_day = await c.fetch("""
          SELECT report_date, arrivals_count, stayovers_count, departures_count,
                 in_house_count, revenue_in_house
            FROM caterbook_daily_snapshots
           WHERE report_date >= CURRENT_DATE - ($1::int)
           ORDER BY report_date DESC
        """, days)
        # Revenue per room per night, last N days, summed.
        per_room = await c.fetch("""
          SELECT room, COUNT(*) AS nights,
                 ROUND(SUM(rate_per_night)::numeric, 2) AS revenue,
                 ROUND(AVG(rate_per_night)::numeric, 2) AS avg_rate
            FROM caterbook_room_nights
           WHERE night_date >= CURRENT_DATE - ($1::int)
           GROUP BY room ORDER BY revenue DESC NULLS LAST
        """, days)
        # Heatmap data: room × night_date matrix of rate_per_night
        heatmap = await c.fetch("""
          SELECT room, night_date, rate_per_night
            FROM caterbook_room_nights
           WHERE night_date >= CURRENT_DATE - ($1::int)
           ORDER BY room, night_date
        """, days)
        recent_imports = await c.fetch("""
          SELECT report_date, source_email_id, account, received_at,
                 arrivals_count, stayovers_count, departures_count
            FROM caterbook_email_reports
           ORDER BY received_at DESC LIMIT 30
        """)

    def _row(r):
        if r is None:
            return None
        out = {}
        for k, v in dict(r).items():
            if hasattr(v, "isoformat"):     out[k] = v.isoformat()
            elif hasattr(v, "to_eng_string"): out[k] = str(v)
            else: out[k] = v
        return out

    return {
        "window_days":     days,
        "coverage":        _row(coverage),
        "latest_snapshot": _row(latest),
        "per_day":         [_row(r) for r in per_day],
        "per_room":        [_row(r) for r in per_room],
        "heatmap":         [_row(r) for r in heatmap],
        "recent_imports":  [_row(r) for r in recent_imports],
    }


# ─────────────────────────────────────────────────────────────────────────────
# U27 — TouchOffice browser-scraped data (Pipeline 5)
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/touchoffice")
async def touchoffice_page():
    return FileResponse(str(STATIC / "touchoffice.html"))


@app.get("/api/touchoffice/overview")
async def api_touchoffice_overview(days: int = 30):
    """Summary + per-day NET sales/covers across both sites for the last N days."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        coverage = await c.fetch("""
          SELECT site,
                 COUNT(DISTINCT report_date) AS days_loaded,
                 MIN(report_date)            AS earliest,
                 MAX(report_date)            AS latest
            FROM touchoffice_fixed_totals
           GROUP BY site
           ORDER BY site
        """)
        recent_scrapes = await c.fetch("""
          SELECT site, report_date, widget, success, rows_written, error_message, scraped_at
            FROM touchoffice_scrapes
           ORDER BY scraped_at DESC
           LIMIT 30
        """)
        per_day = await c.fetch(f"""
          SELECT report_date, site,
                 (SELECT value    FROM touchoffice_fixed_totals f WHERE f.site=t.site AND f.report_date=t.report_date AND f.label='NET sales') AS net_sales,
                 (SELECT value    FROM touchoffice_fixed_totals f WHERE f.site=t.site AND f.report_date=t.report_date AND f.label='GROSS Sales') AS gross_sales,
                 (SELECT quantity FROM touchoffice_fixed_totals f WHERE f.site=t.site AND f.report_date=t.report_date AND f.label='Covers') AS covers,
                 (SELECT COUNT(*) FROM touchoffice_department_sales d WHERE d.site=t.site AND d.report_date=t.report_date) AS depts,
                 (SELECT COUNT(*) FROM touchoffice_plu_sales p WHERE p.site=t.site AND p.report_date=t.report_date) AS plus
            FROM (SELECT DISTINCT site, report_date FROM touchoffice_fixed_totals
                   WHERE report_date >= CURRENT_DATE - ($1::int)) t
           ORDER BY report_date DESC, site
        """, days)
        top_depts = await c.fetch("""
          SELECT site, department, SUM(value)::numeric(14,2) AS total,
                 SUM(quantity)::numeric(14,2) AS qty
            FROM touchoffice_department_sales
           WHERE report_date >= CURRENT_DATE - ($1::int)
           GROUP BY site, department
           ORDER BY site, total DESC
           LIMIT 40
        """, days)
        top_plus = await c.fetch("""
          SELECT site, plu_number, descriptor,
                 SUM(value)::numeric(14,2) AS total,
                 SUM(quantity)::numeric(14,2) AS qty
            FROM touchoffice_plu_sales
           WHERE report_date >= CURRENT_DATE - ($1::int)
           GROUP BY site, plu_number, descriptor
           ORDER BY total DESC
           LIMIT 50
        """, days)
    # Stringify dates + decimals so the response is JSON-encodable by FastAPI's
    # default encoder regardless of which path renders it.
    def _row(r):
        out = {}
        for k, v in dict(r).items():
            if hasattr(v, "isoformat"):
                out[k] = v.isoformat()
            elif hasattr(v, "to_eng_string"):  # decimal.Decimal
                out[k] = str(v)
            else:
                out[k] = v
        return out
    return {
        "window_days":     days,
        "coverage":        [_row(r) for r in coverage],
        "recent_scrapes":  [_row(r) for r in recent_scrapes],
        "per_day":         [_row(r) for r in per_day],
        "top_departments": [_row(r) for r in top_depts],
        "top_plus":        [_row(r) for r in top_plus],
    }


@app.get("/api/pub/snapshot")
async def pub_snapshot():
    """U47a — Pub-side metrics from real tables (caterbook + touchoffice).
    The legacy epos_daily/accommodation_* tables are stubs and were always
    empty. We now read from touchoffice_fixed_totals + caterbook_bookings /
    caterbook_room_nights directly."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        today_epos = await c.fetchrow("""
          SELECT
            COALESCE(SUM(value) FILTER (WHERE label = 'GROSS Sales'), 0)::numeric(10,2) AS gross,
            COALESCE(SUM(value) FILTER (WHERE label = 'NET sales'),  0)::numeric(10,2) AS net,
            COALESCE(SUM(value) FILTER (WHERE label = 'Covers'),     0)::numeric        AS covers
          FROM touchoffice_fixed_totals
          WHERE report_date = CURRENT_DATE
        """)
        today_accom = await c.fetchrow("""
          SELECT
            COUNT(DISTINCT room)::int                          AS rooms_occupied,
            COALESCE(SUM(rate_per_night), 0)::numeric(10,2)    AS room_revenue
          FROM caterbook_room_nights
          WHERE night_date = CURRENT_DATE
        """)
        rooms_total = 7   # Malthouse has 7 rooms (kept as constant; promote to entity meta later)
        today_bookings = await c.fetchrow("""
          SELECT
            COUNT(*) FILTER (WHERE first_seen::date = CURRENT_DATE)            AS new_today,
            COALESCE(SUM(total_amount) FILTER (WHERE first_seen::date = CURRENT_DATE), 0)::numeric(10,2) AS gross_today
          FROM caterbook_bookings
        """)
        arrivals_today = await c.fetch("""
          SELECT ref AS id, guest_name, room,
                 'caterbook' AS source, total_amount,
                 'GBP' AS currency
            FROM caterbook_bookings
           WHERE arrival_date = CURRENT_DATE
           ORDER BY guest_name LIMIT 10
        """)
        departures_tomorrow = await c.fetch("""
          SELECT ref AS id, guest_name, room,
                 'caterbook' AS source, total_amount,
                 'GBP' AS currency
            FROM caterbook_bookings
           WHERE departure_date = CURRENT_DATE + INTERVAL '1 day'
           ORDER BY guest_name LIMIT 10
        """)
        week_calendar = await c.fetch("""
          WITH days AS (
            SELECT generate_series(
                     date_trunc('week', CURRENT_DATE)::date,
                     date_trunc('week', CURRENT_DATE)::date + 6,
                     '1 day'
                   )::date AS d
          )
          SELECT days.d AS day,
                 COUNT(DISTINCT rn.ref) FILTER (WHERE rn.night_date = days.d) AS confirmed,
                 0::bigint AS cancelled,
                 COALESCE(SUM(rn.rate_per_night) FILTER (WHERE rn.night_date = days.d), 0)::numeric(10,2) AS gross
            FROM days
            LEFT JOIN caterbook_room_nights rn ON rn.night_date = days.d
           GROUP BY days.d
           ORDER BY days.d
        """)
        channel_mix_14d = await c.fetch("""
          SELECT COALESCE(rate_code, 'direct') AS source,
                 COUNT(*)                       AS bookings,
                 COALESCE(SUM(total_amount), 0)::numeric(10,2) AS gross
            FROM caterbook_bookings
           WHERE arrival_date BETWEEN CURRENT_DATE - INTERVAL '14 days'
                                  AND CURRENT_DATE + INTERVAL '14 days'
           GROUP BY 1
           ORDER BY bookings DESC LIMIT 8
        """)
        epos_sparkline = await c.fetch("""
          SELECT report_date::text AS d,
                 SUM(value) FILTER (WHERE label = 'GROSS Sales')::numeric(10,2) AS v
            FROM touchoffice_fixed_totals
           WHERE report_date >= CURRENT_DATE - INTERVAL '14 days'
           GROUP BY report_date ORDER BY report_date
        """)
        occ_sparkline = await c.fetch("""
          SELECT night_date::text AS d,
                 (COUNT(DISTINCT room) * 100.0 / 7)::numeric(5,1) AS v
            FROM caterbook_room_nights
           WHERE night_date >= CURRENT_DATE - INTERVAL '14 days'
           GROUP BY night_date ORDER BY night_date
        """)
        # Synthesise a single-row "today_accom" with occupancy_pct
        today_accom = {
            "occupancy_pct": (float(today_accom["rooms_occupied"]) * 100.0 / rooms_total) if today_accom else 0,
            "rooms_occupied": today_accom["rooms_occupied"] if today_accom else 0,
            "total_rooms": rooms_total,
            "room_revenue": today_accom["room_revenue"] if today_accom else 0,
        }

    def row_to(rs):
        return [dict(r) for r in rs]

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "today": {
            "date":             datetime.now(timezone.utc).date().isoformat(),
            "epos_gross":       float(today_epos["gross"]) if today_epos else 0,
            "epos_net":         float(today_epos["net"])   if today_epos else 0,
            "epos_covers":      int(today_epos["covers"])  if today_epos and today_epos["covers"] is not None else 0,
            "epos_sessions":    1 if today_epos and float(today_epos["gross"] or 0) > 0 else 0,
            "occupancy_pct":    today_accom["occupancy_pct"],
            "rooms_occupied":   today_accom["rooms_occupied"],
            "total_rooms":      today_accom["total_rooms"],
            "room_revenue":     float(today_accom["room_revenue"]),
            "new_bookings":     today_bookings["new_today"],
            "bookings_gross":   float(today_bookings["gross_today"]),
        },
        "arrivals_today":       row_to(arrivals_today),
        "departures_tomorrow":  row_to(departures_tomorrow),
        "week_calendar":        [{"day": str(r["day"]), "confirmed": r["confirmed"],
                                  "cancelled": r["cancelled"], "gross": float(r["gross"])}
                                 for r in week_calendar],
        "channel_mix_14d":      [{"source": r["source"], "bookings": r["bookings"],
                                  "gross": float(r["gross"])} for r in channel_mix_14d],
        "sparklines": {
            "epos_gross_14d":   [{"d": r["d"], "v": float(r["v"])} for r in epos_sparkline],
            "occupancy_14d":    [{"d": r["d"], "v": float(r["v"])} for r in occ_sparkline],
        },
    }


# ─────────────────────────────────────────────────────────────────────────────
# U20 — Dead Letter Forensics
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/forensics")
async def forensics_page():
    return FileResponse(str(STATIC / "forensics.html"))


@app.get("/api/forensics/dead-letters")
async def forensics_list(limit: int = Query(50, ge=1, le=200)):
    """Unresolved dead letters with the most useful diagnostic fields."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        rows = await c.fetch("""
          SELECT dl.id          AS dl_id,
                 dl.event_id,
                 dl.pipeline,
                 dl.error_message,
                 dl.retry_count,
                 dl.created_at,
                 e.event_type,
                 e.source        AS event_source,
                 e.status        AS event_status,
                 e.payload,
                 e.trace_id,
                 EXTRACT(EPOCH FROM (NOW() - dl.created_at)) / 3600 AS age_hours
            FROM dead_letter dl
            LEFT JOIN events e ON e.id = dl.event_id
           WHERE dl.resolved = false
           ORDER BY dl.created_at DESC
           LIMIT $1
        """, limit)
    import json as _json
    def _payload(p):
        if p is None:
            return None
        if isinstance(p, str):
            try: return _json.loads(p)
            except Exception: return {"_raw": p}
        return dict(p) if hasattr(p, 'items') else p
    return {"items": [dict(r) | {"created_at": r["created_at"].isoformat() if r["created_at"] else None,
                                  "trace_id": str(r["trace_id"]) if r["trace_id"] else None,
                                  "payload": _payload(r["payload"]),
                                  "age_hours": round(float(r["age_hours"]), 1) if r["age_hours"] is not None else None}
                       for r in rows]}


def _payload_dict(p):
    """asyncpg returns jsonb as either dict or str depending on version. Normalise."""
    if p is None:
        return None
    if isinstance(p, str):
        import json as _json
        try: return _json.loads(p)
        except Exception: return {"_raw": p}
    return dict(p) if hasattr(p, 'items') else p


@app.get("/api/forensics/event/{event_id}")
async def forensics_event(event_id: int):
    """Drill-down for one event: full payload, downstream-presence check,
    related audit_log entries."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        ev = await c.fetchrow("""
          SELECT id, event_type, source, status, payload, payload_signature,
                 trace_id, parent_event_id, idempotency_key, pipeline_version,
                 retry_count, processing_started_at, processing_node_id,
                 created_at, processed_at
            FROM events WHERE id = $1
        """, event_id)
        if not ev:
            return JSONResponse({"error": "event not found"}, status_code=404)

        # Downstream presence check (mirrors recover_stale_leases_v2 logic)
        downstream = {"present": False, "table": None, "row_id": None}
        et = ev["event_type"]
        payload = _payload_dict(ev["payload"]) or {}
        if et == "email.received":
            row = await c.fetchrow(
                "SELECT id FROM emails WHERE gmail_message_id = $1",
                payload.get("gmail_message_id"))
            if row:
                downstream = {"present": True, "table": "emails", "row_id": row["id"]}
        elif et == "invoice.detected":
            row = await c.fetchrow(
                "SELECT id FROM invoices WHERE event_id = $1", event_id)
            if row:
                downstream = {"present": True, "table": "invoices", "row_id": row["id"]}
        elif et == "accommodation.report.detected":
            row = await c.fetchrow(
                "SELECT id FROM accommodation_daily WHERE email_id = $1 OR source_event_id = $2",
                payload.get("email_id"), event_id)
            if row:
                downstream = {"present": True, "table": "accommodation_daily", "row_id": row["id"]}
        elif et == "epos.report.detected":
            row = await c.fetchrow(
                "SELECT id FROM epos_daily WHERE email_id = $1 OR source_event_id = $2",
                payload.get("email_id"), event_id)
            if row:
                downstream = {"present": True, "table": "epos_daily", "row_id": row["id"]}

        # Audit chain
        audit = await c.fetch("""
          SELECT id, pipeline, action, result, error_msg, created_at
            FROM audit_log
           WHERE event_id = $1 OR trace_id = $2
           ORDER BY created_at DESC LIMIT 30
        """, event_id, ev["trace_id"])

        # Children
        children = await c.fetch("""
          SELECT id, event_type, status, created_at
            FROM events WHERE parent_event_id = $1
           ORDER BY created_at LIMIT 20
        """, event_id)

    def ser(rs):
        out = []
        for r in rs:
            d = dict(r)
            for k, v in list(d.items()):
                if hasattr(v, "isoformat"):
                    d[k] = v.isoformat()
            out.append(d)
        return out

    return {
        "event": {
            "id": ev["id"], "event_type": ev["event_type"], "source": ev["source"],
            "status": ev["status"], "trace_id": str(ev["trace_id"]) if ev["trace_id"] else None,
            "parent_event_id": ev["parent_event_id"], "idempotency_key": ev["idempotency_key"],
            "pipeline_version": ev["pipeline_version"], "retry_count": ev["retry_count"],
            "processing_started_at": ev["processing_started_at"].isoformat() if ev["processing_started_at"] else None,
            "processing_node_id": ev["processing_node_id"],
            "created_at": ev["created_at"].isoformat() if ev["created_at"] else None,
            "processed_at": ev["processed_at"].isoformat() if ev["processed_at"] else None,
            "payload": _payload_dict(payload),
        },
        "downstream": downstream,
        "audit": ser(audit),
        "children": ser(children),
    }


@app.post("/api/forensics/resolve")
async def forensics_resolve(dl_id: int = Query(...),
                            verdict: str = Query("downstream_ok", pattern="^(downstream_ok|needs_review|requeued)$"),
                            note: str = Query("")):
    """Mark a dead letter resolved. Three verdicts:
       downstream_ok — false positive, data exists downstream
       needs_review  — kept open, just adds a note
       requeued      — also flip the event back to status=pending so it retries
    """
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = 'all'")
        if verdict == "needs_review":
            await c.execute(
                "UPDATE dead_letter SET resolution_notes = COALESCE(resolution_notes,'') || E'\\n' || $2 WHERE id = $1",
                dl_id, f"[{datetime.now(timezone.utc).isoformat()}] {note}".strip())
            return {"updated": True, "verdict": "needs_review"}
        elif verdict == "downstream_ok":
            await c.execute("""
                UPDATE dead_letter SET resolved = true, resolved_at = NOW(),
                       resolution_notes = COALESCE(resolution_notes,'') || E'\\nforensics:downstream_ok ' || $2
                 WHERE id = $1
            """, dl_id, note)
            ev_id = await c.fetchval("SELECT event_id FROM dead_letter WHERE id = $1", dl_id)
            if ev_id:
                await c.execute(
                    "UPDATE events SET status = 'processed', processed_at = COALESCE(processed_at, NOW()) WHERE id = $1 AND status = 'failed'",
                    ev_id)
            return {"updated": True, "verdict": "downstream_ok"}
        elif verdict == "requeued":
            ev_id = await c.fetchval("SELECT event_id FROM dead_letter WHERE id = $1", dl_id)
            if not ev_id:
                return JSONResponse({"error": "no event for dl_id"}, status_code=400)
            await c.execute("""
                UPDATE events SET status = 'pending',
                                  processing_started_at = NULL,
                                  processing_node_id = NULL,
                                  retry_count = 0
                 WHERE id = $1
            """, ev_id)
            await c.execute("""
                UPDATE dead_letter SET resolved = true, resolved_at = NOW(),
                       resolution_notes = COALESCE(resolution_notes,'') || E'\\nforensics:requeued ' || $2
                 WHERE id = $1
            """, dl_id, note)
            return {"updated": True, "verdict": "requeued", "event_id": ev_id}


@app.get("/api/benchmark/stream")
async def benchmark_stream(model: str = Query("qwen2.5:7b"),
                           tier: str  = Query("hot", pattern="^(hot|medium|heavy)$")):
    """Server-Sent Events: streams stdout from /app/run_benchmark.py inside
    the model-evaluator container. Each SSE event is one stdout line."""
    cmd = ["/usr/local/bin/docker", "exec",
           "-e", "PYTHONUNBUFFERED=1",
           "homeai-model-evaluator",
           "python", "-u", "/app/run_benchmark.py",
           "--model", model, "--tier", tier]

    async def gen():
        proc = await asp.create_subprocess_exec(
            *cmd, stdout=asp.PIPE, stderr=asp.STDOUT)
        try:
            while True:
                line = await proc.stdout.readline()
                if not line:
                    break
                # SSE event format: "data: <line>\n\n"
                yield f"data: {line.decode('utf-8', errors='replace').rstrip()}\n\n"
            await proc.wait()
            yield f"event: done\ndata: exit_code={proc.returncode}\n\n"
        finally:
            if proc.returncode is None:
                proc.terminate()

    return StreamingResponse(
        gen(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


# ─────────────────────────────────────────────────────────────────────────────
# U60 — Finance dashboard
# ─────────────────────────────────────────────────────────────────────────────
# /finance is a unified board over:
#   - bank_accounts + bank_transactions   (NatWest + RBS Mastercards)
#   - card_statements                     (V73)
#   - account_transfers                   (V73 — paired inter-account moves)
#   - vendor_invoice_inbox + dojo_transactions (already-ingested feeds)
#
# Three modes of interaction:
#   1. Headline KPI ribbon from v_finance_kpis (single GET).
#   2. Pre-canned tabs (Balances, Owings, Transfers, Costs, Recent) — each
#      tab calls one slug directly via /api/finance/slug/{slug}.
#   3. NL textbox → /api/finance/ask. Haiku-4.5 tool-use loop picks one of
#      the query_whitelist finance slugs and we run it server-side.

ANTHROPIC_MODEL = "claude-haiku-4-5-20251001"
# Match :param but not :: (PG type-cast). Negative lookbehind excludes the
# second colon of ::interval, ::int, ::numeric, etc.
_NAMED_PARAM_RE = re.compile(r"(?<!:):([a-zA-Z_][a-zA-Z0-9_]*)")


async def _vault_read(path: str) -> dict | None:
    token = os.environ.get("VAULT_TOKEN")
    if not token:
        return None
    try:
        async with httpx.AsyncClient(timeout=4.0) as c:
            r = await c.get(f"{VAULT_URL}/v1/secret/data/{path}",
                            headers={"X-Vault-Token": token})
            r.raise_for_status()
            return r.json()["data"]["data"]
    except Exception:
        return None


async def _load_finance_slugs(conn) -> list[dict]:
    """Approved finance slugs in query_whitelist, owner realm visible."""
    rows = await conn.fetch("""
        SELECT id, slug, display_name, description, intent_examples,
               sql_template, param_schema, result_format
          FROM query_whitelist
         WHERE active = true AND approved_at IS NOT NULL
           AND slug IN ('interest_paid_window','fees_paid_window','account_balances',
                        'owings_summary','monthly_finance_costs','top_vendors_window',
                        'transfers_recent','spend_by_category_window','credit_card_status',
                        'recent_finance_events','finance_kpis','top_purchases_window',
                        'mortgages_summary','mortgages_all','capital_summary',
                        'net_worth_summary','mortgage_coverage',
                        -- U84 Phase 2 additions
                        'today_kpis_work','today_kpis_private','action_queue',
                        -- U84 Phase 5 additions (build hub)
                        'build_pipeline_status','build_model_spend_30d',
                        'build_forensic_summary',
                        -- U84 Phase 3 additions (work tabs)
                        'work_docs_kpis','work_staff_kpis','work_email_kpis',
                        -- U84 Phase 4 additions (private tabs)
                        'private_family_kpis','private_docs_kpis',
                        -- U84 Phase 7 additions (telemetry)
                        'route_telemetry_7d',
                        -- U84 private docs detail lists
                        'private_vehicles',
                        -- U85 Phase D2 (desktop sections)
                        'today_bookings','today_pub_sales',
                        -- U85 Phase D3 (docs/vendors)
                        'recent_invoices','vendor_site_rules',
                        'noise_senders','cost_centre_breakdown',
                        -- U85 Phase D9 (placeholder slugs wired)
                        'children','email_tasks_open','bot_instructions_pending',
                        'labour_recent_14d','ghost_shifts_recent','daily_gp_recent',
                        -- U98 source breakdown
                        'today_bookings_by_source',
                        -- U101 restaurant reservations
                        'today_restaurant')
         ORDER BY slug
    """)
    out = []
    for r in rows:
        out.append({
            "id":              r["id"],
            "slug":            r["slug"],
            "display_name":    r["display_name"],
            "description":     r["description"],
            "intent_examples": list(r["intent_examples"] or []),
            "sql_template":    r["sql_template"],
            "param_schema":    (r["param_schema"] if isinstance(r["param_schema"], dict)
                                else json.loads(r["param_schema"] or "{}")),
            "result_format":   r["result_format"],
        })
    return out


def _bind_params(param_schema: dict, supplied: dict) -> tuple[bool, Any]:
    """Validate + coerce. Returns (ok, bound_or_error_msg)."""
    bound = {}
    for name, spec in (param_schema or {}).items():
        if name in supplied and supplied[name] is not None and supplied[name] != "":
            v = supplied[name]
        elif spec.get("required"):
            return False, f"missing required param '{name}'"
        elif "default" in spec:
            v = spec["default"]
        else:
            continue
        t = spec.get("type", "string")
        try:
            if   t == "int":   v = int(v)
            elif t == "float": v = float(v)
            elif t == "bool":  v = bool(v)
            elif t == "enum":
                if v not in spec.get("values", []):
                    return False, f"{name}={v!r} not in {spec.get('values')}"
            else:
                v = str(v)
        except (ValueError, TypeError) as e:
            return False, f"{name}={v!r}: {e}"
        if "min" in spec and v < spec["min"]:
            return False, f"{name}={v} < min {spec['min']}"
        if "max" in spec and v > spec["max"]:
            return False, f"{name}={v} > max {spec['max']}"
        bound[name] = v
    extras = set(supplied) - set(param_schema or {})
    # ignore unknown params silently to be forgiving on the dashboard side
    return True, bound


async def _run_slug(slug_row: dict, bound: dict) -> dict:
    sql = slug_row["sql_template"]
    seen: list[str] = []
    def repl(m):
        n = m.group(1)
        if n not in seen:
            seen.append(n)
        return f"${seen.index(n) + 1}"
    sql_pg = _NAMED_PARAM_RE.sub(repl, sql)
    args = [bound[n] for n in seen]
    p = await pool()
    async with p.acquire() as c:
        async with c.transaction(readonly=True):
            await c.execute("SET LOCAL app.current_entity = 'all'")
            await c.execute("SELECT home_ai.set_realm($1)", _current_realm.get())
            rows = await c.fetch(sql_pg, *args)
    return {
        "slug": slug_row["slug"],
        "display_name": slug_row["display_name"],
        "params": bound,
        "n_rows": len(rows),
        "rows": [_isoify({k: r[k] for k in r.keys()}) for r in rows],
    }


@app.get("/finance")
async def finance_page():
    return FileResponse(str(STATIC / "finance.html"))


@app.get("/recon")
async def recon_page():
    return FileResponse(str(STATIC / "recon.html"))


@app.get("/api/recon/summary")
async def api_recon_summary(window_days: int = 30):
    """U69 T3: top-of-page tiles for /recon — counts per level + cash variance."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SELECT set_config('app.current_entity','all',false)")
        await c.execute("SELECT set_config('app.current_realm','owner',false)")
        l1 = await c.fetchrow("""
            SELECT
              COUNT(*) FILTER (WHERE status='ok')          AS ok,
              COUNT(*) FILTER (WHERE status='minor')       AS minor,
              COUNT(*) FILTER (WHERE status='mismatch')    AS mismatch,
              COUNT(*) FILTER (WHERE status='approximate') AS approximate,
              COUNT(*)                                     AS total
            FROM mart.daily_totals
            WHERE transaction_date >= current_date - $1::int
        """, window_days)
        l2 = await c.fetchrow("""
            SELECT
              COUNT(*) FILTER (WHERE kind='l2_phantom_refund')      AS phantom,
              COUNT(*) FILTER (WHERE kind='l2_unlinked_refund')     AS unlinked,
              COUNT(*) FILTER (WHERE kind='l2_elevated_risk_mode')  AS elevated,
              COUNT(*) FILTER (WHERE kind='l2_outsized_amount')     AS outsized
            FROM mart.exceptions
            WHERE kind LIKE 'l2_%' AND status='open'
              AND transaction_date >= current_date - $1::int
        """, window_days)
        l3 = await c.fetchrow("""
            SELECT
              COUNT(*) FILTER (WHERE status='settled_clean')    AS clean,
              COUNT(*) FILTER (WHERE status='settled_short')    AS short,
              COUNT(*) FILTER (WHERE status='unsettled_5d')     AS unsettled_5d,
              COUNT(*) FILTER (WHERE status='unsettled_open')   AS open,
              (SUM(expected_amount_minor) FILTER (WHERE status='unsettled_5d') / 100.0)::numeric(12,2)
                                                                AS unsettled_gbp
            FROM mart.expected_settlements
            WHERE batch_date >= current_date - $1::int
        """, window_days)
        cv = await c.fetchrow("""
            SELECT (SUM(variance_minor)/100.0)::numeric(12,2)   AS sum_variance_gbp,
                   COUNT(*) FILTER (WHERE variance_minor < -500) AS days_short_over_5
            FROM mart.cash_variance
            WHERE operator_id='_aggregate_day'
              AND transaction_date >= current_date - $1::int
        """, window_days)
    return {
        "window_days": window_days,
        "l1": _isoify(dict(l1) if l1 else {}),
        "l2": _isoify(dict(l2) if l2 else {}),
        "l3": _isoify(dict(l3) if l3 else {}),
        "cash_variance": _isoify(dict(cv) if cv else {}),
    }


@app.get("/api/recon/exceptions")
async def api_recon_exceptions(window_days: int = 30, status: str = "open"):
    """U69 T3: mart.exceptions filtered + sorted for Tabulator."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SELECT set_config('app.current_entity','all',false)")
        await c.execute("SELECT set_config('app.current_realm','owner',false)")
        rows = await c.fetch("""
            SELECT id, raised_at, severity, kind, source, site, transaction_date,
                   summary, status
              FROM mart.exceptions
             WHERE status = $1
               AND raised_at >= now() - ($2::int || ' days')::interval
             ORDER BY severity DESC, raised_at DESC LIMIT 500
        """, status, window_days)
    return {"rows": [_isoify(dict(r)) for r in rows], "window_days": window_days, "status": status}


@app.get("/api/recipes/sales-vs-consumption")
async def api_recipes_sales_vs_consumption(weeks: int = 8, family: str = ""):
    """U66 T3: sales→consumption from recipe expansion vs invoice purchases.
    Returns weekly rows per product_canonical, oldest→newest within window."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SELECT set_config('app.current_entity','all',false)")
        params = [weeks]
        where  = ["week >= current_date - ($1::int * 7)::int"]
        if family.strip():
            where.append("family = $2")
            params.append(family.strip())
        rows = await c.fetch(f"""
          SELECT week, product_canonical_id, product_name, family, base_unit,
                 implied_consumption::numeric AS used,
                 purchased::numeric           AS bought,
                 gap::numeric                 AS gap,
                 gap_pct
            FROM v_consumption_vs_purchase
           WHERE {' AND '.join(where)}
           ORDER BY week ASC, product_name
        """, *params)
    return {"rows": [_isoify(dict(r)) for r in rows], "weeks": weeks, "family_filter": family or None}


@app.get("/api/recipes/list")
async def api_recipes_list():
    """Inventory of recipes + components for the UI."""
    rows = await db_all("""
        SELECT r.id, r.plu_number, r.name, r.menu_section, r.portion_unit,
               json_agg(json_build_object(
                  'product_canonical_id', rc.product_canonical_id,
                  'product_name', pc.name,
                  'quantity_per_portion', rc.quantity_per_portion,
                  'unit', rc.base_unit
               ) ORDER BY rc.id) AS components
          FROM recipes r
          JOIN recipe_components rc ON rc.recipe_id = r.id
          JOIN product_canonical pc ON pc.id = rc.product_canonical_id
         GROUP BY r.id ORDER BY r.menu_section, r.name
    """)
    return {"rows": [_isoify(dict(r)) for r in rows]}


@app.get("/api/finance/kpis")
async def finance_kpis():
    row = await db_one("SELECT * FROM v_finance_kpis")
    return _isoify(dict(row)) if row else {}


@app.get("/api/finance/slugs")
async def finance_slugs():
    """List of finance slugs available to the dashboard."""
    p = await pool()
    async with p.acquire() as c:
        slugs = await _load_finance_slugs(c)
    # Strip SQL templates from the public list — clients only need names+params.
    return [{"slug": s["slug"], "display_name": s["display_name"],
             "description": s["description"], "intent_examples": s["intent_examples"],
             "param_schema": s["param_schema"]} for s in slugs]


@app.get("/api/finance/slug/{slug}")
async def finance_slug_run(slug: str, request: Request):
    """Run a finance slug directly. Query-string params bind into SQL."""
    p = await pool()
    async with p.acquire() as c:
        slugs = await _load_finance_slugs(c)
    row = next((s for s in slugs if s["slug"] == slug), None)
    if not row:
        return JSONResponse({"error": f"unknown slug {slug!r}"}, status_code=404)
    ok, bound = _bind_params(row["param_schema"], dict(request.query_params))
    if not ok:
        return JSONResponse({"error": bound}, status_code=400)
    return await _run_slug(row, bound)


class _AskBody:
    """Lightweight pydantic-free body parser to avoid touching imports."""
    def __init__(self, question: str):
        self.question = question


@app.post("/api/finance/ask")
async def finance_ask(body: dict = Body(...)):
    """Natural-language entry point. Routes the question to Haiku-tool-use,
    runs the picked slug, and returns rows + a one-line narrative."""
    question = (body.get("question") or "").strip()
    if not question:
        return JSONResponse({"error": "missing 'question'"}, status_code=400)

    anth = await _vault_read("anthropic")
    api_key = (anth or {}).get("api_key")
    if not api_key:
        return JSONResponse({"error": "anthropic key not available; "
                                       "VAULT_TOKEN missing or vault sealed"},
                            status_code=503)

    p = await pool()
    async with p.acquire() as c:
        slugs = await _load_finance_slugs(c)
    if not slugs:
        return JSONResponse({"error": "no finance slugs registered"}, status_code=500)

    # Build the Anthropic tool list from slugs.
    tools = []
    for s in slugs:
        props = {}
        required = []
        for name, spec in (s["param_schema"] or {}).items():
            t = spec.get("type", "string")
            jt = {"int": "integer", "float": "number", "bool": "boolean",
                  "enum": "string", "string": "string", "str": "string"}.get(t, "string")
            prop = {"type": jt}
            if "default" in spec:
                prop["description"] = f"default {spec['default']}"
            if spec.get("required"):
                required.append(name)
            props[name] = prop
        tools.append({
            "name": s["slug"],
            "description": (s["description"] or "")
                + (("\nExamples: " + "; ".join(s["intent_examples"])) if s["intent_examples"] else ""),
            "input_schema": {"type": "object", "properties": props, "required": required},
        })

    system = ("You are Jo's home-finance assistant. The user is Jo Sandercock who runs a pub, "
              "a sandwich bar, an accommodation business and a property company. Use the "
              "provided data tools to answer the question. Never invent numbers. If no tool "
              "fits, reply directly with a short sentence explaining what's missing. Keep "
              "your final reply to 1-3 sentences. Money is in GBP, formatted £x,xxx.xx.")

    messages = [{"role": "user", "content": question}]

    headers = {
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    }

    tool_results = []
    async with httpx.AsyncClient(timeout=60.0) as client:
        for _ in range(3):  # max 3 tool-use turns
            payload = {
                "model": ANTHROPIC_MODEL,
                "max_tokens": 1024,
                "system": system,
                "tools": tools,
                "messages": messages,
            }
            r = await client.post("https://api.anthropic.com/v1/messages",
                                  headers=headers, json=payload)
            if r.status_code != 200:
                return JSONResponse(
                    {"error": "anthropic API error",
                     "status": r.status_code, "body": r.text[:400]},
                    status_code=502)
            resp = r.json()

            blocks = resp.get("content") or []
            messages.append({"role": "assistant", "content": blocks})

            if resp.get("stop_reason") != "tool_use":
                narrative = "".join(
                    b.get("text", "") for b in blocks if b.get("type") == "text"
                ).strip()
                return {
                    "question": question,
                    "narrative": narrative or "(no narrative)",
                    "tool_results": tool_results,
                    "stop_reason": resp.get("stop_reason"),
                }

            # Execute every tool_use block in this assistant turn.
            tool_use_blocks = [b for b in blocks if b.get("type") == "tool_use"]
            tool_result_msgs = []
            for tu in tool_use_blocks:
                slug = tu.get("name")
                slug_row = next((s for s in slugs if s["slug"] == slug), None)
                if not slug_row:
                    tool_result_msgs.append({
                        "type": "tool_result", "tool_use_id": tu["id"],
                        "is_error": True,
                        "content": f"unknown tool {slug!r}",
                    })
                    continue
                ok, bound = _bind_params(slug_row["param_schema"], tu.get("input") or {})
                if not ok:
                    tool_result_msgs.append({
                        "type": "tool_result", "tool_use_id": tu["id"],
                        "is_error": True, "content": f"param error: {bound}",
                    })
                    continue
                try:
                    run = await _run_slug(slug_row, bound)
                except Exception as e:
                    tool_result_msgs.append({
                        "type": "tool_result", "tool_use_id": tu["id"],
                        "is_error": True, "content": f"SQL error: {e}",
                    })
                    continue
                tool_results.append(run)
                # Truncate rows in the message back to Anthropic to stay cheap.
                preview_rows = run["rows"][:40]
                tool_result_msgs.append({
                    "type": "tool_result", "tool_use_id": tu["id"],
                    "content": json.dumps({"n_rows": run["n_rows"],
                                            "rows_preview": preview_rows},
                                           default=str)[:6000],
                })
            messages.append({"role": "user", "content": tool_result_msgs})

    return {
        "question": question,
        "narrative": "(tool-loop did not converge after 3 turns)",
        "tool_results": tool_results,
    }
