#!/bin/bash
# Recreates homeai-llm-router with fresh env from Vault. Used after rebuilding
# the image to pick up code changes without a full start.sh run.
set -euo pipefail

export N8N_DB_PASSWORD=$(docker exec -e VAULT_TOKEN homeai-vault \
  vault kv get -field=homeai_pipeline secret/postgres-roles)
export REDIS_PASSWORD=$(docker exec -e VAULT_TOKEN homeai-vault \
  vault kv get -field=password secret/redis)
export ANTHROPIC_API_KEY=$(docker exec -e VAULT_TOKEN homeai-vault \
  vault kv get -field=api_key secret/anthropic)
export PAYLOAD_HMAC_KEY=$(docker exec -e VAULT_TOKEN homeai-vault \
  vault kv get -field=payload_hmac_key secret/signing)

cd /home_ai
docker compose up -d --force-recreate --no-deps llm-router

unset N8N_DB_PASSWORD REDIS_PASSWORD ANTHROPIC_API_KEY PAYLOAD_HMAC_KEY

sleep 6
echo
echo "=== llm-router status ==="
docker ps --filter name=homeai-llm-router --format '{{.Status}}'
echo
echo "=== last log lines ==="
docker logs homeai-llm-router --tail 5 2>&1 | tail -5
