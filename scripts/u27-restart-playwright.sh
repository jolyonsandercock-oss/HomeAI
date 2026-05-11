#!/bin/bash
# /home_ai/scripts/u27-restart-playwright.sh
#
# Re-creates the homeai-playwright container with VAULT_TOKEN in its env so
# the scraper can read secret/touchoffice + secret/caterbook from Vault.
#
# Prompts for the Vault token (same one you give to start.sh). Token is
# scoped to this docker compose invocation only — not exported to your shell.

set -euo pipefail
RED='\033[0;31m'; YEL='\033[0;33m'; GREEN='\033[0;32m'; NC='\033[0m'

docker inspect homeai-vault >/dev/null 2>&1 || {
  echo -e "${RED}✗${NC} homeai-vault not running — run ./start.sh first"; exit 1; }

read -rsp "Vault token (read on secret/touchoffice + secret/caterbook): " VAULT_TOKEN
printf '\n'
[[ -n "$VAULT_TOKEN" ]] || { echo -e "${RED}✗${NC} no token given"; exit 1; }

trap 'unset VAULT_TOKEN' EXIT INT TERM

echo -e "${YEL}→${NC} re-creating homeai-playwright with token in env…"
VAULT_TOKEN="$VAULT_TOKEN" docker compose -f /home_ai/docker-compose.yml \
  up -d --force-recreate playwright-service 2>&1 | tail -5

sleep 2
echo
echo -e "${YEL}→${NC} smoke-checking /readyz (does the container see Vault?)…"
if docker exec homeai-playwright python -c "
import urllib.request, json
r = urllib.request.urlopen('http://localhost:8001/readyz', timeout=5)
print(json.loads(r.read()))
" 2>&1; then
  echo -e "${GREEN}✓${NC} container up + Vault reachable"
else
  echo -e "${RED}✗${NC} readyz failed — check 'docker logs homeai-playwright'"
fi
