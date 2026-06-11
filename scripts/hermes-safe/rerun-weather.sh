#!/usr/bin/env bash
# hermes-safe: re-run the weather sync (same as the 07:30 cron).
set -euo pipefail
echo "$(date -Is) rerun-weather" >> /home_ai/logs/hermes-safe.log
exec docker exec -i homeai-bot-responder python3 - < /home_ai/scripts/weather-sync.py
