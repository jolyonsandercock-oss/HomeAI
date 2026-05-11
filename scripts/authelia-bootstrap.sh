#!/bin/bash
# /home_ai/scripts/authelia-bootstrap.sh
#
# One-shot interactive bootstrap for Authelia (Phase 2 SSO).
#
# What this does:
#   1. Generates JWT secret + storage encryption key (32-char random each)
#      and writes them into configuration.yml.
#   2. Prompts for an admin password (silent input), generates an argon2id
#      hash via the authelia container, writes users_database.yml.
#   3. Stores the bootstrap secrets to Vault under secret/authelia/jwt and
#      secret/authelia/encryption (so they survive volume reset).
#
# Run AFTER ./start.sh (Vault must be unsealed).

set -euo pipefail

CONFIG_DIR=/home_ai/security/authelia-v2
CONFIG=$CONFIG_DIR/configuration.yml
USERS=$CONFIG_DIR/users_database.yml
TEMPLATE=$CONFIG_DIR/users_database.yml.template

# ── 1. Secrets ──────────────────────────────────────────────────
JWT_SECRET=$(openssl rand -hex 32)
ENC_KEY=$(openssl rand -hex 32)
STORAGE_ENCRYPTION_KEY="$ENC_KEY"

echo "→ generating secrets + writing into $CONFIG"
sed -i "s|^  encryption_key: ''|  encryption_key: '$ENC_KEY'|" "$CONFIG"
sed -i "s|^    jwt_secret: ''|    jwt_secret: '$JWT_SECRET'|" "$CONFIG"

# ── 2. Admin password ──────────────────────────────────────────
read -rsp "New Authelia admin password (silent): " PW
printf '\n'
read -rsp "Confirm: " PW2
printf '\n'
if [[ "$PW" != "$PW2" ]]; then
  echo "✗ passwords don't match"
  exit 1
fi
if [[ ${#PW} -lt 14 ]]; then
  echo "✗ minimum 14 characters"
  exit 1
fi

echo "→ hashing via authelia (argon2id)…"
HASH=$(docker run --rm authelia/authelia:4.39 authelia crypto hash generate argon2 --password "$PW" 2>/dev/null \
       | tail -1 | sed -E 's/^Digest: //')
unset PW PW2

if [[ -z "$HASH" ]]; then
  echo "✗ authelia hash generation failed"
  exit 1
fi

cp "$TEMPLATE" "$USERS"
# Argon2 hash contains $ and / chars — use python for safe replace
python3 -c "
import sys
src = open('$USERS').read()
out = src.replace(\"'\\\$argon2id\\\$v=19\\\$m=65536,t=3,p=4\\\$REPLACE_ME\\\$REPLACE_ME'\", \"'$HASH'\")
open('$USERS','w').write(out)
"

# ── 3. Stash to Vault ──────────────────────────────────────────
read -rsp "Vault token (kv-write to secret/authelia/*): " VTOK
printf '\n'
docker exec -e VAULT_TOKEN="$VTOK" homeai-vault \
  vault kv put secret/authelia/jwt        secret="$JWT_SECRET" >/dev/null
docker exec -e VAULT_TOKEN="$VTOK" homeai-vault \
  vault kv put secret/authelia/encryption secret="$ENC_KEY" >/dev/null
unset VTOK JWT_SECRET ENC_KEY

echo
echo "✓ Authelia bootstrapped."
echo "Next:"
echo "  1. Uncomment the authelia + caddy-forward-auth blocks in docker-compose.yml"
echo "  2. docker compose up -d authelia"
echo "  3. Browse to https://auth.homeai.local — log in with username 'jo' and the password you set"
echo "  4. Enrol TOTP with your authenticator app on first login"
echo "  5. Update Caddyfile to forward-auth Metabase, n8n, Grafana, dashboard"
