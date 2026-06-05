#!/usr/bin/env bash
# fix-metabase-role-pw.sh — reset the metabase_app DB role password and re-store
# it in Vault, then chain into the normal startup.
#
# Why: secret/postgres-roles lost its `metabase_app` field during the
# 2026-06-05 superuser-migration churn (reverted in 3ad638d). The old password
# is unrecoverable (Postgres stores only a SCRAM hash), so start.sh aborts at
# fetch_secrets and the WHOLE stack stays down for one non-critical service.
# Fix = mint a fresh password, ALTER the role to it, write it to Vault
# (preserving the other fields), then run start.sh. Metabase's data DB
# (metabase_app) is untouched — only the login password changes.
#
# Usage:  bash /home_ai/scripts/fix-metabase-role-pw.sh   (prompts for token once)

set -euo pipefail
umask 077

readonly VAULT_CONTAINER="homeai-vault"
readonly PG_CONTAINER="homeai-postgres"
readonly ROLE="metabase_app"
readonly KV_PATH="secret/postgres-roles"

cleanup() { unset VAULT_TOKEN NEWPW; }
trap cleanup EXIT INT TERM

err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }

# 1. Vault must be unsealed
sealed=$(docker exec "$VAULT_CONTAINER" vault status -format=json 2>/dev/null | jq -r '.sealed' || echo true)
[[ "$sealed" == "false" ]] || { err "vault is sealed — run ./start.sh first"; exit 1; }

# 2. Token (prompt once; exported so the chained start.sh reuses it)
if [[ -z "${VAULT_TOKEN:-}" ]]; then
  read -rs -p "  vault token: " VAULT_TOKEN; printf '\n'
fi
export VAULT_TOKEN
docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" vault token lookup >/dev/null 2>&1 \
  || { err "token rejected by vault"; exit 1; }
ok "token accepted"

# 3. Mint a fresh password (hex = quote/JDBC/env-safe)
NEWPW=$(openssl rand -hex 24)

# 4. Reset the role password. Pass via env -> psql \getenv so it never appears
#    on a command line or in shell history.
docker exec -i -e MPW="$NEWPW" "$PG_CONTAINER" \
  psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 <<'SQL'
\getenv mpw MPW
ALTER ROLE metabase_app PASSWORD :'mpw';
SQL
ok "role $ROLE password reset"

# 5. Store it in Vault (patch preserves homeai_pipeline / readonly fields)
docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" \
  vault kv patch "$KV_PATH" "${ROLE}=${NEWPW}" >/dev/null
ok "stored $ROLE in $KV_PATH (Vault)"

# 6. Verify Vault now returns it and that the role authenticates with it
got=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" \
      vault kv get -format=json "$KV_PATH" | jq -er ".data.data.\"$ROLE\"") \
  || { err "post-write read-back failed — $ROLE not in Vault"; exit 1; }
[[ "$got" == "$NEWPW" ]] || { err "Vault value mismatch"; exit 1; }
if docker exec -e PGPASSWORD="$NEWPW" "$PG_CONTAINER" \
     psql -h 127.0.0.1 -U "$ROLE" -d "$ROLE" -tAc 'select 1' >/dev/null 2>&1; then
  ok "verified: $ROLE authenticates with the new password"
else
  err "WARNING: role did not authenticate over TCP — check pg_hba, continuing anyway"
fi

# 7. Chain into the normal startup (VAULT_TOKEN already exported -> typed once)
printf '\n'
info "metabase password restored — continuing with full startup..."
exec bash /home_ai/start.sh
