#!/bin/bash
# /home_ai/scripts/u34-tanda-departments-sync.sh
#
# Sync Tanda /api/v2/departments → workforce_departments.
# Auto-maps the `team` column based on department name keywords:
#   kitchen → kitchen
#   bar / cellar → bar
#   sandwich / cafe / coffee → cafe
#   front / floor / waiter / waitress / server / host → front_of_house
#   manager / admin → management
#   housekeeping / room / clean → accommodation
# else: unassigned.
#
# Idempotent. Cron candidate: weekly (departments rarely change).

set -uo pipefail
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, json, urllib.request, asyncio, asyncpg, re

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]

def vget(p):
    r = urllib.request.Request(f"http://vault:8200/v1/secret/data/{p}",
                                headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(r, timeout=5).read())["data"]["data"]

def auto_team(name):
    if not name:
        return ("unassigned", "auto")
    n = name.lower()
    pats = [
      ("kitchen",         [r"\bkitchen\b", r"\bchef\b", r"\bcook\b"]),
      ("bar",             [r"\bbar\b", r"\bcellar\b"]),
      ("cafe",            [r"\bsandwich\b", r"\bcaf[eé]\b", r"\bcoffee\b", r"\bice ?cream\b"]),
      ("front_of_house",  [r"\bfront\b", r"\bfloor\b", r"\bwait", r"\bserver\b", r"\bhost", r"\bfoh\b"]),
      ("management",      [r"\bmanager\b", r"\badmin\b", r"\bmgr\b"]),
      ("accommodation",   [r"\bhousekeep", r"\bhouse\b", r"\broom\b", r"\bclean\b", r"\bhk\b", r"\binn\b", r"\blinen\b"]),
    ]
    for team, patterns in pats:
        for p in patterns:
            if re.search(p, n):
                return (team, "auto")
    return ("unassigned", "auto")

async def main():
    creds = vget("workforce")
    base, tok = creds["base_url"], creds["access_token"]
    url = f"{base}/api/v2/departments"
    r = urllib.request.urlopen(urllib.request.Request(
        url, headers={"Authorization": f"bearer {tok}"}), timeout=30)
    depts = json.loads(r.read())
    print(f"fetched {len(depts)} departments")

    conn = await asyncpg.connect(PG_DSN)
    upserted = 0
    async with conn.transaction():
        await conn.execute("SET LOCAL app.current_entity = '1'")
        for d in depts:
            ext_id = d.get("id")
            name = d.get("name") or f"dept_{ext_id}"
            team, source = auto_team(name)
            await conn.execute("""
              INSERT INTO workforce_departments (external_id, name, team, team_source, raw_payload)
              VALUES ($1, $2, $3, $4, $5)
              ON CONFLICT (external_id) DO UPDATE SET
                name           = EXCLUDED.name,
                raw_payload    = EXCLUDED.raw_payload,
                last_synced_at = now(),
                team           = CASE
                                   WHEN workforce_departments.team_source = 'manual'
                                   THEN workforce_departments.team
                                   ELSE EXCLUDED.team
                                 END,
                team_source    = CASE
                                   WHEN workforce_departments.team_source = 'manual'
                                   THEN 'manual'
                                   ELSE EXCLUDED.team_source
                                 END
            """, ext_id, name, team, source, json.dumps(d))
            upserted += 1
    await conn.close()
    print(f"upserted {upserted} departments")

asyncio.run(main())
PYEOF
