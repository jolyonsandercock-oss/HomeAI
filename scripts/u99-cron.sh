#!/bin/bash
# u99-cron.sh — daily 06:45 wrapper for the vehicle renewal hunter.
# 365-day window so we always catch the AXA "renews soon" emails which
# arrive ~3 weeks before renewal.
set -euo pipefail
docker cp /home_ai/scripts/u99-harvest-vehicle-renewals.py \
          homeai-bot-responder:/tmp/u99.py 2>/dev/null
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-bot-responder python3 -u /tmp/u99.py 365
