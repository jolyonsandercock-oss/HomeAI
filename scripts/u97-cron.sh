#!/bin/bash
# u97-cron.sh — hourly wrapper that runs the Caterbook reservation
# harvester against the last 7 days only.
set -euo pipefail
docker cp /home_ai/scripts/u97-harvest-caterbook-reservations.py \
          homeai-bot-responder:/tmp/u97.py 2>/dev/null
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-bot-responder python3 -u /tmp/u97.py 7
