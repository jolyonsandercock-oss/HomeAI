#!/usr/bin/env bash
#
# u62-calendar-sync.sh — pull `primary` Google Calendar for every google identity
# with the calendar scope. Idempotent on (source_account, gcal_event_id).
#
# Cron: */15 * * * *

set -euo pipefail

WINDOW_PAST_DAYS="${WINDOW_PAST_DAYS:-30}"
WINDOW_FUTURE_DAYS="${WINDOW_FUTURE_DAYS:-180}"

# Map account → realm. (Matches the U9 google identity layout.)
# NOTE: 'family' is a dead realm value since the V164/V165 FAMILY→PERSONAL
# pivot (2026-05-19) — calendar_events_realm_check no longer permits it.
declare -A ACCT_REALM=(
    [jo]=personal
    [admin]=work
    [info]=work
    [pounana]=work
    [bot]=owner
)

VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VT" \
    -e WINDOW_PAST_DAYS="$WINDOW_PAST_DAYS" -e WINDOW_FUTURE_DAYS="$WINDOW_FUTURE_DAYS" \
    homeai-google-fetch python /dev/stdin <<'PYEOF'
import os, asyncio, json
from datetime import datetime, timezone, timedelta
import httpx

VAULT_ADDR  = os.environ["VAULT_ADDR"]
VAULT_TOKEN = os.environ["VAULT_TOKEN"]
WINDOW_PAST   = int(os.environ.get("WINDOW_PAST_DAYS",   30))
WINDOW_FUTURE = int(os.environ.get("WINDOW_FUTURE_DAYS", 180))

# 'family' retired by the V164/V165 realm pivot (2026-05-19) — calendar_events_realm_check
# only accepts owner/work/personal/shared now. jo's personal Google Calendar -> 'personal'.
ACCT_REALM = {"jo":"personal","admin":"work","info":"work","pounana":"work","bot":"owner"}

async def vault_read(client, path):
    r = await client.get(f"{VAULT_ADDR}/v1/secret/data/{path}",
                         headers={"X-Vault-Token": VAULT_TOKEN}, timeout=5)
    r.raise_for_status()
    return r.json()["data"]["data"]

async def access_token(client, sec):
    r = await client.post("https://oauth2.googleapis.com/token", data={
        "client_id": sec["oauth_client_id"],
        "client_secret": sec["oauth_client_secret"],
        "refresh_token": sec["refresh_token"],
        "grant_type": "refresh_token",
    })
    r.raise_for_status()
    return r.json()["access_token"]

async def fetch_calendar(client, acct, tok):
    time_min = (datetime.now(timezone.utc) - timedelta(days=WINDOW_PAST)).isoformat()
    time_max = (datetime.now(timezone.utc) + timedelta(days=WINDOW_FUTURE)).isoformat()
    items = []
    page = None
    for _ in range(8):  # max ~2000 events
        params = {
            "timeMin": time_min, "timeMax": time_max,
            "singleEvents": "true", "orderBy": "startTime",
            "maxResults": "250",
        }
        if page:
            params["pageToken"] = page
        r = await client.get(
            "https://www.googleapis.com/calendar/v3/calendars/primary/events",
            headers={"Authorization": f"Bearer {tok}"},
            params=params, timeout=30)
        if r.status_code != 200:
            print(f"  [{acct}] HTTP {r.status_code}: {r.text[:200]}")
            break
        j = r.json()
        items.extend(j.get("items", []))
        page = j.get("nextPageToken")
        if not page:
            break
    return items

import asyncpg
async def upsert(conn, acct, realm, ev):
    start_obj = ev.get("start", {})
    end_obj   = ev.get("end", {})
    all_day = "date" in start_obj and "dateTime" not in start_obj
    def parse(t):
        if not t: return None
        if "T" in t: return datetime.fromisoformat(t.replace("Z","+00:00"))
        # all-day date
        return datetime.fromisoformat(t + "T00:00:00+00:00")
    start_at = parse(start_obj.get("dateTime") or start_obj.get("date"))
    end_at   = parse(end_obj.get("dateTime")   or end_obj.get("date"))
    if not start_at:
        return False
    attendees = ev.get("attendees")
    await conn.execute("""
        INSERT INTO calendar_events
          (source_account, calendar_id, gcal_event_id, title, description,
           location, start_at, end_at, all_day, attendees, organiser_email,
           status, updated_at, fetched_at, realm)
        VALUES ($1, 'primary', $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10,
                $11, $12, NOW(), $13)
        ON CONFLICT (source_account, gcal_event_id) DO UPDATE
           SET title           = EXCLUDED.title,
               description     = EXCLUDED.description,
               location        = EXCLUDED.location,
               start_at        = EXCLUDED.start_at,
               end_at          = EXCLUDED.end_at,
               all_day         = EXCLUDED.all_day,
               attendees       = EXCLUDED.attendees,
               organiser_email = EXCLUDED.organiser_email,
               status          = EXCLUDED.status,
               updated_at      = EXCLUDED.updated_at,
               fetched_at      = NOW()
    """,
        acct, ev["id"], ev.get("summary"), ev.get("description"),
        ev.get("location"), start_at, end_at, all_day,
        json.dumps(attendees) if attendees else None,
        (ev.get("organizer") or {}).get("email"),
        ev.get("status", "confirmed"),
        parse(ev.get("updated")) or datetime.now(timezone.utc),
        realm)
    return True

async def main():
    conn = await asyncpg.connect(os.environ["PG_DSN"])
    await conn.execute("SET app.current_entity = 'all'")
    await conn.execute("SET app.current_realm  = 'owner'")

    async with httpx.AsyncClient() as client:
        # Discover identities with `calendar` scope
        identities = await client.get(f"{VAULT_ADDR}/v1/secret/metadata/google",
            headers={"X-Vault-Token": VAULT_TOKEN}, params={"list":"true"}, timeout=5)
        keys = identities.json().get("data", {}).get("keys", [])

        for acct in keys:
            if acct.startswith("oauth") or acct.startswith("sa-"):
                continue
            try:
                sec = await vault_read(client, f"google/{acct}")
            except Exception as e:
                print(f"  [{acct}] vault read failed: {e}")
                continue
            if "calendar" not in (sec.get("scopes","") or ""):
                continue
            try:
                tok = await access_token(client, sec)
            except Exception as e:
                print(f"  [{acct}] token refresh failed: {e}")
                continue
            events = await fetch_calendar(client, acct, tok)
            n_ok = 0
            for ev in events:
                if await upsert(conn, acct, ACCT_REALM.get(acct, "personal"), ev):
                    n_ok += 1
            print(f"  [{acct}] {n_ok} events upserted (window -{WINDOW_PAST}d..+{WINDOW_FUTURE}d)")

    total = await conn.fetchval("SELECT COUNT(*) FROM calendar_events")
    upcoming = await conn.fetchval("SELECT COUNT(*) FROM v_calendar_upcoming")
    print(f"\nTotal events in calendar_events: {total}")
    print(f"v_calendar_upcoming (next 30d): {upcoming}")

    await conn.close()

asyncio.run(main())
PYEOF
