#!/usr/bin/env bash
# recreate-with-secrets.sh <compose-service>... — force-recreate services with
# the same secret harvest start.sh performs. Non-interactive: requires vault
# unsealed + VAULT_TOKEN in /home_ai/.env. Proven 2026-07-02 (8 boot-race victims).
set -euo pipefail
umask 077
cd /home_ai
set -a; . ./.env; set +a
[[ -n "${VAULT_TOKEN:-}" ]] || { echo "no VAULT_TOKEN in .env" >&2; exit 1; }
vkf() { docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault \
        vault kv get -format=json "$1" 2>/dev/null | jq -er ".data.data.\"$2\""; }
POSTGRES_PASSWORD=$(vkf secret/postgres password)
REDIS_PASSWORD=$(vkf secret/redis password)
GRAFANA_ADMIN_PASSWORD=$(vkf secret/grafana admin_password)
OPEN_WEBUI_SECRET=$(vkf secret/open-webui secret_key)
PAYLOAD_HMAC_KEY=$(vkf secret/signing payload_hmac_key)
ANTHROPIC_API_KEY=$(vkf secret/anthropic api_key)
ROLES_JSON=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -format=json secret/postgres-roles)
N8N_DB_PASSWORD=$(jq -er '.data.data.homeai_pipeline' <<<"$ROLES_JSON")
METABASE_APP_PASSWORD=$(jq -er '.data.data.metabase_app' <<<"$ROLES_JSON" || echo "")
PAPERLESS_DB_PASSWORD=$(jq -er '.data.data.paperless' <<<"$ROLES_JSON" || echo "")
ROLES_JSON=""
BREAKFAST_TOKEN_SECRET=$(vkf secret/breakfast token_secret || echo "")
export POSTGRES_PASSWORD REDIS_PASSWORD GRAFANA_ADMIN_PASSWORD OPEN_WEBUI_SECRET \
       PAYLOAD_HMAC_KEY ANTHROPIC_API_KEY N8N_DB_PASSWORD METABASE_APP_PASSWORD \
       PAPERLESS_DB_PASSWORD BREAKFAST_TOKEN_SECRET
echo "secrets harvested; recreating: $*"
docker compose up -d --force-recreate --no-deps "$@"
