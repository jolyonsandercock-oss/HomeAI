#!/bin/bash
# Full rotation of homeai_pipeline password — hex (paste-safe) — and
# alignment of all four places it lives:
#   1. Vault: secret/postgres-roles.homeai_pipeline
#   2. Postgres role
#   3. n8n stored credential (iTuuNfsqHY49MGhk)
#   4. n8n container env DB_POSTGRESDB_PASSWORD (via start.sh after this)
#
# Use after rotation drift is detected. After this completes, run ./start.sh
# to refresh #4. Master Router should turn green within 30s of start.sh.
set -euo pipefail

PW=$(openssl rand -hex 32)

echo "1/3 patching Vault..."
docker exec -e VAULT_TOKEN homeai-vault \
  vault kv patch secret/postgres-roles homeai_pipeline="$PW" >/dev/null

echo "2/3 ALTER ROLE..."
docker exec -i homeai-postgres psql -U postgres -d homeai \
  -c "ALTER ROLE homeai_pipeline PASSWORD '$PW';" >/dev/null

echo "3/3 syncing n8n credential..."
unset PW   # let sync-script fetch fresh from Vault — single source of truth
bash /home_ai/.claude/scripts/sync-n8n-postgres-credential.sh

echo
echo "✓ Rotation done. Vault, role, and n8n credential are all aligned."
echo
echo "FINAL STEP: run ./start.sh to refresh n8n container env."
echo "After that, Master Router should green within 30s."
