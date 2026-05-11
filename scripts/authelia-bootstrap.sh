#!/bin/bash
# /home_ai/scripts/authelia-bootstrap.sh
#
# Bootstrap + re-render for Authelia (Phase 2 SSO).
#
# Idempotent. Vault is the canonical secret store; this script:
#   1. Fetches secret/authelia/encryption + secret/authelia/jwt from Vault.
#      Generates fresh values and stores them on first run only.
#   2. Renders security/authelia-v2/configuration.yml from configuration.yml.template
#      via envsubst. The rendered file is gitignored.
#   3. On first run only (when users_database.yml is missing/templated), prompts
#      for an admin password and writes an argon2id-hashed user entry.
#
# Re-runs safely after the initial bootstrap — same Vault values produce the
# same rendered file, so cookies/JWTs stay valid.
#
# Run AFTER ./start.sh (Vault must be unsealed). Run as your normal user.

set -euo pipefail
RED='\033[0;31m'; YEL='\033[0;33m'; GREEN='\033[0;32m'; NC='\033[0m'

CONFIG_DIR=/home_ai/security/authelia-v2
TEMPLATE=$CONFIG_DIR/configuration.yml.template
CONFIG=$CONFIG_DIR/configuration.yml
USERS=$CONFIG_DIR/users_database.yml
USERS_TEMPLATE=$CONFIG_DIR/users_database.yml.template
VAULT=homeai-vault

[[ -f "$TEMPLATE" ]] || { echo -e "${RED}✗${NC} missing $TEMPLATE"; exit 1; }
docker inspect "$VAULT" >/dev/null 2>&1 || {
  echo -e "${RED}✗${NC} $VAULT not running — run ./start.sh first"; exit 1; }

read -rsp "Vault token (kv-rw on secret/authelia/*): " VAULT_TOKEN
printf '\n'
[[ -n "$VAULT_TOKEN" ]] || { echo -e "${RED}✗${NC} no token given"; exit 1; }

trap 'unset VAULT_TOKEN ENC JWT' EXIT INT TERM

vault_get() {
  docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
    vault kv get -field="$2" "$1" 2>/dev/null
}

vault_put() {
  docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT" \
    vault kv put "$1" "$2=$3" >/dev/null
}

# ── 1. Encryption key ──────────────────────────────────────────
ENC=$(vault_get secret/authelia/encryption secret) || ENC=""
if [[ -z "$ENC" ]]; then
  ENC=$(openssl rand -hex 32)
  vault_put secret/authelia/encryption secret "$ENC"
  echo -e "${YEL}→${NC} generated + stored secret/authelia/encryption"
else
  echo -e "${GREEN}✓${NC} encryption key from Vault"
fi

# ── 2. JWT secret ──────────────────────────────────────────────
JWT=$(vault_get secret/authelia/jwt secret) || JWT=""
if [[ -z "$JWT" ]]; then
  JWT=$(openssl rand -hex 32)
  vault_put secret/authelia/jwt secret "$JWT"
  echo -e "${YEL}→${NC} generated + stored secret/authelia/jwt"
else
  echo -e "${GREEN}✓${NC} jwt secret from Vault"
fi

# ── 3. Render configuration.yml from template ──────────────────
AUTHELIA_STORAGE_ENCRYPTION_KEY="$ENC" \
AUTHELIA_JWT_SECRET="$JWT" \
  envsubst '${AUTHELIA_STORAGE_ENCRYPTION_KEY} ${AUTHELIA_JWT_SECRET}' \
  < "$TEMPLATE" > "$CONFIG"
chmod 600 "$CONFIG"
echo -e "${GREEN}✓${NC} rendered $CONFIG (mode 600)"

# ── 4. Users database (first run only) ─────────────────────────
needs_users=false
if [[ ! -s "$USERS" ]] || grep -q REPLACE_ME "$USERS" 2>/dev/null; then
  needs_users=true
fi

if $needs_users; then
  [[ -f "$USERS_TEMPLATE" ]] || {
    echo -e "${RED}✗${NC} missing $USERS_TEMPLATE — can't bootstrap users"; exit 1; }
  read -rsp "Authelia admin password (silent, min 14 chars): " PW
  printf '\n'
  read -rsp "Confirm: " PW2
  printf '\n'
  [[ "$PW" == "$PW2" ]] || { echo -e "${RED}✗${NC} passwords don't match"; exit 1; }
  [[ ${#PW} -ge 14 ]] || { echo -e "${RED}✗${NC} minimum 14 characters"; exit 1; }

  echo -e "${YEL}→${NC} hashing via authelia (argon2id)…"
  HASH=$(docker run --rm authelia/authelia:4.39 \
         authelia crypto hash generate argon2 --password "$PW" 2>/dev/null \
         | tail -1 | sed -E 's/^Digest: //')
  unset PW PW2
  [[ -n "$HASH" ]] || { echo -e "${RED}✗${NC} authelia hash generation failed"; exit 1; }

  cp "$USERS_TEMPLATE" "$USERS"
  python3 - "$USERS" "$HASH" <<'PYEOF'
import sys
path, hash_val = sys.argv[1], sys.argv[2]
src = open(path).read()
placeholder = "'$argon2id$v=19$m=65536,t=3,p=4$REPLACE_ME$REPLACE_ME'"
if placeholder not in src:
    print("ERR: placeholder not found in users_database.yml.template")
    sys.exit(1)
open(path, 'w').write(src.replace(placeholder, f"'{hash_val}'"))
PYEOF
  chmod 600 "$USERS"
  echo -e "${GREEN}✓${NC} users_database.yml written (mode 600)"
else
  echo -e "${GREEN}✓${NC} users_database.yml already populated (skipping)"
fi

echo
echo -e "${GREEN}── done ──${NC}"
echo "Next:"
echo "  docker compose up -d authelia    # if first time"
echo "  docker compose restart authelia  # if re-render after rotation"
