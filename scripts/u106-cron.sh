#!/bin/bash
# u106-cron.sh — daily 17:00. TEST=1 by default = test recipients only.
# Set TEST=0 in /home_ai/.env after Jo signs off.
set -uo pipefail
docker cp /home_ai/scripts/u106-breakfast-email.py homeai-bot-responder:/tmp/u106.py 2>/dev/null
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
TEST_MODE=${BREAKFAST_LIVE:-1}  # 1 = test, 0 = live; flip via env
# U250: secret from .env (mirrors Vault secret/breakfast); no fallback in script.
BREAKFAST_TOKEN_SECRET=$(grep "^BREAKFAST_TOKEN_SECRET=" /home_ai/.env | cut -d= -f2-)
docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e TEST="$TEST_MODE" -e BREAKFAST_TOKEN_SECRET="$BREAKFAST_TOKEN_SECRET" homeai-bot-responder python3 -u /tmp/u106.py
