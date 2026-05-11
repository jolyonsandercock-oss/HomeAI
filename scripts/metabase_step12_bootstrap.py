#!/usr/bin/env python3
"""
metabase_step12_bootstrap.py — Step 12 automation.

Configures Metabase via REST API:
  1. Adds `homeai` Postgres as a Metabase data source (homeai_readonly creds
     fetched from Vault at runtime).
  2. Creates two saved questions: Events log + Email review queue.
  3. Creates a dashboard "Step 12 — Vertical Slice" containing both.

Idempotent: if a database/question/dashboard with the same name already
exists, skips creation and reuses the existing id.

USAGE
    export MB_API_KEY=mb_...      # from Metabase admin UI
    python3 /home_ai/scripts/metabase_step12_bootstrap.py

Resolves Metabase host via Docker — connects to the homeai-metabase
container's IP on the home_ai_ai-internal network. Vault token is taken
from $VAULT_TOKEN (set by start.sh).
"""

import json
import os
import subprocess
import sys
import urllib.request
import urllib.error

DASHBOARD_NAME = "Step 12 — Vertical Slice"
DB_NAME = "homeai"
Q_EVENTS = "Events log"
Q_REVIEW = "Email review queue"


def docker_ip(name: str, network: str = "home_ai_ai-internal") -> str:
    out = subprocess.check_output([
        "docker", "inspect", name,
        "--format",
        f'{{{{(index .NetworkSettings.Networks "{network}").IPAddress}}}}',
    ]).decode().strip()
    if not out:
        sys.exit(f"could not resolve container {name} on {network}")
    return out


class MB:
    def __init__(self, base_url: str, api_key: str):
        self.base = base_url.rstrip("/")
        self.headers = {
            "x-api-key": api_key,
            "Content-Type": "application/json",
        }

    def _req(self, method: str, path: str, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            f"{self.base}{path}", data=data, method=method, headers=self.headers,
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            sys.exit(f"{method} {path} → {e.code} {e.reason}\n{e.read().decode()}")

    def get(self, path):  return self._req("GET", path)
    def post(self, path, body): return self._req("POST", path, body)
    def put(self, path, body):  return self._req("PUT", path, body)


def find_db(mb: MB, name: str):
    res = mb.get("/api/database")
    items = res.get("data") if isinstance(res, dict) else res
    for db in (items or []):
        if db.get("name") == name:
            return db
    return None


def find_card(mb: MB, name: str):
    res = mb.get("/api/card")
    for c in (res or []):
        if c.get("name") == name:
            return c
    return None


def find_dashboard(mb: MB, name: str):
    res = mb.get("/api/dashboard")
    for d in (res or []):
        if d.get("name") == name:
            return d
    return None


def vault_get(field: str, path: str) -> str:
    token = os.environ.get("VAULT_TOKEN")
    if not token:
        sys.exit("VAULT_TOKEN not set in this shell — re-run start.sh or export it.")
    return subprocess.check_output([
        "docker", "exec", "-e", f"VAULT_TOKEN={token}", "homeai-vault",
        "vault", "kv", "get", f"-field={field}", path,
    ]).decode().strip()


def main() -> int:
    api_key = os.environ.get("MB_API_KEY")
    if not api_key:
        sys.exit("MB_API_KEY not set. Get from Metabase Admin → Settings → API Keys.")

    mb_ip = docker_ip("homeai-metabase")
    mb = MB(f"http://{mb_ip}:3000", api_key)

    # 1. Database connection
    db = find_db(mb, DB_NAME)
    if db:
        print(f"db '{DB_NAME}' already exists (id={db['id']})")
        db_id = db["id"]
    else:
        pg_password = vault_get("homeai_readonly", "secret/postgres-roles")
        body = {
            "name": DB_NAME,
            "engine": "postgres",
            "details": {
                "host": "postgres",  # Docker hostname on shared network
                "port": 5432,
                "dbname": "homeai",
                "user": "homeai_readonly",
                "password": pg_password,
                "ssl": False,
            },
        }
        created = mb.post("/api/database", body)
        db_id = created["id"]
        print(f"db '{DB_NAME}' created (id={db_id})")

    # Trigger schema sync so the table picker is populated
    mb.post(f"/api/database/{db_id}/sync_schema", None)

    # 2. Questions (cards) — native SQL
    def upsert_card(name, sql):
        existing = find_card(mb, name)
        if existing:
            print(f"card '{name}' already exists (id={existing['id']})")
            return existing["id"]
        body = {
            "name": name,
            "display": "table",
            "visualization_settings": {},
            "dataset_query": {
                "type": "native",
                "native": {"query": sql, "template-tags": {}},
                "database": db_id,
            },
        }
        created = mb.post("/api/card", body)
        print(f"card '{name}' created (id={created['id']})")
        return created["id"]

    sql_events = (
        "SELECT id, event_type, source, entity_id, status, created_at, "
        "idempotency_key, retry_count "
        "FROM events ORDER BY created_at DESC LIMIT 100;"
    )
    sql_review = (
        "SELECT id, account, from_address, subject, classification, "
        "confidence_score, requires_human, received_at "
        "FROM emails "
        "WHERE requires_human = true OR confidence_score < 0.80 "
        "   OR classification IS NULL "
        "ORDER BY received_at DESC NULLS LAST LIMIT 100;"
    )
    events_card = upsert_card(Q_EVENTS, sql_events)
    review_card = upsert_card(Q_REVIEW, sql_review)

    # 3. Dashboard
    dash = find_dashboard(mb, DASHBOARD_NAME)
    if dash:
        print(f"dashboard '{DASHBOARD_NAME}' already exists (id={dash['id']})")
        dash_id = dash["id"]
    else:
        created = mb.post("/api/dashboard", {"name": DASHBOARD_NAME})
        dash_id = created["id"]
        print(f"dashboard '{DASHBOARD_NAME}' created (id={dash_id})")
        # Add cards via PUT /api/dashboard/{id}
        mb.put(f"/api/dashboard/{dash_id}", {
            "dashcards": [
                {"id": -1, "card_id": events_card, "row": 0, "col": 0,
                 "size_x": 24, "size_y": 8, "parameter_mappings": []},
                {"id": -2, "card_id": review_card, "row": 8, "col": 0,
                 "size_x": 24, "size_y": 8, "parameter_mappings": []},
            ],
        })
        print(f"dashboard cards attached")

    print("\nStep 12 complete.")
    print(f"Open: http://100.104.82.53:3000/dashboard/{dash_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
