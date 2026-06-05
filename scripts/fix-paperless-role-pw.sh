#!/usr/bin/env bash
# fix-paperless-role-pw.sh — reset the `paperless` DB role password, store it in
# Vault (secret/postgres-roles, field `paperless`), and recreate paperless.
#
# Why: PAPERLESS_DB_PASSWORD was never in Vault or start.sh's fetch_secrets — it
# only ever lived in .env, which no longer has it — so PAPERLESS_DBPASS resolves
# empty and paperless crash-loops ("fe_sendauth: no password supplied"). The old
# password is unrecoverable (SCRAM hash). This makes Vault the single source of
# truth, matching metabase/n8n; start.sh now fetches `paperless` from the same
# secret, so a clean reboot brings paperless up without this ever recurring.
# Paperless's data DB is untouched — only the login password changes.
#
# Usage:  bash /home_ai/scripts/fix-paperless-role-pw.sh   (prompts for token once)

set -euo pipefail
umask 077

readonly VAULT_CONTAINER="homeai-vault"
readonly PG_CONTAINER="homeai-postgres"
readonly ROLE="paperless"
readonly KV_PATH="secret/postgres-roles"
readonly COMPOSE="/home_ai/docker-compose.yml"

cleanup() { unset VAULT_TOKEN NEWPW REDIS_PASSWORD; }
trap cleanup EXIT INT TERM

err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }

# 1. Vault must be unsealed
sealed=$(docker exec "$VAULT_CONTAINER" vault status -format=json 2>/dev/null | jq -r '.sealed' || echo true)
[[ "$sealed" == "false" ]] || { err "vault is sealed — run ./start.sh first"; exit 1; }

# 2. Token (prompt once)
if [[ -z "${VAULT_TOKEN:-}" ]]; then
  read -rs -p "  vault token: " VAULT_TOKEN; printf '\n'
fi
export VAULT_TOKEN
docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" vault token lookup >/dev/null 2>&1 \
  || { err "token rejected by vault"; exit 1; }
ok "token accepted"

# 3. Mint a fresh password (hex = quote/env/Django-safe)
NEWPW=$(openssl rand -hex 24)

# 4. Reset the role password (env -> psql \getenv, never on a command line)
docker exec -i -e MPW="$NEWPW" "$PG_CONTAINER" \
  psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 <<'SQL'
\getenv mpw MPW
ALTER ROLE paperless PASSWORD :'mpw';
SQL
ok "role $ROLE password reset"

# 5. Store it in Vault (patch preserves the other postgres-roles fields)
docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" \
  vault kv patch "$KV_PATH" "${ROLE}=${NEWPW}" >/dev/null
ok "stored $ROLE in $KV_PATH (Vault)"

# 6. Verify Vault returns it and the role authenticates with it
got=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" \
      vault kv get -format=json "$KV_PATH" | jq -er ".data.data.\"$ROLE\"") \
  || { err "post-write read-back failed — $ROLE not in Vault"; exit 1; }
[[ "$got" == "$NEWPW" ]] || { err "Vault value mismatch"; exit 1; }
docker exec -e PGPASSWORD="$NEWPW" "$PG_CONTAINER" \
  psql -h 127.0.0.1 -U "$ROLE" -d "$ROLE" -tAc 'select 1' >/dev/null 2>&1 \
  && ok "verified: $ROLE authenticates with the new password" \
  || { err "role did not authenticate over TCP — aborting before recreate"; exit 1; }

# 7. Recreate paperless with ALL the runtime secrets it needs injected from this
#    shell. A targeted --no-deps recreate does NOT inherit start.sh's exported
#    secrets, so besides the DB password paperless also needs REDIS_PASSWORD
#    (its broker URL is redis://:${REDIS_PASSWORD}@redis:6379/2 and redis requires
#    auth) — without it paperless starts but every task dies "Authentication
#    required". .env supplies PAPERLESS_SECRET_KEY / PAPERLESS_ADMIN_PASSWORD.
REDIS_PASSWORD=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" \
  vault kv get -field=password secret/redis 2>/dev/null) \
  || { err "could not fetch secret/redis password from Vault"; exit 1; }
export PAPERLESS_DB_PASSWORD="$NEWPW" REDIS_PASSWORD
docker compose -f "$COMPOSE" up -d --force-recreate --no-deps paperless
ok "paperless recreated"
unset PAPERLESS_DB_PASSWORD REDIS_PASSWORD

# 8. Confirm it stops crash-looping
info "waiting for paperless to settle (up to 90s)..."
for i in $(seq 1 18); do
  sleep 5
  status=$(docker inspect -f '{{.State.Status}}' homeai-paperless 2>/dev/null || echo gone)
  if [[ "$status" == "running" ]]; then
    if docker logs homeai-paperless 2>&1 | tail -40 | grep -qi 'no password supplied'; then
      continue
    fi
    if docker logs homeai-paperless 2>&1 | grep -qiE 'Paperless-ngx .* ready|Listening at|Operations to perform|migrations.*OK'; then
      ok "paperless running, DB auth OK"
      docker ps --filter name=homeai-paperless --format '  {{.Names}}: {{.Status}}'
      exit 0
    fi
  fi
done
err "paperless did not settle cleanly — check: docker logs --tail 50 homeai-paperless"
docker ps --filter name=homeai-paperless --format '  {{.Names}}: {{.Status}}'
exit 1
