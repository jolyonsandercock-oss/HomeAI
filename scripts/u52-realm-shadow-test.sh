#!/usr/bin/env bash
#
# u52-realm-shadow-test.sh — parallel-read regression harness for the
# realm RLS rollout (U52).
#
# Three modes:
#   --baseline            Capture current row counts as homeai_pipeline (no
#                         realm GUC set) into realm-shadow-baseline.json.
#                         Run this once BEFORE applying V65.
#
#   --check transitional  Re-run the same battery (no realm GUC). After V65
#                         the transitional NULL branch of realm_isolation
#                         should keep behaviour identical → no drift.
#                         Exits non-zero on drift.
#
#   --check enforced      For each of owner/work/family, SET LOCAL
#                         app.current_realm and assert observed count ==
#                         expected count. Expected = unrestricted count
#                         where realm IN (<r>,'shared') or <r>='owner'.
#                         Exits non-zero on mismatch.
#
# Implementation notes:
#   - Connects as postgres superuser then SET LOCAL ROLE homeai_pipeline so
#     RLS fires on the queries (current_user, not session_user, decides).
#     This avoids needing the pipeline password from Vault.
#   - Expected-count side runs as superuser without SET ROLE — RLS is
#     bypassed there, and the WHERE clause does the realm filtering by hand.
#   - Every test query is wrapped in BEGIN ... ROLLBACK so SET LOCAL is
#     transaction-scoped and never leaks.
#
# Exit codes:
#   0  green
#   1  drift / mismatch
#   2  setup error

set -euo pipefail

BASELINE_PATH="/home_ai/data/realm-shadow-baseline.json"
PSQL_FLAGS=(-X -q -A -t)

TABLES=(
  emails
  events
  vendor_invoice_inbox
  workforce_shifts
  workforce_departments
  bank_transactions
  child_events
  rent_payments
  properties
  tenancies
  weather_daily
  email_tasks
  guest_reviews
  bot_feedback
  caterbook_email_reports
  caterbook_observations
  caterbook_daily_snapshots
  ops_thresholds
  product_canonical
  audit_log
)

usage() {
  cat <<EOF >&2
Usage:
  $0 --baseline
  $0 --check transitional
  $0 --check enforced
EOF
  exit 2
}

require_running() {
  if ! docker inspect -f '{{.State.Running}}' homeai-postgres 2>/dev/null | grep -q true; then
    echo "ERROR: homeai-postgres is not running." >&2
    exit 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq required." >&2
    exit 2
  fi
}

# raw_count <table>
# Count rows visible to homeai_pipeline with no realm GUC (transitional
# state — entity_isolation alone, app.current_entity='all').
raw_count() {
  local table="$1"
  docker exec -i homeai-postgres psql -U postgres -d homeai "${PSQL_FLAGS[@]}" <<SQL 2>/dev/null | tr -d '[:space:]'
BEGIN;
SET LOCAL ROLE homeai_pipeline;
SET LOCAL app.current_entity = 'all';
SELECT COUNT(*) FROM ${table};
ROLLBACK;
SQL
}

# realm_count <table> <realm>
# Same as raw_count but with app.current_realm set.
realm_count() {
  local table="$1"
  local realm="$2"
  docker exec -i homeai-postgres psql -U postgres -d homeai "${PSQL_FLAGS[@]}" <<SQL 2>/dev/null | tr -d '[:space:]'
BEGIN;
SET LOCAL ROLE homeai_pipeline;
SET LOCAL app.current_entity = 'all';
SET LOCAL app.current_realm = '${realm}';
SELECT COUNT(*) FROM ${table};
ROLLBACK;
SQL
}

# expected_count <table> <realm>
# RLS-bypass count with manual realm WHERE filter. For rent_payments the
# realm lives on tenancies, not on rent_payments itself.
expected_count() {
  local table="$1"
  local realm="$2"
  local sql
  if [[ "$table" == "rent_payments" ]]; then
    if [[ "$realm" == "owner" ]]; then
      sql="SELECT COUNT(*) FROM rent_payments;"
    else
      sql="SELECT COUNT(*) FROM rent_payments rp JOIN tenancies t ON t.id=rp.tenancy_id WHERE t.realm IN ('${realm}','shared');"
    fi
  else
    if [[ "$realm" == "owner" ]]; then
      sql="SELECT COUNT(*) FROM ${table};"
    else
      sql="SELECT COUNT(*) FROM ${table} WHERE realm IN ('${realm}','shared');"
    fi
  fi
  docker exec -i homeai-postgres psql -U postgres -d homeai "${PSQL_FLAGS[@]}" -c "$sql" 2>/dev/null | tr -d '[:space:]'
}

mode="${1:-}"
case "$mode" in
  --baseline)
    require_running
    echo "Capturing baseline (role=homeai_pipeline, entity=all, realm unset)..."
    declare -a kvs=()
    for t in "${TABLES[@]}"; do
      n=$(raw_count "$t")
      [[ -z "$n" ]] && n=0
      kvs+=( "\"$t\":$n" )
      printf "  %-25s %s\n" "$t" "$n"
    done
    joined=$(IFS=, ; echo "${kvs[*]}")
    json="{\"captured_at\":\"$(date -Iseconds)\",\"mode\":\"pre-V65-baseline\",\"counts\":{${joined}}}"
    if ! echo "$json" | jq . > "$BASELINE_PATH" 2>/dev/null; then
      echo "ERROR: produced JSON failed jq validation:" >&2
      echo "$json" >&2
      exit 2
    fi
    echo "Wrote $BASELINE_PATH"
    exit 0
    ;;

  --check)
    require_running
    sub="${2:-}"
    if [[ ! -f "$BASELINE_PATH" ]]; then
      echo "ERROR: baseline file $BASELINE_PATH not found. Run --baseline first." >&2
      exit 2
    fi

    case "$sub" in
      transitional)
        echo "Transitional check (no realm GUC; expect zero drift vs baseline)..."
        drift=0
        for t in "${TABLES[@]}"; do
          observed=$(raw_count "$t")
          [[ -z "$observed" ]] && observed=0
          expected=$(jq -r --arg t "$t" '.counts[$t] // "MISSING"' "$BASELINE_PATH")
          if [[ "$observed" != "$expected" ]]; then
            printf "  DRIFT %-25s  baseline=%s  observed=%s\n" "$t" "$expected" "$observed"
            drift=1
          else
            printf "  OK    %-25s  %s\n" "$t" "$observed"
          fi
        done
        if [[ $drift -ne 0 ]]; then
          echo "FAIL: transitional check found drift." >&2
          exit 1
        fi
        echo "PASS: transitional branch preserved baseline."
        exit 0
        ;;

      enforced)
        echo "Enforced check (per-realm GUC; observed must equal expected)..."
        fails=0
        for realm in owner work family; do
          echo "  Realm=${realm}"
          for t in "${TABLES[@]}"; do
            observed=$(realm_count "$t" "$realm")
            [[ -z "$observed" ]] && observed=0
            expected=$(expected_count "$t" "$realm")
            [[ -z "$expected" ]] && expected=0
            if [[ "$observed" != "$expected" ]]; then
              printf "    FAIL %-25s  expected=%s  observed=%s\n" "$t" "$expected" "$observed"
              fails=$((fails+1))
            else
              printf "    OK   %-25s  %s\n" "$t" "$observed"
            fi
          done
        done
        if [[ $fails -ne 0 ]]; then
          echo "FAIL: enforced check reported ${fails} mismatch(es)." >&2
          exit 1
        fi
        echo "PASS: realm enforcement matches expectation across all tables."
        exit 0
        ;;

      *)
        usage
        ;;
    esac
    ;;

  *)
    usage
    ;;
esac
