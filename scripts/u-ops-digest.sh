#!/usr/bin/env bash
# u-ops-digest.sh — one morning Telegram digest: what is broken and for how long.
#
# Registry row (V280__ops_digest_registry.sql):
#   INSERT INTO ops.pipeline_registry(name,kind,script_path,schedule_cron,freshness_sql,freshness_sla_hours,notes)
#   VALUES ('ops_digest','report','scripts/u-ops-digest.sh','45 7 * * *',
#           'SELECT max(finished_at) FROM ops.pipeline_runs WHERE name=''ops_digest'' AND status=''ok''',26,
#           'R0.4 daily Telegram ops digest') ON CONFLICT (name) DO NOTHING;
#
# Deviation from brief: the stale-pipelines list is capped at 30 lines with a
# "+N more" tail before being folded into the message, so a mass-NO_DATA day
# (e.g. right after a registry seed, before jobs have had their first run)
# can't blow the digest up to hundreds of lines.
set -euo pipefail
echo "START $(date -Is)"
source "$(dirname "${BASH_SOURCE[0]}")/lib/pg-connect.sh"

STALE=$(psqlc "SELECT name||' age='||COALESCE(age_hours::text,'n/a')||'h (sla '||sla_hours||'h)'
               FROM ops.check_freshness() WHERE status IN ('STALE','NO_DATA') ORDER BY age_hours DESC NULLS LAST")
ALERTS=$(psqlc "SELECT alertname||' ['||COALESCE(severity,'?')||'] since '||to_char(starts_at,'MM-DD')||
                CASE WHEN acknowledged THEN ' (acked)' ELSE '' END
                FROM system_alerts WHERE status='firing' ORDER BY starts_at LIMIT 20")
EXC=$(psqlc "SELECT kind||': '||left(summary,60)||' ('||to_char(raised_at,'MM-DD')||')'
             FROM mart.exceptions WHERE status='open' ORDER BY raised_at DESC LIMIT 15")

# Deviation: cap the stale-pipelines list at 30 lines (see header note above).
STALE_DISPLAY="$STALE"
if [ -n "$STALE" ]; then
  STALE_TOTAL=$(echo "$STALE" | wc -l)
  if [ "$STALE_TOTAL" -gt 30 ]; then
    STALE_DISPLAY=$(echo "$STALE" | head -30)$'\n'"(+$((STALE_TOTAL - 30)) more)"
  fi
fi

BODY=""
[ -n "$STALE" ]  && BODY+=$'\n📉 Stale pipelines:\n'"$(echo "$STALE_DISPLAY" | sed 's/^/  • /')"
[ -n "$ALERTS" ] && BODY+=$'\n🚨 Firing alerts:\n'"$(echo "$ALERTS" | sed 's/^/  • /')"
[ -n "$EXC" ]    && BODY+=$'\n⚠️ Open exceptions:\n'"$(echo "$EXC" | sed 's/^/  • /')"
[ -z "$BODY" ]   && BODY=$'\n✅ all green'
MSG="🩺 Ops digest $(date +%a\ %d\ %b)${BODY}"

docker exec -e MSG="$MSG" homeai-bot-responder python -c "
import os, urllib.request, urllib.parse, json
req = urllib.request.Request('http://vault:8200/v1/secret/data/telegram',
    headers={'X-Vault-Token': os.environ['VAULT_TOKEN']})
d = json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']
req = urllib.request.Request(f\"https://api.telegram.org/bot{d['bot_token']}/sendMessage\",
    data=urllib.parse.urlencode({'chat_id': d['chat_id'], 'text': os.environ['MSG'][:4000]}).encode())
print('sent:', json.loads(urllib.request.urlopen(req, timeout=10).read()).get('ok'))
"
echo "OPS_ROWS=$( [ -n "$STALE" ] && echo "$STALE" | wc -l || echo 0 )"
echo "DONE $(date -Is)"
