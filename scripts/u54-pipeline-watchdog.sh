#!/usr/bin/env bash
#
# u54-pipeline-watchdog.sh — independent paging for ingest-pipeline outages.
#
# Watchdog runs OUTSIDE n8n so an n8n outage can't suppress the alert (which
# is what bit us on 2026-05-13: master-router went silent, the heartbeat
# correctly reported DEGRADED, but the route from DEGRADED to Telegram lived
# inside n8n and was therefore also dark).
#
# Checks every 15 min (via cron) and Telegram-pages on:
#   * oldest pending email.received event > 2 hours old
#   * no master-router execution in the last 15 min
#
# Idempotency: writes a telegram_outbox row each time it pages so a flapping
# state doesn't pump the chat; also checks telegram_outbox for a same-source
# alert in the last 30 min and short-circuits if found.
#
# Exit codes:
#   0  no page sent (system healthy OR suppression hit)
#   1  page sent (degraded state detected)
#   2  setup error

set -euo pipefail

SOURCE="u54-pipeline-watchdog"
PSQL=(docker exec -i homeai-postgres psql -U postgres -d homeai -X -q -A -t)

q() { "${PSQL[@]}" -c "$1" 2>/dev/null | tr -d '[:space:]'; }

# Suppression: bail if a same-source alert went out in the last 2 hours.
# (Was 30 min + severity='critical' — but notify-telegram.sh logs as 'info'
# so the severity filter never matched and the watchdog fired every cron
# tick. Widened to 2h and dropped the severity filter — same outage on
# repeat doesn't re-page until 2h elapsed.)
recent_alert=$(q "SELECT COUNT(*) FROM telegram_outbox
                   WHERE source='${SOURCE}'
                     AND sent_at > now() - interval '2 hours'
                     AND suppressed=false;")
if [[ "${recent_alert:-0}" -gt 0 ]]; then
    echo "Suppressed: same-source alert sent within 2h."
    exit 0
fi

# Probe 1 — oldest pending email.received age in seconds.
oldest_pending_age=$(q "SELECT COALESCE(
    EXTRACT(EPOCH FROM (now() - MIN(created_at)))::bigint, 0)
  FROM events
  WHERE event_type='email.received' AND status='pending';")

# Probe 2 — seconds since last master-router execution.
last_exec_age=$(q "SELECT COALESCE(
    EXTRACT(EPOCH FROM (now() - MAX(\"startedAt\")))::bigint, 99999)
  FROM execution_entity
  WHERE \"workflowId\"='test-master-router';")

reasons=()
[[ "${oldest_pending_age:-0}" -gt 7200 ]] && reasons+=("oldest pending event ${oldest_pending_age}s old (>2h)")
[[ "${last_exec_age:-0}"      -gt 900  ]] && reasons+=("no master-router exec in ${last_exec_age}s (>15m)")

if [[ ${#reasons[@]} -eq 0 ]]; then
    echo "OK: pending=${oldest_pending_age}s, last_exec=${last_exec_age}s"
    exit 0
fi

# Build the alert text. HTML mode for emphasis.
msg="<b>🚨 INGEST PIPELINE DEGRADED</b>%0A"
for r in "${reasons[@]}"; do
    msg+="• ${r}%0A"
done
msg+="%0AInvestigate: docker logs homeai-n8n; check execution_entity; check events.status='pending' backlog."

bash /home_ai/.claude/scripts/notify-telegram.sh "$msg" "$SOURCE" >/dev/null
echo "PAGED: ${reasons[*]}"
exit 1
