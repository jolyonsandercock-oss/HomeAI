#!/bin/bash
# /home_ai/scripts/u33-rejection-digest.sh
#
# Telegram noise rate-limiter for query_rejections.
# If more than 5 rejections in the last 60 min AND no digest was sent in
# the last 60 min → send one digest Telegram summarising the surge.
# Otherwise silent. Per-row alerts are never sent.
#
# Cron: */15 * * * *.

set -uo pipefail
MARKER=/home_ai/data/u33-rejection-digest.lastsent
THRESHOLD=5
WINDOW_MIN=60
COOLDOWN_MIN=60

# Cooldown check
if [[ -f "$MARKER" ]]; then
  last_epoch=$(cat "$MARKER" 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  age_min=$(( (now_epoch - last_epoch) / 60 ))
  if (( age_min < COOLDOWN_MIN )); then
    exit 0
  fi
fi

VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e THRESHOLD="$THRESHOLD" -e WINDOW_MIN="$WINDOW_MIN" homeai-playwright python << 'PYEOF'
import os, sys, json, urllib.request, urllib.parse, asyncio
import asyncpg

THRESHOLD = int(os.environ["THRESHOLD"])
WINDOW_MIN = int(os.environ["WINDOW_MIN"])
VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]


def vault_get(path):
    req = urllib.request.Request(f"http://vault:8200/v1/secret/data/{path}",
                                  headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())["data"]["data"]


def tg_send(text):
    d = vault_get("telegram")
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{d['bot_token']}/sendMessage",
        data=urllib.parse.urlencode({"chat_id": d["chat_id"], "text": text}).encode())
    urllib.request.urlopen(req, timeout=10)


async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity = 'all'")
    rows = await conn.fetch("""
      SELECT asked_at, asked_by, reason, classifier_slug, LEFT(raw_question, 80) AS q
        FROM query_rejections
       WHERE asked_at >= NOW() - make_interval(mins => $1)
       ORDER BY asked_at DESC
    """, WINDOW_MIN)
    await conn.close()

    n = len(rows)
    if n <= THRESHOLD:
        sys.exit(0)

    by_reason = {}
    by_sender = {}
    for r in rows:
        by_reason[r["reason"]] = by_reason.get(r["reason"], 0) + 1
        by_sender[r["asked_by"]] = by_sender.get(r["asked_by"], 0) + 1

    lines = [
        f"⚠️  query rejection surge: {n} in last {WINDOW_MIN}min (threshold {THRESHOLD})",
        "",
        "by reason:",
    ]
    for k, v in sorted(by_reason.items(), key=lambda x: -x[1]):
        lines.append(f"  {k}: {v}")
    lines.append("")
    lines.append("by sender:")
    for k, v in sorted(by_sender.items(), key=lambda x: -x[1])[:5]:
        lines.append(f"  {k}: {v}")
    lines.append("")
    lines.append("most recent:")
    for r in rows[:5]:
        lines.append(f"  [{r['reason']}] {r['asked_by']} — {r['q']}")
    tg_send("\n".join(lines)[:3500])
    import time
    with open("/home_ai/data/u33-rejection-digest.lastsent", "w") as f:
        f.write(str(int(time.time())))
    print(f"digest sent: n={n}")

asyncio.run(main())
PYEOF
