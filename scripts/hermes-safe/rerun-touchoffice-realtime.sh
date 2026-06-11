#!/usr/bin/env bash
# hermes-safe: re-run the TouchOffice realtime scrape (same as the */10 cron).
set -euo pipefail
echo "$(date -Is) rerun-touchoffice-realtime" >> /home_ai/logs/hermes-safe.log
exec bash /home_ai/scripts/u33-touchoffice-realtime.sh
