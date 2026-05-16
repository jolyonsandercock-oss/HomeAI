#!/bin/bash
set -uo pipefail
docker cp /home_ai/scripts/u101-harvest-collins-reservations.py homeai-bot-responder:/tmp/u101.py 2>/dev/null
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-bot-responder python3 -u /tmp/u101.py 7
