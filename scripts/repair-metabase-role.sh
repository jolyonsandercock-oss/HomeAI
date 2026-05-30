#!/usr/bin/env bash
# repair-metabase-role.sh
#
# Root cause (2026-05-30): secret/postgres-roles has no `metabase_app` field
# (only homeai_pipeline + homeai_readonly), so start.sh can't source
# METABASE_APP_PASSWORD and metabase comes up with an empty MB_DB_PASS ->
# SCRAM auth fails -> crash loop. The role's current password is unknown and
# unrecoverable, so we ROTATE it and restore the missing Vault field.
#
# Steps (nothing touches metabase until role + Vault are updated):
#   1. validate token
#   2. generate a fresh password
#   3. ALTER ROLE metabase_app  (Postgres superuser)
#   4. vault kv patch secret/postgres-roles metabase_app=<pw>  (preserves others)
#   5. recreate ONLY metabase with the new password
#   6. verify it initialises and SCRAM auth succeeds
#
# metabase_app is consumed solely by the metabase container — no other service
# breaks. Safe to re-run.
#
# Usage:  ./scripts/repair-metabase-role.sh   (prompts for vault token)

set -euo pipefail
umask 077

readonly VAULT_CONTAINER="homeai-vault"
readonly PG_CONTAINER="homeai-postgres"
readonly COMPOSE="/home_ai/docker-compose.yml"
cleanup() { unset VAULT_TOKEN PW; }
trap cleanup EXIT INT TERM

err() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
ok()  { printf '\033[32m✓\033[0m %s\n' "$*"; }

# 1. Vault unsealed + token valid
sealed=$(docker exec "$VAULT_CONTAINER" vault status -format=json 2>/dev/null | jq -r '.sealed' || echo true)
[[ "$sealed" == "false" ]] || { err "vault is sealed — run ./start.sh first"; exit 1; }
read -rsp '  vault token: ' VAULT_TOKEN; printf '\n'; export VAULT_TOKEN
docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" vault token lookup >/dev/null 2>&1 \
  || { err "token rejected by vault"; exit 1; }
ok "token accepted"

# 2. Fresh password — hex only, so no quoting/SCRAM/compose-interpolation hazards
PW=$(openssl rand -hex 24)
[[ ${#PW} -eq 48 ]] || { err "password generation failed"; exit 1; }

# 3. Rotate the Postgres role (SQL via stdin so the secret isn't in `ps`/argv)
printf "ALTER ROLE metabase_app WITH LOGIN PASSWORD '%s';" "$PW" \
  | docker exec -i "$PG_CONTAINER" psql -U postgres -d homeai -v ON_ERROR_STOP=1 -f - >/dev/null \
  || { err "ALTER ROLE metabase_app failed"; exit 1; }
ok "metabase_app role password rotated in Postgres"

# 4. Restore the missing Vault field (patch preserves homeai_pipeline/homeai_readonly)
docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" \
  vault kv patch secret/postgres-roles metabase_app="$PW" >/dev/null \
  || { err "vault kv patch failed — token may lack write on secret/postgres-roles"; exit 1; }
got=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" \
  vault kv get -format=json secret/postgres-roles | jq -er '.data.data.metabase_app')
[[ "$got" == "$PW" ]] || { err "Vault readback mismatch"; exit 1; }
ok "secret/postgres-roles.metabase_app restored (start.sh will work again)"

# 5. Recreate only metabase with the new password
METABASE_APP_PASSWORD="$PW" docker compose -f "$COMPOSE" up -d --force-recreate --no-deps metabase >/dev/null
ok "metabase recreated"

# 6. Verify
echo "  waiting for metabase to settle (up to 120s)..."
for _ in $(seq 1 24); do
  sleep 5
  logs=$(docker logs homeai-metabase 2>&1 | tail -40)
  if printf '%s' "$logs" | grep -qiE "Metabase Initialization COMPLETE"; then
    ok "metabase initialised — SCRAM auth succeeded"
    docker ps --filter name=homeai-metabase --format '  {{.Names}}: {{.Status}}'
    exit 0
  fi
  if printf '%s' "$logs" | grep -qi "password is an empty string"; then
    err "metabase still seeing empty password — check env"; exit 1
  fi
done
err "metabase did not confirm init within 120s — docker logs homeai-metabase --tail 60"
exit 1
