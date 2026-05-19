#!/usr/bin/env python3
"""u134-trail-poll.py — hourly Trail report poller.

Pulls the latest report scores from Trail and upserts into trail_reports.
The API base + auth header pattern are discovered from Trail's actual
endpoints on first contact; until that's verified, this script
gracefully no-ops with a log message rather than crashing the cron.

Vault path: secret/trail key=api_key
Run: python3 /home_ai/scripts/u134-trail-poll.py [--base https://...]
"""
from __future__ import annotations
import argparse
import json
import os
import subprocess
import sys
import urllib.request
import urllib.error
import datetime as dt

# Trail's public API root — best-known candidates. First that responds wins.
# Update once Jo confirms via Trail's developer portal.
DEFAULT_BASES = [
    "https://api.trailapp.net",
    "https://api.trailapp.io",
    "https://app.trailapp.net/api/v1",
]


def vault_token() -> str:
    for c in ("homeai-critical-listener", "homeai-n8n", "homeai-google-fetch"):
        p = subprocess.run(
            ["docker", "inspect", c, "--format", "{{range .Config.Env}}{{println .}}{{end}}"],
            capture_output=True, text=True,
        )
        for line in p.stdout.splitlines():
            if line.startswith("VAULT_TOKEN="):
                return line.split("=", 1)[1]
    print("[FAIL] VAULT_TOKEN not found in any container env", file=sys.stderr)
    sys.exit(1)


def vault_get(path: str, field: str) -> str:
    tok = vault_token()
    p = subprocess.run(
        ["docker", "exec", "-e", f"VAULT_TOKEN={tok}", "homeai-vault",
         "vault", "kv", "get", "-format=json", f"secret/{path}"],
        capture_output=True, text=True,
    )
    if p.returncode != 0:
        print(f"[FAIL] vault read secret/{path}: {p.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return json.loads(p.stdout)["data"]["data"][field]


def psql(sql: str) -> None:
    p = subprocess.run(
        ["docker", "exec", "-i", "homeai-postgres",
         "psql", "-U", "postgres", "-d", "homeai",
         "-v", "ON_ERROR_STOP=1", "-q"],
        input=sql, text=True, capture_output=True,
    )
    if p.returncode != 0:
        print(f"[psql FAIL] {p.stderr.strip()}", file=sys.stderr)
        sys.exit(1)


def try_fetch(base: str, key: str, path: str) -> tuple[int, str]:
    url = f"{base.rstrip('/')}/{path.lstrip('/')}"
    for hdr_name, hdr_val in [
        ("Authorization", f"Bearer {key}"),
        ("X-API-Key", key),
        ("X-Trail-Token", key),
    ]:
        req = urllib.request.Request(url, headers={
            hdr_name: hdr_val,
            "Accept": "application/json",
            "User-Agent": "homeai-trail-poller/1.0",
        })
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                body = r.read().decode("utf-8", errors="replace")
                return r.status, body
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                continue  # try next auth header
            return e.code, str(e)
        except (urllib.error.URLError, TimeoutError) as e:
            return 0, str(e)
    return 401, "all auth headers rejected"


def sql_escape(s) -> str:
    if s is None:
        return "NULL"
    return "'" + str(s).replace("'", "''") + "'"


def upsert_report(r: dict) -> None:
    sql = f"""INSERT INTO trail_reports
        (trail_report_id, location, report_name, report_date, cadence,
         score_pct, tasks_total, tasks_completed, tasks_overdue,
         raw_payload, ingested_at, realm)
        VALUES (
            {sql_escape(r['trail_report_id'])},
            {sql_escape(r['location'])},
            {sql_escape(r['report_name'])},
            {sql_escape(r['report_date'])}::date,
            {sql_escape(r.get('cadence','daily'))},
            {r.get('score_pct','NULL') if r.get('score_pct') is not None else 'NULL'},
            {r.get('tasks_total','NULL') if r.get('tasks_total') is not None else 'NULL'},
            {r.get('tasks_completed','NULL') if r.get('tasks_completed') is not None else 'NULL'},
            {r.get('tasks_overdue','NULL') if r.get('tasks_overdue') is not None else 'NULL'},
            {sql_escape(json.dumps(r.get('raw_payload', {})))}::jsonb,
            NOW(),
            'work'
        )
        ON CONFLICT (trail_report_id, report_date) DO UPDATE
           SET score_pct       = EXCLUDED.score_pct,
               tasks_total     = EXCLUDED.tasks_total,
               tasks_completed = EXCLUDED.tasks_completed,
               tasks_overdue   = EXCLUDED.tasks_overdue,
               raw_payload     = EXCLUDED.raw_payload,
               ingested_at     = NOW();"""
    psql(sql)


def discover_base(key: str, bases: list[str]) -> str | None:
    """Find the first base that returns 200/auth-ok on a 'sites' or 'reports' probe."""
    for base in bases:
        for path in ("/sites", "/reports", "/locations", "/v1/sites"):
            code, body = try_fetch(base, key, path)
            if code == 200:
                print(f"  [discover] OK base={base} probe={path}")
                return base
            if code in (401, 403):
                print(f"  [discover] {base}{path} {code} — auth issue, key may need different scope")
                return base  # base exists, key needs work
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", help="Trail API base URL")
    ap.add_argument("--days", type=int, default=2, help="how many days back to backfill")
    args = ap.parse_args()

    key = vault_get("trail", "api_key")
    bases = [args.base] if args.base else DEFAULT_BASES

    base = discover_base(key, bases)
    if not base:
        print("[INFO] No Trail API base reachable from this host.")
        print("[INFO] Endpoint candidates tried:", bases)
        print("[INFO] Once a working base is known: --base https://... or update DEFAULT_BASES.")
        print("[INFO] Vault holds the key at secret/trail — script will work once base is reachable.")
        return

    # Real implementation would iterate locations + reports + dates and call
    # upsert_report(). Left as a stub until the API contract is known —
    # Trail uses GraphQL on some tiers, REST on others.
    print(f"[INFO] Trail base discovered: {base}")
    print("[INFO] Report-extraction stub — endpoint contract not yet verified.")
    print("[INFO] Once verified, fill in the loop calling upsert_report() per report row.")


if __name__ == "__main__":
    main()
