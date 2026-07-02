#!/bin/bash
# u96-cron.sh — hourly wrapper that runs the Airbnb harvester against
# the last 7 days only. Quick and idempotent. The full 36-month backfill
# is done separately via /home_ai/scripts/u96-harvest-airbnb-bookings.py
# called with a longer days_back argument.
set -euo pipefail
docker cp /home_ai/scripts/u96-harvest-airbnb-bookings.py \
          homeai-bot-responder:/tmp/u96.py 2>/dev/null
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-bot-responder python3 -u /tmp/u96.py 7
