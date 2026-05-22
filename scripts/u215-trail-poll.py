#!/usr/bin/env python3
"""u215-trail-poll.py — Trail compliance score poller.

REPLACES u134-trail-poll.py (REST API attempt — Trail has no public REST).
REPLACES u156-trail-scrape.py (interactive pair STUB).

Flow:
  1. Login via accessacloud.com OIDC (email → password → callback).
     Persistent profile at /home_ai/data/trail-profile-oidc reuses sessions.
  2. Open /reports#/scores; the SPA fires POST /api/scores with date range.
  3. Replay the same POST directly using the page's fetch (preserves CSRF +
     session cookies) for any range we want.
  4. Upsert one row per (location, date) into trail_reports.

Cron: 30 7,13,19 * * *  (three times daily — morning + lunch + post-close)
Vault: secret/trail  → {username, password, login_url, web_url}
"""
from __future__ import annotations
import asyncio
import json
import os
import subprocess
import sys
import urllib.request
from datetime import date, timedelta

LOG_PREFIX = "[u215]"


def log(msg: str) -> None:
    print(f"{LOG_PREFIX} {msg}", flush=True)


def vault_token() -> str:
    for c in ("homeai-critical-listener", "homeai-n8n", "homeai-google-fetch"):
        p = subprocess.run(
            ["docker", "inspect", c, "--format", "{{range .Config.Env}}{{println .}}{{end}}"],
            capture_output=True, text=True,
        )
        for line in p.stdout.splitlines():
            if line.startswith("VAULT_TOKEN="):
                return line.split("=", 1)[1]
    raise SystemExit(f"{LOG_PREFIX} VAULT_TOKEN not found")


SCRAPE_SRC = r'''
import asyncio, os, sys, json, urllib.request, datetime as dt

VAULT_TOKEN = os.environ['VAULT_TOKEN']
req = urllib.request.Request('http://vault:8200/v1/secret/data/trail',
    headers={'X-Vault-Token': VAULT_TOKEN})
creds = json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']

from playwright.async_api import async_playwright
PROFILE = "/home_ai/data/trail-profile-oidc"
os.makedirs(PROFILE, exist_ok=True)

DAYS_BACK = int(os.environ.get('TRAIL_DAYS_BACK', '7'))

async def login_if_needed(page):
    await page.goto('https://web.trailapp.com/reports#/scores', wait_until='domcontentloaded', timeout=30000)
    await page.wait_for_timeout(2500)
    if 'trailapp.com' in page.url and '/u/sign_in' not in page.url:
        return
    print('  re-auth required')
    await page.evaluate("() => { document.getElementById('onetrust-consent-sdk')?.remove(); }")
    await page.click('a[href="/u/auth/openid_connect"]', timeout=8000)
    await page.wait_for_url(lambda u: 'accessacloud.com' in u, timeout=15000)
    await page.wait_for_load_state('networkidle', timeout=10000)
    await page.locator('input[type="email"]').first.fill(creds['username'])
    await page.click('button#Next, button[type="submit"]')
    await page.wait_for_url(lambda u: '/auth/password' in u or 'trailapp.com' in u, timeout=15000)
    await page.wait_for_load_state('networkidle', timeout=10000)
    if 'accessacloud' in page.url:
        await page.locator('input[type="password"]').first.fill(creds['password'])
        await page.click('button[type="submit"]')
        await page.wait_for_url(lambda u: 'trailapp.com' in u and '/u/sign_in' not in u, timeout=20000)
    await page.wait_for_timeout(3000)

async def main():
    captured = []
    async with async_playwright() as p:
        ctx = await p.chromium.launch_persistent_context(
            PROFILE, headless=True,
            args=['--no-sandbox', '--disable-dev-shm-usage'],
            viewport={'width': 1400, 'height': 900},
        )
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()

        async def on_response(resp):
            if '/api/scores' in resp.url and resp.request.method == 'POST':
                try:
                    captured.append((resp.request.post_data, await resp.text(), resp.status))
                except Exception:
                    pass
        page.on('response', lambda r: asyncio.create_task(on_response(r)))

        await login_if_needed(page)
        if 'reports' not in page.url:
            await page.goto('https://web.trailapp.com/reports#/scores', wait_until='domcontentloaded', timeout=20000)
        await page.wait_for_load_state('networkidle', timeout=15000)
        await page.wait_for_timeout(4000)

        # We have at least one POST /api/scores captured naturally. Now replay
        # explicitly for our chosen window via the page's fetch (uses cookies).
        gte = (dt.date.today() - dt.timedelta(days=DAYS_BACK)).isoformat()
        body_obj = {'date': {'gte': gte}}
        # Pass body as a JSON arg into evaluate so no string-escape mess
        result_json = await page.evaluate("""async (bodyObj) => {
            const csrf = document.querySelector('meta[name="csrf-token"]')?.content || '';
            const r = await fetch('/api/scores', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Accept': 'application/json',
                    'X-Requested-With': 'XMLHttpRequest',
                    'X-CSRF-Token': csrf
                },
                body: JSON.stringify(bodyObj),
                credentials: 'include'
            });
            const text = await r.text();
            return {status: r.status, body: text};
        }""", body_obj)
        if result_json['status'] != 200:
            print(f'  fetch /api/scores returned {result_json["status"]}: {result_json["body"][:200]}')
            sys.exit(2)

        print(json.dumps({'status': result_json['status'], 'body': result_json['body']}))
        await ctx.close()

asyncio.run(main())
'''


def run_scraper() -> dict:
    """Run the Playwright scraper in homeai-playwright and return parsed scores."""
    tok = vault_token()
    p = subprocess.run(
        ["docker", "exec", "-i", "-e", f"VAULT_TOKEN={tok}",
         "-e", "TRAIL_DAYS_BACK=" + os.environ.get("TRAIL_DAYS_BACK", "7"),
         "homeai-playwright", "python3", "-"],
        input=SCRAPE_SRC, capture_output=True, text=True, timeout=180,
    )
    if p.returncode != 0:
        log(f"scraper failed (rc={p.returncode}):\n{p.stderr[-2000:]}")
        sys.exit(p.returncode)

    # Parse last JSON line (preceding lines may be log output)
    last_line = ""
    for line in p.stdout.splitlines():
        if line.startswith("{") and '"status"' in line:
            last_line = line
    if not last_line:
        log(f"no JSON response captured; stdout tail:\n{p.stdout[-1500:]}")
        sys.exit(3)
    parsed = json.loads(last_line)
    return json.loads(parsed["body"])


def upsert_scores(rows: list[dict]) -> int:
    """Upsert one row per (location, date) into trail_reports."""
    n_upserted = 0
    # Build a single multi-row INSERT for efficiency
    inserts = []
    for r in rows:
        if r["level"] != "location":
            continue  # skip the "Average" aggregate
        location = r["name"]
        loc_id = r["id"]
        for d, info in r["scores"].items():
            score = info.get("score")
            if score is None:
                continue  # future or no data
            report_id = f"{loc_id}_{d}"
            payload = json.dumps({"trail_id": loc_id, "status": info.get("status"), "name": location})
            score_s = "NULL" if score is None else f"{score}"
            inserts.append(
                f"('{report_id}', '{location}', 'daily', '{d}', 'daily', {score_s}, NULL, NULL, NULL, '{payload}'::jsonb, 'work')"
            )

    if not inserts:
        log("no closed-day scores to upsert")
        return 0

    sql = (
        "INSERT INTO trail_reports "
        "(trail_report_id, location, report_name, report_date, cadence, "
        " score_pct, tasks_total, tasks_completed, tasks_overdue, raw_payload, realm) "
        "VALUES " + ",\n".join(inserts) +
        " ON CONFLICT (trail_report_id, report_date) DO UPDATE SET "
        " score_pct = EXCLUDED.score_pct, "
        " raw_payload = EXCLUDED.raw_payload, "
        " ingested_at = NOW();"
    )

    # Run via docker exec
    pg_pass_env = subprocess.run(
        ["docker", "inspect", "homeai-critical-listener", "--format",
         "{{range .Config.Env}}{{println .}}{{end}}"],
        capture_output=True, text=True,
    ).stdout
    pg_pass = next(
        (l.split("=", 1)[1] for l in pg_pass_env.splitlines() if l.startswith("POSTGRES_PASSWORD=")),
        "",
    )
    p = subprocess.run(
        ["docker", "exec", "-i", "-e", f"PGPASSWORD={pg_pass}",
         "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai", "-q"],
        input=sql, capture_output=True, text=True, timeout=30,
    )
    if p.returncode != 0:
        log(f"psql failed:\n{p.stderr}")
        sys.exit(4)
    n_upserted = len(inserts)
    return n_upserted


def main() -> None:
    log(f"polling trail scores (last {os.environ.get('TRAIL_DAYS_BACK', '7')} days)")
    rows = run_scraper()
    n = upsert_scores(rows)
    log(f"upserted {n} rows into trail_reports")


if __name__ == "__main__":
    main()
