#!/usr/bin/env bash
# Diagnostic: print the FIELD NAMES (not values) under secret/postgres-roles.
set -euo pipefail
trap 'unset T' EXIT INT TERM
read -rsp '  vault token: ' T; printf '\n'
docker exec -e VAULT_TOKEN="$T" homeai-vault \
  vault kv get -format=json secret/postgres-roles \
  | jq '.data.data | keys'
