#!/usr/bin/env python3
"""
audit-invariants.py — Home AI Administrative Engine invariant checker.

Greps first-party code for violations of the hard invariants declared in
/home_ai/AGENTS.md, so a regression is caught when it is introduced rather
than months later by a third-party audit.

Invariants checked (see AGENTS.md "Build rules"):
  INV-IDEMPOTENCY  events INSERTs must use WHERE NOT EXISTS, never ON CONFLICT
                   (events.idempotency_key has no DB unique constraint — a
                   partitioned table can't UNIQUE-index a non-partition-key
                   column, so ON CONFLICT throws at runtime).            [FAIL]
  INV-ENTITY-GUC   every PostgreSQL write must set app.current_entity.   [FAIL]
  INV-ENTITY-LOCAL entity GUC must be transaction-local (SET LOCAL / the
                   3-arg set_config(...,true)); bare SET leaks into the
                   next query on a pooled connection.                    [WARN]
  INV-PG-SUPERUSER services must not connect as the postgres superuser
                   (BYPASSRLS defeats entity isolation).                 [FAIL]
  INV-DOCKER-SOCK  no app service mounts docker.sock (RW=FAIL host-root;
                   :ro=WARN — :ro is not real isolation).                 [FAIL]
  INV-BODY-TEXT    AI-prompt paths must use body_text_safe, never the raw
                   body_text (PII redaction).                            [WARN]
  INV-DIRECT-LLM   cloud LLM calls should route through the gateway
                   (llm-router / claude_call wrapper), not raw SDK/HTTP.  [WARN]
  INV-PORTS        host-published ports should bind to 127.0.0.1 unless
                   intentionally exposed.                                [WARN]

Exit code: 0 if no FAIL-level findings, 1 otherwise (CI / cron friendly).
Stdlib only — no install step.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # /home_ai
N8N_DIR = ROOT / ".claude" / "n8n-exports"
SERVICES_DIR = ROOT / "services"
LIB_DIR = ROOT / "lib"
COMPOSE = ROOT / "docker-compose.yml"
FRONTEND_API = ROOT / "services" / "homeai-frontend" / "app" / "api"

# Files allowed to call the Anthropic API directly: the gateway + the shared
# retry wrappers that everything else is supposed to go through.
LLM_GATEWAY_ALLOW = ("llm-router", "homeai-litellm", "claude_call.py")
# Files where raw body_text is legitimate (outbound email, not an AI prompt).
BODY_TEXT_ALLOW = ("google-fetch", "bot-responder", "homeai-frontend")

# Tables with RLS entity isolation (from postgres/*.sql ENABLE ROW LEVEL
# SECURITY). A write to one of these without app.current_entity is a silent
# data-isolation bug; writes to audit/system tables are not RLS-scoped, so
# we don't fail on those (keeps the gate high-signal).
RLS_TABLES = {
    "accommodation_daily_reports", "bank_transactions", "cashflow_forecast",
    "documents", "emails", "epos_daily_reports", "events", "invoices",
    "rent_payments", "staff", "till_reconciliation",
}
# Markers that a node body is building an LLM prompt (so raw body_text matters).
AI_MARKER_RE = re.compile(r"prompt|system|claude|gpt|anthropic|messages|llm",
                          re.I)

WRITE_INS_RE = re.compile(r"insert\s+into\s+([a-z_][a-z0-9_]*)", re.I)
WRITE_UPD_RE = re.compile(r"\bupdate\s+([a-z_][a-z0-9_]*)\s+set\b", re.I)
WRITE_DEL_RE = re.compile(r"delete\s+from\s+([a-z_][a-z0-9_]*)", re.I)
WRITE_RE = re.compile(r"\b(insert\s+into|update\s+\w+\s+set|delete\s+from)\b",
                      re.I)
INSERT_EVENTS_RE = re.compile(r"insert\s+into\s+events\b", re.I)
NEXT_INSERT_RE = re.compile(r"insert\s+into\b", re.I)
ON_CONFLICT_RE = re.compile(r"\bon\s+conflict\b", re.I)
SET_LOCAL_RE = re.compile(r"set\s+local\s+app\.current_entity", re.I)
SET_CONFIG_LOCAL_RE = re.compile(
    r"set_config\(\s*'app\.current_entity'\s*,[^)]*,\s*true\s*\)", re.I
)
SET_BARE_RE = re.compile(r"(?<!local )set\s+app\.current_entity", re.I)
GUC_PRESENT_RE = re.compile(r"app\.current_entity", re.I)
# Tailscale CGNAT range 100.64.0.0/10 (100.64.x – 100.127.x).
TAILNET_RE = re.compile(r"^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.")

findings: list[tuple[str, str, str, str]] = []  # (severity, rule, location, msg)


def add(severity: str, rule: str, location: str, msg: str) -> None:
    findings.append((severity, rule, location, msg))


def line_of(text: str, needle: str) -> int:
    idx = text.find(needle)
    if idx < 0:
        return 0
    return text.count("\n", 0, idx) + 1


def write_targets(query: str) -> set[str]:
    """Tables written by a SQL string (INSERT/UPDATE...SET/DELETE)."""
    t = set()
    for rx in (WRITE_INS_RE, WRITE_UPD_RE, WRITE_DEL_RE):
        t.update(m.group(1).lower() for m in rx.finditer(query))
    return t


def events_insert_uses_on_conflict(query: str) -> bool:
    """True only if the events INSERT's *own* clause uses ON CONFLICT.

    Scopes to the window between 'INSERT INTO events' and the next INSERT, so
    an ON CONFLICT on a sibling table (invoices, audit_log) in the same CTE
    chain is not a false positive.
    """
    for m in INSERT_EVENTS_RE.finditer(query):
        tail = query[m.end():]
        nxt = NEXT_INSERT_RE.search(tail)
        window = tail[:nxt.start()] if nxt else tail
        if ON_CONFLICT_RE.search(window):
            return True
    return False


# ── n8n workflow exports ──────────────────────────────────────────────
def walk_nodes(obj):
    """Yield (name, kind, body) for every postgres query / code node."""
    if isinstance(obj, dict):
        params = obj.get("parameters")
        name = obj.get("name", "?")
        if isinstance(params, dict):
            if isinstance(params.get("query"), str):
                yield name, "query", params["query"]
            if isinstance(params.get("jsCode"), str):
                yield name, "jsCode", params["jsCode"]
        for v in obj.values():
            yield from walk_nodes(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from walk_nodes(v)


def check_n8n() -> None:
    if not N8N_DIR.is_dir():
        return
    for path in sorted(N8N_DIR.glob("*.json")):
        try:
            data = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            add("WARN", "PARSE", str(path), "could not parse JSON")
            continue
        raw = path.read_text()
        for name, kind, body in walk_nodes(data):
            loc = f"{path.name} » node '{name}' (~L{line_of(raw, name[:40])})"
            low = body.lower()

            if kind == "query":
                # IDEMPOTENCY: the events INSERT must not use ON CONFLICT
                if events_insert_uses_on_conflict(body):
                    add("FAIL", "INV-IDEMPOTENCY", loc,
                        "INSERT INTO events uses ON CONFLICT — events has no "
                        "unique constraint on idempotency_key; use WHERE NOT "
                        "EXISTS (or claim_idempotency_key()).")
                # ENTITY GUC on writes to RLS tables
                targets = write_targets(body)
                rls_hit = targets & RLS_TABLES
                has_guc = bool(GUC_PRESENT_RE.search(body))
                has_local = bool(SET_LOCAL_RE.search(body)
                                 or SET_CONFIG_LOCAL_RE.search(body))
                if rls_hit and not has_guc:
                    add("FAIL", "INV-ENTITY-GUC", loc,
                        f"write to RLS table(s) {sorted(rls_hit)} with no "
                        "app.current_entity set.")
                elif has_guc and not has_local:
                    add("WARN", "INV-ENTITY-LOCAL", loc,
                        "entity GUC set without LOCAL — leaks to next query "
                        "on a pooled connection.")
                elif SET_BARE_RE.search(body) and not has_local:
                    add("WARN", "INV-ENTITY-LOCAL", loc,
                        "bare SET app.current_entity (no LOCAL) — session leak.")

            # body_text in an AI prompt: only flag a fallback that actually
            # reaches raw body_text (e.g. `body_text_safe || x.body_text`).
            # `body_text_safe || ''` is safe and must not warn.
            if re.search(r"body_text_safe\s*\|\|[^;\n]*\bbody_text\b(?!_safe)", body):
                add("WARN", "INV-BODY-TEXT", loc,
                    "body_text_safe falls back to raw body_text — fallback "
                    "defeats redaction; drop the raw fallback.")
            elif (re.search(r"\bbody_text\b", body)
                  and "body_text_safe" not in low
                  and AI_MARKER_RE.search(body)):
                add("WARN", "INV-BODY-TEXT", loc,
                    "raw body_text in a node that looks like an AI prompt — "
                    "use body_text_safe for model input.")

            # direct Anthropic from a workflow
            if "api.anthropic.com" in low:
                add("WARN", "INV-DIRECT-LLM", loc,
                    "workflow calls api.anthropic.com directly — route via "
                    "llm-router for budget/Presidio/retry.")


# ── docker-compose.yml ────────────────────────────────────────────────
# Port spec inside quotes: optional IP, then host:container (handles inline
# array form `ports: ["8200:8200"]` AND block form `- "127.0.0.1:80:80"`).
PORT_SPEC_RE = re.compile(r'["\']((?:\d{1,3}(?:\.\d{1,3}){3}:)?\d+:\d+)["\']')


def _flag_port(spec: str, lineno: int) -> None:
    # spec is [ip:]host:container. A leading IP means an explicit bind.
    m = re.match(r"(\d{1,3}(?:\.\d{1,3}){3}):", spec)
    bind_ip = m.group(1) if m else None
    if bind_ip is None:
        add("WARN", "INV-PORTS", f"docker-compose.yml:{lineno}",
            f"port '{spec}' has no bind IP — Docker publishes on 0.0.0.0 "
            "(all interfaces); bind to 127.0.0.1 or the tailnet IP.")
    elif bind_ip == "0.0.0.0":
        add("WARN", "INV-PORTS", f"docker-compose.yml:{lineno}",
            f"port '{spec}' is bound to 0.0.0.0 (all interfaces) — confirm "
            "host firewall or bind to 127.0.0.1 / tailnet.")
    elif not (bind_ip == "127.0.0.1" or TAILNET_RE.match(bind_ip)):
        add("WARN", "INV-PORTS", f"docker-compose.yml:{lineno}",
            f"port '{spec}' is on a public/LAN interface '{bind_ip}' (not "
            "loopback or tailnet) — confirm intent.")


def check_compose() -> None:
    if not COMPOSE.is_file():
        return
    lines = COMPOSE.read_text().splitlines()
    in_ports = False
    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if "postgresql://postgres:" in line:
            add("FAIL", "INV-PG-SUPERUSER", f"docker-compose.yml:{i}",
                "service DSN connects as postgres superuser (BYPASSRLS) — "
                "use a scoped role.")
        if "docker.sock" in line and stripped.lstrip("-").strip().startswith("/"):
            # :ro is NOT real isolation — the socket is a command channel to the
            # daemon; the mount mode is not the authz boundary. RW = host-root
            # vector (FAIL); :ro = still full API access, confirm it's needed (WARN).
            ro = stripped.rstrip(",").endswith(":ro")
            add("WARN" if ro else "FAIL", "INV-DOCKER-SOCK", f"docker-compose.yml:{i}",
                "docker.sock mounted read-only — :ro does NOT block Engine API "
                "writes; confirm this service truly needs Docker access."
                if ro else
                "docker.sock mounted read-write — host-root vector; remove it "
                "(run the workload in its owning container + relay over HTTP).")
        # inline-array form: ports: ["8200:8200", "0.0.0.0:11434:11434"]
        if re.match(r"ports:\s*\[", stripped):
            for sm in PORT_SPEC_RE.finditer(line):
                _flag_port(sm.group(1), i)
            continue
        # block form: ports:\n  - "127.0.0.1:80:80"
        if re.match(r"ports:\s*$", stripped):
            in_ports = True
            continue
        if in_ports:
            sm = PORT_SPEC_RE.search(stripped)
            if sm:
                _flag_port(sm.group(1), i)
            elif stripped and not stripped.startswith("-"):
                in_ports = False


# ── python services / lib ─────────────────────────────────────────────
def check_python() -> None:
    for base in (SERVICES_DIR, LIB_DIR):
        if not base.is_dir():
            continue
        for path in base.rglob("*.py"):
            rel = str(path.relative_to(ROOT))
            try:
                text = path.read_text()
            except OSError:
                continue
            low = text.lower()

            # direct Anthropic SDK/HTTP outside the gateway/wrapper
            uses_anthropic = ("api.anthropic.com" in low
                              or re.search(r"\banthropic\(", text)
                              or re.search(r"^\s*(from|import)\s+anthropic", text, re.M))
            if uses_anthropic and not any(a in rel for a in LLM_GATEWAY_ALLOW):
                add("WARN", "INV-DIRECT-LLM", rel,
                    "calls Anthropic directly outside the gateway/claude_call "
                    "wrapper — route via llm-router (budget/Presidio/retry).")

            # service performs writes but never sets the entity GUC anywhere
            if WRITE_RE.search(text) and not GUC_PRESENT_RE.search(text):
                add("WARN", "INV-ENTITY-GUC", rel,
                    "service issues writes but never references "
                    "app.current_entity — verify RLS entity scoping.")

            # raw body_text in a prompt-building service (not a send path)
            if (re.search(r"\bbody_text\b", text)
                    and "body_text_safe" not in low
                    and AI_MARKER_RE.search(text)
                    and not any(a in rel for a in BODY_TEXT_ALLOW)):
                add("WARN", "INV-BODY-TEXT", rel,
                    "raw body_text alongside LLM-prompt code — use "
                    "body_text_safe for model input.")


# ── next.js frontend route handlers ───────────────────────────────────
def check_frontend() -> None:
    """The frontend connects as a non-superuser role, so RLS actually applies.

    home_ai.set_realm() is SET LOCAL — it must run inside a transaction with
    the dependent queries (the withRealm() wrapper), or the realm evaporates
    and the realm policies fall back to their permissive branch.
    """
    if not FRONTEND_API.is_dir():
        return
    for path in FRONTEND_API.rglob("route.ts"):
        rel = str(path.relative_to(ROOT))
        try:
            text = path.read_text()
        except OSError:
            continue
        has_wrapper = "withRealm" in text
        has_begin = re.search(r"['\"]BEGIN['\"]", text) is not None
        in_tx = has_wrapper or has_begin

        # set_realm without a surrounding transaction → realm discarded
        if "set_realm" in text and not in_tx:
            add("FAIL", "INV-FE-REALM-TX", rel,
                "home_ai.set_realm() called without withRealm()/BEGIN — SET "
                "LOCAL realm is discarded before the query runs.")
        # raw pooled client with no transaction at all in a DB route
        elif re.search(r"\.connect\(\)", text) and not in_tx and (
                "set_realm" in text or re.search(r"\b(INSERT INTO|UPDATE \w+ SET|DELETE FROM)\b", text)):
            add("WARN", "INV-FE-RAW-CONNECT", rel,
                "raw pooled .connect() with no transaction — use withRealm() so "
                "realm/entity are set transaction-locally before any query.")


# ── report ────────────────────────────────────────────────────────────
BASELINE = ROOT / "scripts" / ".audit-baseline.txt"


def _ident(f) -> str:
    # Stable identity of a finding (severity may change; rule+location is the key)
    return f"{f[1]}|{f[2]}"


def _collect():
    check_n8n()
    check_compose()
    check_python()
    check_frontend()
    order = {"FAIL": 0, "WARN": 1}
    findings.sort(key=lambda f: (order.get(f[0], 9), f[1], f[2]))


def main() -> int:
    args = sys.argv[1:]
    _collect()
    use_color = sys.stdout.isatty()
    def c(code, s):
        return f"\033[{code}m{s}\033[0m" if use_color else s

    # --write-baseline: snapshot current findings as the accepted backlog.
    if "--write-baseline" in args:
        BASELINE.write_text("".join(f"{_ident(f)}\n" for f in findings))
        print(f"baseline written: {len(findings)} findings → {BASELINE.name}")
        return 0

    # --check: regression gate — fail ONLY on findings not in the baseline
    # (so the known/tracked backlog doesn't block every push). Used by pre-push.
    if "--check" in args:
        base = set(BASELINE.read_text().splitlines()) if BASELINE.exists() else set()
        new = [f for f in findings if _ident(f) not in base]
        new_fail = [f for f in new if f[0] == "FAIL"]
        if not new:
            print(c("32", f"invariant gate: no new findings ({len(findings)} known)"))
            return 0
        print(c("31" if new_fail else "33", f"invariant gate: {len(new)} NEW finding(s):"))
        for sev, rule, loc, msg in new:
            print(f"  [{sev}] [{rule}] {loc}\n      {msg}")
        return 1 if new_fail else 0

    # default: full report
    fails = sum(1 for f in findings if f[0] == "FAIL")
    warns = sum(1 for f in findings if f[0] == "WARN")
    print(c("1", "Home AI — invariant audit"))
    print("=" * 60)
    if not findings:
        print(c("32", "No invariant violations found."))
        return 0
    cur = None
    for sev, rule, loc, msg in findings:
        if sev != cur:
            cur = sev
            colour = "31" if sev == "FAIL" else "33"
            print("\n" + c(colour, f"── {sev} ──"))
        tag = c("31" if sev == "FAIL" else "33", f"[{rule}]")
        print(f"  {tag} {loc}\n      {msg}")
    print("\n" + "=" * 60)
    print(c("31" if fails else "33", f"{fails} FAIL, {warns} WARN"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
