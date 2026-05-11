#!/bin/bash
# Rotates homeai_readonly password (hex — paste-safe), verifies psql auth,
# prints the new password for Metabase.
set -euo pipefail

PW=$(openssl rand -hex 24)

docker exec -e VAULT_TOKEN homeai-vault \
  vault kv patch secret/postgres-roles homeai_readonly="$PW" >/dev/null

docker exec -i homeai-postgres psql -U postgres -d homeai \
  -c "ALTER ROLE homeai_readonly PASSWORD '$PW';" >/dev/null

TEST=$(docker exec -e PGPASSWORD="$PW" homeai-postgres \
  psql -h postgres -U homeai_readonly -d homeai -t -c "SELECT 'OK';" 2>&1)

if echo "$TEST" | grep -q "OK"; then
  echo "✓ rotated AND auth verified."
  echo
  echo "Paste this password into Metabase (only Metabase):"
  echo
  echo "    $PW"
  echo
else
  echo "✗ rotation succeeded but psql auth failed:"
  echo "$TEST"
  exit 1
fi
