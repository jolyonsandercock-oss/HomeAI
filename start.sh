#!/usr/bin/env bash
# Home AI — startup script.
# Unseals Vault, fetches infrastructure secrets, issues a fresh n8n token,
# then runs docker compose up. Run once after every reboot.
#
# Usage:  ./start.sh
# Permissions: 0700 (owner only). NEVER add secrets to this file.

set -euo pipefail
umask 077

readonly COMPOSE_DIR="/home_ai"
readonly VAULT_CONTAINER="homeai-vault"
readonly N8N_POLICY="n8n-policy"
readonly N8N_TOKEN_TTL="24h"

# Secrets are unset on any exit path, including SIGINT/SIGTERM.
cleanup_secrets() {
  unset POSTGRES_PASSWORD N8N_DB_PASSWORD METABASE_APP_PASSWORD \
        PAPERLESS_DB_PASSWORD \
        REDIS_PASSWORD GRAFANA_ADMIN_PASSWORD OPEN_WEBUI_SECRET \
        PAYLOAD_HMAC_KEY ANTHROPIC_API_KEY \
        VAULT_N8N_TOKEN VAULT_TOKEN ROLES_JSON
}
trap cleanup_secrets EXIT INT TERM

err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }

# -------------------------------------------------------------------
# 1. Prerequisites
# -------------------------------------------------------------------
check_prereqs() {
  command -v docker >/dev/null || { err "docker not on PATH"; exit 1; }
  command -v jq >/dev/null     || { err "jq not on PATH (apt install jq)"; exit 1; }
  [[ -f "$COMPOSE_DIR/docker-compose.yml" ]] \
    || { err "$COMPOSE_DIR/docker-compose.yml missing"; exit 1; }
  docker ps --format '{{.Names}}' | grep -q "^$VAULT_CONTAINER\$" \
    || { err "$VAULT_CONTAINER not running — start it first: docker compose up -d vault"; exit 1; }
  ok "prereqs"
}

# -------------------------------------------------------------------
# 2. Unseal (idempotent — skipped if already unsealed)
# -------------------------------------------------------------------
vault_is_sealed() {
  local sealed
  sealed=$(docker exec "$VAULT_CONTAINER" vault status -format=json 2>/dev/null \
           | jq -r '.sealed' || echo "true")
  [[ "$sealed" == "true" ]]
}

submit_unseal_key() {
  local prompt="$1" key
  while true; do
    read -rs -p "$prompt" key
    printf '\n'
    if printf '%s\n' "$key" \
       | docker exec -i "$VAULT_CONTAINER" vault operator unseal - >/dev/null 2>&1; then
      key=""
      return 0
    fi
    err "rejected — try again"
  done
}

unseal_vault() {
  if ! vault_is_sealed; then
    ok "vault already unsealed"
    return 0
  fi
  info "vault is sealed — enter 3 of 5 unseal keys"
  submit_unseal_key "  key 1/3: "
  submit_unseal_key "  key 2/3: "
  submit_unseal_key "  key 3/3: "
  if vault_is_sealed; then
    err "vault still sealed after 3 keys — aborting"
    exit 1
  fi
  ok "vault unsealed"
}

# -------------------------------------------------------------------
# 3. Authenticate
# -------------------------------------------------------------------
prompt_token() {
  # Reuse a token already supplied in the environment (e.g. when chained from
  # a helper script) so it is only typed once; otherwise prompt interactively.
  if [[ -z "${VAULT_TOKEN:-}" ]]; then
    read -rs -p "  vault token: " VAULT_TOKEN
    printf '\n'
  fi
  export VAULT_TOKEN
  if ! docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" \
       vault token lookup >/dev/null 2>&1; then
    err "token rejected by vault"
    exit 1
  fi
  ok "token accepted"
}

# -------------------------------------------------------------------
# 4. Fetch secrets
# -------------------------------------------------------------------
vault_kv_field() {
  # vault_kv_field <path> <field>  →  echoes value, exits 1 if missing/null
  local path="$1" field="$2" value
  value=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" \
          vault kv get -format=json "$path" 2>/dev/null \
          | jq -er ".data.data.\"$field\"") || {
    err "secret/$path missing field '$field'"
    exit 1
  }
  printf '%s' "$value"
}

fetch_secrets() {
  POSTGRES_PASSWORD=$(vault_kv_field secret/postgres password)
  REDIS_PASSWORD=$(vault_kv_field secret/redis password)
  GRAFANA_ADMIN_PASSWORD=$(vault_kv_field secret/grafana admin_password)
  OPEN_WEBUI_SECRET=$(vault_kv_field secret/open-webui secret_key)
  PAYLOAD_HMAC_KEY=$(vault_kv_field secret/signing payload_hmac_key)
  ANTHROPIC_API_KEY=$(vault_kv_field secret/anthropic api_key)

  # postgres-roles has multiple fields; fetch once, parse twice.
  ROLES_JSON=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" \
               vault kv get -format=json secret/postgres-roles)
  N8N_DB_PASSWORD=$(printf '%s' "$ROLES_JSON" | jq -er '.data.data.homeai_pipeline') \
    || { err "secret/postgres-roles missing 'homeai_pipeline'"; exit 1; }
  # Per-service role passwords are NON-CRITICAL: a missing one must only degrade
  # its own service, never abort startup. (Hard-failing on metabase_app is what
  # downed the whole box on 2026-06-05.) Warn, leave empty, carry on — the owning
  # container will crash-loop in isolation and the fix script re-mints it.
  METABASE_APP_PASSWORD=$(printf '%s' "$ROLES_JSON" | jq -er '.data.data.metabase_app') \
    || { err "secret/postgres-roles missing 'metabase_app' — metabase will not start (run scripts/fix-metabase-role-pw.sh)"; METABASE_APP_PASSWORD=""; }
  PAPERLESS_DB_PASSWORD=$(printf '%s' "$ROLES_JSON" | jq -er '.data.data.paperless') \
    || { err "secret/postgres-roles missing 'paperless' — paperless will not start (run scripts/fix-paperless-role-pw.sh)"; PAPERLESS_DB_PASSWORD=""; }
  ROLES_JSON=""

  # U250: breakfast-link signing secret. NON-CRITICAL — missing only degrades
  # build-dashboard (fails loud at import) + the breakfast email crons.
  BREAKFAST_TOKEN_SECRET=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" \
      vault kv get -format=json secret/breakfast 2>/dev/null \
      | jq -er '.data.data.token_secret') \
    || { err "secret/breakfast missing 'token_secret' — build-dashboard will not start (U250)"; BREAKFAST_TOKEN_SECRET=""; }

  export POSTGRES_PASSWORD N8N_DB_PASSWORD METABASE_APP_PASSWORD \
         PAPERLESS_DB_PASSWORD \
         REDIS_PASSWORD GRAFANA_ADMIN_PASSWORD OPEN_WEBUI_SECRET \
         PAYLOAD_HMAC_KEY ANTHROPIC_API_KEY BREAKFAST_TOKEN_SECRET
  ok "10 infrastructure secrets fetched"
}

# -------------------------------------------------------------------
# 5. Issue fresh n8n token (24h, renewable)
# -------------------------------------------------------------------
issue_n8n_token() {
  VAULT_N8N_TOKEN=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" \
    vault token create -policy="$N8N_POLICY" -ttl="$N8N_TOKEN_TTL" \
                       -renewable=true -format=json 2>/dev/null \
    | jq -er '.auth.client_token') || {
    err "failed to issue n8n token (is policy '$N8N_POLICY' loaded?)"
    exit 1
  }
  export VAULT_N8N_TOKEN
  ok "n8n token issued (ttl=$N8N_TOKEN_TTL)"
}

# -------------------------------------------------------------------
# 6. Run compose
# -------------------------------------------------------------------
run_compose() {
  cd "$COMPOSE_DIR"
  info "docker compose up -d"
  docker compose up -d
  ok "compose started"
}

# -------------------------------------------------------------------
# 7. Health check
# -------------------------------------------------------------------
health_check() {
  info "waiting for core services to report healthy..."
  local deadline=$(( SECONDS + 60 ))
  while (( SECONDS < deadline )); do
    if docker exec homeai-postgres pg_isready -U postgres -q 2>/dev/null \
       && docker exec homeai-redis redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null \
          | grep -q PONG \
       && ! vault_is_sealed; then
      ok "postgres + redis + vault healthy"
      return 0
    fi
    sleep 2
  done
  err "core services did not all become healthy within 60s"
  docker compose ps
  return 1
}

# -------------------------------------------------------------------
# 8. Detect drift between n8n stored Postgres credential and the
#    homeai_pipeline password. n8n credentials are stored encrypted in
#    n8n's own DB and the import:credentials CLI silently no-ops on
#    existing IDs — so we can't auto-fix. We just warn loudly.
#    Fix when warned: log into n8n UI → Credentials → HomeAI Postgres →
#    paste new password → save. (See feedback memory.)
# -------------------------------------------------------------------
check_n8n_credential_drift() {
  local cred_id="iTuuNfsqHY49MGhk"
  local env_len cred_len
  env_len=${#N8N_DB_PASSWORD}
  docker exec homeai-n8n n8n export:credentials \
    --id="$cred_id" --decrypted --output=/tmp/cred-check.json >/dev/null 2>&1 || {
      info "credential drift check skipped — could not export $cred_id"
      return 0
    }
  cred_len=$(docker exec homeai-n8n sh -c \
    "node -e 'console.log(JSON.parse(require(\"fs\").readFileSync(\"/tmp/cred-check.json\")).at(0).data.password.length)'" \
    2>/dev/null) || cred_len=0
  docker exec homeai-n8n rm -f /tmp/cred-check.json
  if [[ "$env_len" == "$cred_len" ]]; then
    ok "n8n Postgres credential matches Vault (length $env_len)"
  else
    err "DRIFT: n8n cred password length=$cred_len, Vault password length=$env_len"
    err "FIX: open n8n UI → Credentials → HomeAI Postgres → paste new password → save"
    err "(Until fixed, Master Router and every Postgres-using workflow will fail auth)"
  fi
}

summary() {
  printf '\n'
  ok "Home AI startup complete"
  docker compose ps --format 'table {{.Service}}\t{{.Status}}'
}

# -------------------------------------------------------------------
# main
# -------------------------------------------------------------------
main() {
  printf '\033[1mHome AI — startup\033[0m\n\n'
  check_prereqs
  unseal_vault
  prompt_token
  fetch_secrets
  issue_n8n_token
  run_compose
  health_check
  check_n8n_credential_drift
  summary
}

main "$@"
