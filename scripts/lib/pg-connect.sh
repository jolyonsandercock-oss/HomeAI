#!/usr/bin/env bash
# scripts/lib/pg-connect.sh — shared Postgres + Vault helpers for ops scripts.
#
# psqlc(): runs psql inside homeai-postgres relying on peer auth — verified
# 2026-07-03 that `docker exec homeai-postgres psql -U postgres -d homeai
# -tAc 'SELECT 1'` succeeds with NO password and NO Vault round-trip. Scripts
# that only touch the DB should use this instead of harvesting a Vault token
# + PGPASSWORD on every run: that pattern cost ~100 needless Vault reads/hr
# across the ops crons and turns a sealed Vault into a silent heartbeat
# outage even though Postgres itself is fine.
#
# Call styles (both supported, matching the two patterns already in use):
#   psqlc "SELECT 1"            # single -c command, unaligned pipe-separated output
#   psqlc <<'SQL'                # multi-statement script piped on stdin
#   ...
#   SQL
#
# harvest_vault_token(): for scripts that genuinely need a Vault secret (e.g.
# a third-party API key, not just the DB). Borrows VAULT_TOKEN off
# homeai-google-fetch's own environment, same as the code this replaces did.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib/pg-connect.sh"

psqlc() {
  if [ "$#" -gt 0 ]; then
    docker exec homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 -tAq -c "$1"
  else
    docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 -tAq
  fi
}

harvest_vault_token() {
  docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' \
    | grep '^VAULT_TOKEN=' | cut -d= -f2-
}
