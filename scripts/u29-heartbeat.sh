#!/bin/bash
# /home_ai/scripts/u29-heartbeat.sh
#
# 6-hourly heartbeat (00/06/12/18). Emits a Telegram message EVERY run:
#   - healthy  → routine status update (♥ ok + freshness summary)
#   - degraded → exception/emergency listing the reasons:
#       system_alerts firing · scrape stale (TO>1h, CB>26h, WF>26h)
#       · dead_letter open > 5 · pending bot_instructions > 0
#
# Changed 2026-05-30 from */15 quiet-unless-degraded to 6-hourly always-emit
# (owner request: "6 hourly + exceptions, updates or emergencies"). Real-time
# criticals remain covered by Prometheus→notify-bridge + vault-watchdog. History:
# `SELECT * FROM telegram_outbox WHERE source='heartbeat' ORDER BY id DESC LIMIT 10`.

set -uo pipefail
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, urllib.request, urllib.parse, hashlib
from datetime import datetime
import asyncpg

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]


def vault_get(path):
    req = urllib.request.Request(f"http://vault:8200/v1/secret/data/{path}",
                                  headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())["data"]["data"]


async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity = 'all'")

    pending_inst = await conn.fetchval(
      "SELECT COUNT(*) FROM bot_instructions WHERE status='pending'")
    firing = await conn.fetchval(
      "SELECT COUNT(*) FROM system_alerts WHERE status='firing' AND acknowledged=false")
    last_to = await conn.fetchval(
      "SELECT MAX(scraped_at) FROM touchoffice_scrapes WHERE success=true")
    last_cb = await conn.fetchval(
      "SELECT MAX(received_at) FROM caterbook_email_reports")
    last_wf = await conn.fetchval(
      "SELECT MAX(started_at) FROM workforce_sync_log WHERE http_status=200")
    dead_letter_open = await conn.fetchval(
      "SELECT COUNT(*) FROM dead_letter WHERE resolved=false")

    def age_h(ts):
        if ts is None: return 99999
        return (datetime.now(ts.tzinfo) - ts).total_seconds() / 3600
    def stale_str(ts, _hours):
        h = age_h(ts)
        if h >= 99: return "old"
        if h < 1:   return f"{int(h*60)}m"
        return f"{int(h)}h"

    # Compute degraded reasons
    reasons = []
    if firing > 0:                  reasons.append(f"{firing} alert(s) firing")
    if pending_inst > 0:            reasons.append(f"{pending_inst} pending instruction(s)")
    if dead_letter_open > 5:        reasons.append(f"DL open {dead_letter_open}")
    if age_h(last_to) > 1:          reasons.append(f"TO stale {stale_str(last_to,1)}")
    if age_h(last_cb) > 26:         reasons.append(f"CB stale {stale_str(last_cb,26)}")
    if age_h(last_wf) > 26:         reasons.append(f"WF stale {stale_str(last_wf,26)}")

    degraded = bool(reasons)
    severity = "warn" if degraded else "info"

    now_str = datetime.now().strftime("%H:%M")
    if degraded:
        body = (f"♥ {now_str} · ⚠️ DEGRADED\n"
                + "\n".join(f"  • {r}" for r in reasons)
                + f"\n  TO {stale_str(last_to,1)} · CB {stale_str(last_cb,2)} · WF {stale_str(last_wf,25)}"
                + f" · alerts {firing}🔥 · DL {dead_letter_open or 0} · instructions {pending_inst}📨")
    else:
        body = (f"♥ {now_str} · ok · TO {stale_str(last_to,1)} · CB {stale_str(last_cb,2)} · WF {stale_str(last_wf,25)}")

    # Log to telegram_outbox in all cases
    body_hash = hashlib.sha256(body.encode()).hexdigest()[:16]
    sent = False
    http_status = None
    suppression_reason = None

    # 6-hourly run always emits: a routine status update when healthy, an
    # exception/emergency when degraded. Dedup guards only against a misfire
    # double-send of an identical body within 4h.
    recent = await conn.fetchval(
      """SELECT COUNT(*) FROM telegram_outbox
          WHERE source='heartbeat' AND body_hash=$1
            AND sent_at > now() - interval '4 hours'
            AND suppressed=false""",
      body_hash)
    if recent and recent > 0:
        suppression_reason = f"identical-body within 4h ({recent})"
    else:
        try:
            d = vault_get("telegram")
            req = urllib.request.Request(
                f"https://api.telegram.org/bot{d['bot_token']}/sendMessage",
                data=urllib.parse.urlencode({
                    "chat_id": d["chat_id"], "text": body,
                    "disable_notification": "false",
                }).encode())
            r = urllib.request.urlopen(req, timeout=10)
            http_status = r.status
            sent = True
        except Exception as e:
            http_status = -1
            suppression_reason = f"http error: {str(e)[:120]}"

    await conn.execute("""
      INSERT INTO telegram_outbox
        (source, severity, chat_id, http_status, body_hash, body_preview,
         suppressed, suppression_reason)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
    """, "heartbeat", severity, None, http_status, body_hash, body[:200],
         not sent, suppression_reason)

    await conn.close()
    print(f"{datetime.now().isoformat()} heartbeat sent={sent} severity={severity} reasons={len(reasons)}")

asyncio.run(main())
PYEOF
