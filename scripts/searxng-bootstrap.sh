#!/bin/bash
# /home_ai/scripts/searxng-bootstrap.sh
#
# Bootstrap + re-render for SearXNG.
#
# Idempotent. Vault stores the secret_key (path: secret/searxng, field: secret_key).
# This script:
#   1. Fetches the secret_key from Vault. Generates fresh + stores on first run.
#   2. Renders config/searxng/settings.yml from config/searxng-settings.yml.template
#      via envsubst. The rendered file is gitignored.
#
# Re-runs safely: same Vault value produces the same rendered file.
#
# If you have an existing settings.yml with a secret_key you want to preserve,
# seed Vault first:
#   docker exec -e VAULT_TOKEN=… homeai-vault \
#     vault kv put secret/searxng secret_key="<existing hex>"
# then run this script — it'll detect the value and re-use it.
#
# Run AFTER ./start.sh (Vault must be unsealed). Run as your normal user.

set -euo pipefail
RED='\033[0;31m'; YEL='\033[0;33m'; GREEN='\033[0;32m'; NC='\033[0m'

TEMPLATE=/home_ai/config/searxng-settings.yml.template
RENDERED=/home_ai/config/searxng/settings.yml
VAULT=homeai-vault

[[ -f "$TEMPLATE" ]] || { echo -e "${RED}✗${NC} missing $TEMPLATE"; exit 1; }
docker inspect "$VAULT" >/dev/null 2>&1 || {
  echo -e "${RED}✗${NC} $VAULT not running — run ./start.sh first"; exit 1; }

read -rsp "Vault token (kv-rw on secret/searxng): " VAULT_TOKEN
printf '\n'
[[ -n "$VAULT_TOKEN" ]] || { echo -e "${RED}✗${NC} no token given"; exit 1; }

trap 'unset VAULT_TOKEN KEY' EXIT INT TERM

KEY=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
        vault kv get -field=secret_key secret/searxng 2>/dev/null) || KEY=""

if [[ -z "$KEY" ]]; then
  # Vault is empty. Prefer importing any pre-existing key from the live config
  # over generating a fresh one — avoids invalidating SearXNG sessions on a
  # re-render of an already-running instance.
  existing=""
  if [[ -r "$RENDERED" ]]; then
    existing=$(grep -oP '^\s*secret_key:\s*"\K[a-f0-9]{32,}' "$RENDERED" || true)
  fi
  if [[ -n "$existing" ]]; then
    echo -e "${YEL}→${NC} found existing secret_key in $RENDERED"
    read -rp "Import into Vault? [Y/n] (N = generate fresh, will invalidate sessions): " imp
    if [[ ! "${imp:-Y}" =~ ^[Nn] ]]; then
      KEY="$existing"
    fi
  fi
  if [[ -z "$KEY" ]]; then
    KEY=$(openssl rand -hex 32)
    echo -e "${YEL}→${NC} generated fresh secret_key"
  fi
  docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
    vault kv put secret/searxng secret_key="$KEY" >/dev/null
  echo -e "${YEL}→${NC} stored to secret/searxng"
else
  echo -e "${GREEN}✓${NC} secret_key from Vault"
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"; unset VAULT_TOKEN KEY' EXIT INT TERM
SEARXNG_SECRET_KEY="$KEY" envsubst '${SEARXNG_SECRET_KEY}' < "$TEMPLATE" > "$TMP"
chmod 644 "$TMP"

if [[ -w "$RENDERED" ]] || { [[ ! -e "$RENDERED" ]] && [[ -w "$(dirname "$RENDERED")" ]]; }; then
  cp "$TMP" "$RENDERED"
  echo -e "${GREEN}✓${NC} rendered $RENDERED"
else
  echo -e "${YEL}→${NC} $RENDERED is not writable as $(whoami) — using sudo"
  sudo install -m 644 "$TMP" "$RENDERED"
  echo -e "${GREEN}✓${NC} rendered $RENDERED (via sudo)"
fi

echo
echo -e "${GREEN}── done ──${NC}"
echo "Next: docker compose restart searxng"
