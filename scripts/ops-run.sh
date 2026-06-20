#!/usr/bin/env bash
# ops-run.sh <pipeline_name> -- <command...>
#
# Wraps a pipeline command and records a run heartbeat in ops.pipeline_runs
# (started_at / finished_at / status ok|failed / rows_affected). This is the
# missing "did it actually run, and did it error?" layer on top of the existing
# data-freshness watchdogs. <pipeline_name> MUST exist in ops.pipeline_registry
# (FK). Row count is read from an `OPS_ROWS=<n>` line on the command's stdout if
# present; otherwise NULL.
#
# Heartbeat recording is BEST-EFFORT: if Vault/DB are unreachable it is skipped
# and NEVER changes the wrapped command's exit code. The wrapped command's output
# is passed through unchanged so existing cron logs are unaffected.
set -uo pipefail
NAME="$1"; shift
[ "${1:-}" = "--" ] && shift
START="$(date -Is)"

TMP="$(mktemp)"
"$@" >"$TMP" 2>&1; RC=$?
cat "$TMP"                                  # passthrough for cron logs
ROWS="$(grep -oE 'OPS_ROWS=[0-9]+' "$TMP" | tail -1 | cut -d= -f2)"
rm -f "$TMP"

STATUS=ok; [ "$RC" -ne 0 ] && STATUS=failed

# best-effort heartbeat — never affects $RC
(
  VT="$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^VAULT_TOKEN=' | cut -d= -f2-)"
  PW="$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/postgres 2>/dev/null)"
  docker exec -e PGPASSWORD="$PW" homeai-postgres psql -U postgres -d homeai -tAc \
    "SELECT ops.record_pipeline_run('${NAME//\'/}','$STATUS','$START',${ROWS:-NULL},'ops-run wrapper');" >/dev/null 2>&1
) || true

exit $RC
