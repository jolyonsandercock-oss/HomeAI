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
import os
import re
import subprocess
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import asyncpg
import httpx
import yaml
from fastapi import FastAPI, Query
from fastapi.responses import FileResponse, JSONResponse, HTMLResponse
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
def load_yaml(name: str) -> dict:
    p = DATA / name
    if not p.exists():
        return {}
    return yaml.safe_load(p.read_text()) or {}

# ─── Postgres pool ──────────────────────────────────────────────
_pool: asyncpg.Pool | None = None

async def pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(PG_DSN, min_size=1, max_size=4)
    return _pool

async def db_one(sql: str, *args):
    p = await pool()
    async with p.acquire() as c:
        return await c.fetchrow(sql, *args)

async def db_all(sql: str, *args):
    p = await pool()
    async with p.acquire() as c:
        return await c.fetch(sql, *args)

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
            WHERE p.relname = 'events')                                     AS event_partitions
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

@app.get("/")
async def root():
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
    inside /home_ai/storage/invoices."""
    p = await pool()
    async with p.acquire() as c:
        await c.execute("SET app.current_entity = '1'")
        path = await c.fetchval(
            "SELECT first_attachment_path FROM vendor_invoice_inbox WHERE id=$1",
            invoice_id,
        )
    if not path:
        return JSONResponse({"error": "no PDF on disk for this invoice (may not yet be extracted)"}, status_code=404)
    real = _os.path.realpath(path)
    if not real.startswith(_os.path.realpath(_INVOICE_STORAGE_ROOT) + "/"):
        return JSONResponse({"error": "path traversal blocked"}, status_code=403)
    if not _os.path.exists(real):
        return JSONResponse({"error": "file not found on disk"}, status_code=404)
    return FileResponse(real, media_type="application/pdf",
                        filename=_os.path.basename(real))


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
        from datetime import date as _date
        if date_from and date_to:
            date_clause = "COALESCE(delivery_date, invoice_date, received_at::date) BETWEEN $1::date AND $2::date"
            date_args = [_date.fromisoformat(date_from), _date.fromisoformat(date_to)]
            window_label = f"{date_from} → {date_to}"
        else:
            date_clause = "received_at >= CURRENT_DATE - ($1::int)"
            date_args = [days]
            window_label = f"last {days} days"

        # Site filter: pub = wet+dry+head_office (entity 1, excluding cafe_stock);
        #              cafe = cafe_stock category only;
        #              all  = everything.
        site_clause = ""
        if site == "cafe":
            site_clause = " AND category_canonical = 'cafe_stock'"
        elif site == "pub":
            site_clause = " AND (category_canonical <> 'cafe_stock' OR category_canonical IS NULL) AND entity_id = 1"
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
           ORDER BY COALESCE(delivery_date, invoice_date, received_at::date) DESC,
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
