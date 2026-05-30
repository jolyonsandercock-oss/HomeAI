#!/usr/bin/env bash
# fix-metabase-pass.sh — re-inject metabase_app DB password and recreate ONLY
# the metabase container.
#
# Why: homeai-metabase was recreated outside start.sh, so MB_DB_PASS baked in
# empty ("${METABASE_APP_PASSWORD}" unset) -> SCRAM auth fails -> crash loop.
# The metabase_app postgres role password is unchanged; metabase just isn't
# being handed it. This re-fetches it from Vault and recreates the container.
#
# Usage (interactive, so the Vault token is never echoed or stored):
#   ./scripts/fix-metabase-pass.sh
# or non-interactively if you already have a token in the environment:
#   VAULT_TOKEN=s.xxxx ./scripts/fix-metabase-pass.sh

set -euo pipefail
umask 077

readonly VAULT_CONTAINER="homeai-vault"
readonly COMPOSE="/home_ai/docker-compose.yml"
cleanup() { unset VAULT_TOKEN METABASE_APP_PASSWORD; }
trap cleanup EXIT INT TERM

err() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
ok()  { printf '\033[32m✓\033[0m %s\n' "$*"; }

# 1. Vault must be unsealed
sealed=$(docker exec "$VAULT_CONTAINER" vault status -format=json 2>/dev/null | jq -r '.sealed' || echo true)
[[ "$sealed" == "false" ]] || { err "vault is sealed — run ./start.sh first"; exit 1; }

# 2. Token (prompt if not already in env)
if [[ -z "${VAULT_TOKEN:-}" ]]; then
  read -rs -p "  vault token: " VAULT_TOKEN; printf '\n'
fi
export VAULT_TOKEN
docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" vault token lookup >/dev/null 2>&1 \
  || { err "token rejected by vault"; exit 1; }
ok "token accepted"

# 3. Fetch the metabase_app role password (same path start.sh uses)
METABASE_APP_PASSWORD=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" \
  vault kv get -format=json secret/postgres-roles 2>/dev/null \
  | jq -er '.data.data.metabase_app') \
  || { err "secret/postgres-roles missing 'metabase_app'"; exit 1; }
export METABASE_APP_PASSWORD
ok "metabase_app password fetched (len=${#METABASE_APP_PASSWORD})"

# 4. Recreate ONLY metabase with the env populated
docker compose -f "$COMPOSE" up -d --force-recreate --no-deps metabase
ok "metabase recreated"

# 5. Verify it stops crash-looping
echo "  waiting for metabase to settle (up to 90s)..."
for i in $(seq 1 18); do
  sleep 5
  if docker logs homeai-metabase 2>&1 | grep -qiE "Metabase Initialization COMPLETE|Running Metabase version"; then
    if ! docker logs homeai-metabase 2>&1 | tail -20 | grep -qi "password is an empty string"; then
      ok "metabase initialised — SCRAM auth succeeded"
      docker ps --filter name=homeai-metabase --format '  {{.Names}}: {{.Status}}'
      exit 0
    fi
  fi
done
err "metabase did not confirm init within 90s — check: docker logs homeai-metabase --tail 40"
exit 1
