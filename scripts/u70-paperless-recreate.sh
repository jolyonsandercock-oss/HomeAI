#!/usr/bin/env bash
# u70-paperless-recreate.sh — recreate homeai-paperless with the post-consume
# webhook hook wired in. Mirrors the start.sh secret-fetch pattern: read
# everything from Vault, export, run `docker compose up -d paperless`.
#
# Idempotent. Safe to re-run.

set -euo pipefail
umask 077

cleanup() { unset VAULT_TOKEN POSTGRES_PASSWORD \
                  PAPERLESS_DB_PASSWORD PAPERLESS_ADMIN_PASSWORD \
                  PAPERLESS_SECRET_KEY PAPERLESS_WEBHOOK_SECRET \
                  PAPERLESS_API_TOKEN REDIS_PASSWORD; }
trap cleanup EXIT INT TERM

VAULT_TOKEN=$(docker inspect homeai-bot-responder \
  --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep '^VAULT_TOKEN=' | cut -d= -f2-)
[[ -n "$VAULT_TOKEN" ]] || { echo "✗ VAULT_TOKEN unavailable from bot-responder"; exit 1; }
export VAULT_TOKEN

kv() { docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault \
         vault kv get -field="$2" "$1"; }

POSTGRES_PASSWORD=$(kv secret/postgres password)
REDIS_PASSWORD=$(kv secret/redis password)
PAPERLESS_DB_PASSWORD=$(kv secret/paperless db_password)
PAPERLESS_ADMIN_PASSWORD=$(kv secret/paperless admin_password)
PAPERLESS_SECRET_KEY=$(kv secret/paperless secret_key)
PAPERLESS_WEBHOOK_SECRET=$(kv secret/paperless/webhook secret)
PAPERLESS_API_TOKEN=$(kv secret/paperless/api token)

export POSTGRES_PASSWORD REDIS_PASSWORD \
       PAPERLESS_DB_PASSWORD PAPERLESS_ADMIN_PASSWORD PAPERLESS_SECRET_KEY \
       PAPERLESS_WEBHOOK_SECRET PAPERLESS_API_TOKEN

cd /home_ai
docker compose up -d paperless

echo "✓ paperless recreated with U70 post-consume hook"
echo "  webhook  → http://homeai-build-dashboard:8090/api/documents/ingest-from-paperless"
echo "  script   → /usr/src/paperless/scripts/post-consume.sh"
echo "  api-token in vault: secret/paperless/api"
