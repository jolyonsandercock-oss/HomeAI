#!/bin/bash
# /home_ai/scripts/selftest.sh
# Deep verification of the full Home AI stack.
# Exit 0 = all critical checks pass; non-zero = at least one critical check failed.
# Prints a concise status table; logs to /home_ai/backups/selftest-<DATE>.log.
# Don't use -e — we want to continue past failures and tally.
# Don't use -u either — empty FAILURES array is fine.
set -o pipefail
FAILURES=()

LOG="/home_ai/backups/selftest-$(date +%Y%m%d-%H%M).log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee "$LOG") 2>&1

PASS=0
WARN=0
FAIL=0
declare -a FAILURES

check() {
  local name="$1"; local cmd="$2"; local severity="${3:-critical}"
  local out
  if out=$(eval "$cmd" 2>&1); then
    printf '  [PASS] %-55s %s\n' "$name" "$out"
    PASS=$((PASS+1))
  else
    if [[ "$severity" == "warning" ]]; then
      printf '  [WARN] %-55s %s\n' "$name" "$out"
      WARN=$((WARN+1))
    else
      printf '  [FAIL] %-55s %s\n' "$name" "$out"
      FAIL=$((FAIL+1))
      FAILURES+=("$name")
    fi
  fi
}

PSQL="docker exec homeai-postgres psql -U postgres -d homeai -tAc"

echo "── Home AI self-test $(date -u '+%Y-%m-%dT%H:%M:%SZ') ──"
echo

# ── Service health ─────────────────────────────────────────────
echo "[1] Service health"
check "docker daemon"       "docker ps -q | wc -l | tr -d ' '"
# U226: docker inspect exits 0 even for exited containers; require state == running.
running() { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null | command grep -qx running && echo running; }
check "homeai-postgres"     "running homeai-postgres"
check "homeai-vault"        "running homeai-vault"
check "homeai-n8n"          "running homeai-n8n"
check "homeai-prometheus"   "running homeai-prometheus"
check "homeai-alertmanager" "running homeai-alertmanager"
check "homeai-grafana"      "running homeai-grafana"
check "homeai-pdfplumber"   "running homeai-pdfplumber"
check "homeai-markitdown"   "running homeai-markitdown"
check "homeai-ollama"       "running homeai-ollama"
check "homeai-blackbox-exporter" "running homeai-blackbox-exporter"
check "homeai-build-dashboard"   "running homeai-build-dashboard"
echo

# ── Vault ──────────────────────────────────────────────────────
echo "[2] Vault"
check "vault unsealed"  "docker exec homeai-vault vault status -format=json 2>&1 | python3 -c 'import json,sys; d=json.load(sys.stdin); assert not d[\"sealed\"]; print(\"unsealed\")'"
echo

# ── Postgres ───────────────────────────────────────────────────
echo "[3] Postgres + schema"
check "postgres accepts connections" "$PSQL 'SELECT 1' | command grep -q '^1$' && echo ok"
check "events_overflow empty"        "v=\$($PSQL 'SELECT count(*) FROM events_overflow'); [[ \$v -eq 0 ]] && echo \$v"
check "current month partition"      "v=\$($PSQL \"SELECT to_regclass('public.events_'||to_char(NOW(),'YYYY_MM'))::text\"); [[ -n \$v ]] && [[ \$v != '<NULL>' ]] && echo \$v"
check "next-month partition"         "v=\$($PSQL \"SELECT to_regclass('public.events_'||to_char(NOW()+INTERVAL'1 month','YYYY_MM'))::text\"); [[ -n \$v ]] && [[ \$v != '<NULL>' ]] && echo \$v"
check "stuck processing leases"      "v=\$($PSQL \"SELECT count(*) FROM events WHERE status='processing' AND processing_started_at < NOW()-INTERVAL'30 minutes'\"); [[ \$v -eq 0 ]] && echo \$v"
check "dead_letter recent"           "v=\$($PSQL \"SELECT count(*) FROM dead_letter WHERE created_at > NOW()-INTERVAL'1 hour' AND pipeline!='system_marker'\"); [[ \$v -lt 5 ]] && echo \$v" warning
# Silent-pipeline-failure detector (V248): a record that should have produced a
# downstream row but didn't (e.g. a Paperless invoice doc that never reached
# vendor_invoice_inbox — the post-consume-webhook gap). Warning: a backlog should
# surface but isn't service-down.
check "no pipeline drift"            "v=\$($PSQL \"SELECT count(*) FROM home_ai.v_pipeline_drift\"); [[ \$v -eq 0 ]] && echo ok || { echo \"\$v drifted\"; false; }" warning
check "system.state running"         "$PSQL \"SELECT value->>'state' FROM static_context WHERE key='system.state'\" | command grep -q '^running$' && echo running"
check "RLS test suite"               "docker exec -i homeai-postgres psql -U homeai_pipeline -d homeai -v ON_ERROR_STOP=1 < /home_ai/postgres/tests/rls-test-suite.sql 2>&1 | command grep -q 'RLS test suite passed' && echo ok"
echo

# ── n8n workflows ──────────────────────────────────────────────
echo "[4] n8n workflows"
ACTIVE=$($PSQL "SELECT count(*) FROM workflow_entity WHERE active=true")
check "active workflow count >= 13" "[[ $ACTIVE -ge 13 ]] && echo $ACTIVE"
# invoice-pipeline-v1 (P2): keep-on decision MADE 2026-06-08 — reactivated +
# drained cleanly (claim re-admit V250 + router trigger + active + reload; 0 flood).
# Expected active = CRITICAL so a future silent drop pages. (Was retired 05-30,
# revived 06-06, silently off 06-06→06-08 because of a stale selftest exclusion —
# that's the gap this check closes.)
for wf in test-master-router gmail-ingest-v1 partition-maintenance-v1 \
          bank-csv-import-v1 nanny-v1 report-ingestion-v1 \
          alert-sink-v1 hmac-verifier-v1 diagnostics-v1 cleanup-v1 \
          watchdog-n8n-errors; do
  check "  workflow $wf active" "$PSQL \"SELECT active FROM workflow_entity WHERE id='$wf'\" | command grep -q '^t$' && echo active"
done
check "  invoice-pipeline-v1 (P2) active" "$PSQL \"SELECT active FROM workflow_entity WHERE id='invoice-pipeline-v1'\" | command grep -q '^t$' && echo active"
echo

# ── HTTP probes ────────────────────────────────────────────────
echo "[5] HTTP probes"
CURL="docker run --rm --network home_ai_ai-internal curlimages/curl:latest -sS -o /dev/null -w %{http_code}"
check "n8n /healthz"          "code=\$($CURL http://homeai-n8n:5678/healthz 2>/dev/null); [[ \$code == 200 ]] && echo \$code"
check "pdfplumber /healthcheck" "code=\$($CURL http://homeai-pdfplumber:8003/healthcheck 2>/dev/null); [[ \$code == 200 ]] && echo \$code"
check "markitdown /healthcheck" "code=\$($CURL http://homeai-markitdown:8004/healthcheck 2>/dev/null); [[ \$code == 200 ]] && echo \$code"
check "ollama /api/version"   "code=\$($CURL http://homeai-ollama:11434/api/version 2>/dev/null); [[ \$code == 200 ]] && echo \$code"
check "build-dashboard /api/healthz" "code=\$($CURL http://homeai-build-dashboard:8090/api/healthz 2>/dev/null); [[ \$code == 200 ]] && echo \$code"
PROM="docker run --rm --network home_ai_ai-monitoring curlimages/curl:latest -sS"
check "prometheus targets up >= 3" "n=\$($PROM 'http://homeai-prometheus:9090/api/v1/targets' 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for t in d[\"data\"][\"activeTargets\"] if t[\"health\"]==\"up\"))'); [[ \$n -ge 3 ]] && echo \$n"
check "alertmanager ready"       "code=\$($PROM -o /dev/null -w %{http_code} http://homeai-alertmanager:9093/-/ready 2>/dev/null); [[ \$code == 200 ]] && echo \$code"
echo

# ── Custom Postgres metrics ────────────────────────────────────
echo "[6] Postgres exporter custom metrics"
# Capture to a temp file once — running 7 short-lived docker containers
# in a tight loop is flaky and the inline-var approach hits eval-scope
# weirdness. File-based works cleanly.
METRICS_FILE=$(mktemp)
docker run --rm --network home_ai_ai-monitoring curlimages/curl:latest -sS http://homeai-postgres-exporter:9187/metrics > "$METRICS_FILE" 2>/dev/null
for m in events_overflow_count dead_letter_count audit_log_recent_count \
         events_partition_rows_reltuples events_processing_lease_age_oldest_seconds \
         hmac_verification_recent_verified_24h stale_lease_recovery_recent_recovered_recent; do
  check "metric $m exposed" "command grep -q '^$m' '$METRICS_FILE' && echo ok"
done
rm -f "$METRICS_FILE"
echo

# ── Backups ────────────────────────────────────────────────────
echo "[7] Backup"
check "nightly backup ran < 24h ago" "f=/home_ai/backups/last-backup.log; [[ -f \$f ]] && age=\$(( \$(date +%s) - \$(stat -c %Y \$f) )); [[ \$age -lt 86400 ]] && echo \"\${age}s ago\""
check "restic snapshots exist"        "RESTIC_REPOSITORY=/home_ai/backups/restic-local RESTIC_PASSWORD_FILE=/home_ai/backups/.restic-pw restic snapshots --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d))' | grep -E '^[1-9]' "
# Off-NVMe replica on the HDD (separate physical disk) — guards against the
# 'pg_dump to the same disk' single-point-of-failure. Latest HDD snapshot must
# be < 36h old (nightly + slack). WARNING severity (the NVMe copy is primary).
check "off-NVMe HDD backup fresh < 36h" "RESTIC_REPOSITORY=/mnt/shared_storage/home_ai-archive/restic-hdd RESTIC_PASSWORD_FILE=/home_ai/backups/.restic-pw restic snapshots --json 2>/dev/null | python3 -W ignore -c 'import json,sys,datetime as D; d=json.load(sys.stdin); t=max(x[\"time\"][:19] for x in d); age=(D.datetime.utcnow()-D.datetime.fromisoformat(t)).total_seconds(); assert age<129600, f\"{int(age)}s\"; print(f\"{int(age)}s ago\")'" "warning"
echo

# ── Fixtures ───────────────────────────────────────────────────
echo "[8] Test fixtures"
check "sanitiser fixture passes" "node /home_ai/postgres/tests/sanitiser-fixture.js 2>&1 | tail -1 | command grep -q '0 fail' && echo ok"
check "P2 invoice fixture passes" "docker exec -i homeai-postgres psql -U homeai_pipeline -d homeai -v ON_ERROR_STOP=1 < /home_ai/postgres/tests/p2-invoice-fixture.sql 2>&1 | command grep -q 'P2 invoice fixture passed' && echo ok"
# Catches the /api/vehicles + audit_log class: dashboard SQL referencing columns/
# tables that were renamed/dropped (PREPARE every static query vs the live schema).
check "dashboard SQL plans vs live schema" "bash /home_ai/scripts/check-dashboard-sql.sh"
echo

# ── counterparty resolver (refactor 2026-06-09) — read-only smoke, no test rows ──
echo "[9] Counterparty resolver"
check "financial_counterparty seeded" "$PSQL \"SELECT count(*)>0 FROM financial_counterparty WHERE status='active'\" | command grep -q '^t$' && echo ok"
check "resolver resolves a seeded domain" "$PSQL \"SELECT home_ai.resolve_counterparty(jsonb_build_object('email_domain','jrf.lls.com'))->>'decision'\" | command grep -q '^resolve$' && echo ok"
check "resolver abstains on a fake counterparty" "$PSQL \"SELECT home_ai.resolve_counterparty(jsonb_build_object('raw_counterparty','zzzq fake nobody 99999'))->>'decision'\" | command grep -q '^abstain$' && echo ok"
check "resolver in shadow mode (no auto-attribution)" "$PSQL \"SELECT value FROM static_context WHERE key='resolver.mode'\" | command grep -q shadow && echo ok"
echo

# ── Summary ────────────────────────────────────────────────────
echo "── summary ──"
echo "  PASS:    $PASS"
echo "  WARN:    $WARN"
echo "  FAIL:    $FAIL"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo
  echo "FAILURES:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
fi
echo
echo "log: $LOG"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
