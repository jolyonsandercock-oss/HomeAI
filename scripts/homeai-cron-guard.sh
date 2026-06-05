#!/usr/bin/env bash
# homeai-cron-guard.sh — reinstall joly's crontab from the committed snapshot if
# the live job count drops below baseline. Heals the recurring crontab-wipe
# (the root cause of watchdogs silently dying). Runs as a systemd timer.
set -uo pipefail
SNAP=/home_ai/scripts/crontab.snapshot.txt
BASELINE=15
live=$(crontab -u joly -l 2>/dev/null | grep -vcE '^\s*#|^\s*$' || echo 0)
if [ "${live:-0}" -lt "$BASELINE" ] && [ -f "$SNAP" ]; then
  crontab -u joly "$SNAP"
  docker exec -i homeai-postgres psql -U postgres -d homeai \
    -c "INSERT INTO audit_log(pipeline,action,ai_parsed) VALUES('cron-guard','self_repair',jsonb_build_object('repair','reinstall_crontab','live_was',$live));" >/dev/null 2>&1 || true
  bash /home_ai/.claude/scripts/notify-telegram.sh "🛠 cron-guard: crontab had $live jobs (<$BASELINE) — reinstalled from snapshot" "cron-guard" >/dev/null 2>&1 || true
fi
