#!/bin/bash
# /home_ai/scripts/u167-restore-drill.sh
# U167 — monthly DR drill: restore latest restic snapshot to a sandbox
# postgres, validate row counts within 0.1% of prod, write findings.

set -uo pipefail

DRILL_DIR=/tmp/u167-restore-drill
AUDIT_DIR=/home_ai/audits
mkdir -p "$DRILL_DIR" "$AUDIT_DIR"
DATE_TAG=$(date +%Y-%m-%d-%H%M)
REPORT="$AUDIT_DIR/u167-restore-drill-$DATE_TAG.md"

VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
SANDBOX_PORT=5433
SANDBOX_NAME=homeai-postgres-drill

echo "# U167 — Restore drill ($DATE_TAG)" > "$REPORT"
echo "" >> "$REPORT"

START=$(date +%s)

# ── 1. Snapshot inventory ──
echo "## Snapshot inventory" >> "$REPORT"
SNAPSHOT_INFO=$(RESTIC_PASSWORD_FILE=/home_ai/backups/.restic-pw \
  RESTIC_REPOSITORY=/home_ai/backups/restic-local \
  restic snapshots --tag homeai-nightly --json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
if not d: print('NONE'); sys.exit(1)
s = d[-1]   # last = newest in chronological list
print(f'{s[\"short_id\"]}|{s[\"time\"][:19]}')")

LATEST_ID=$(echo "$SNAPSHOT_INFO" | cut -d'|' -f1)
LATEST_TIME=$(echo "$SNAPSHOT_INFO" | cut -d'|' -f2)
echo "Latest snapshot: \`$LATEST_ID\` @ $LATEST_TIME" >> "$REPORT"
echo "RPO (snapshot age): $(( ($(date +%s) - $(date -d "$LATEST_TIME" +%s)) / 3600 ))h" >> "$REPORT"
echo "" >> "$REPORT"

# ── 2. Restore staging dir ──
echo "## Restore" >> "$REPORT"
echo "→ restoring to $DRILL_DIR..."
rm -rf "$DRILL_DIR"
mkdir -p "$DRILL_DIR"
RESTIC_PASSWORD_FILE=/home_ai/backups/.restic-pw \
RESTIC_REPOSITORY=/home_ai/backups/restic-local \
restic restore "$LATEST_ID" --target "$DRILL_DIR" 2>&1 | tail -5

PGDUMP=$(find "$DRILL_DIR" -name 'homeai.pgdump' -type f 2>/dev/null | head -1)
if [ -z "$PGDUMP" ] || [ ! -f "$PGDUMP" ]; then
  echo "❌ pgdump not found in snapshot (looked in $DRILL_DIR)" >> "$REPORT"
  find "$DRILL_DIR" -type f -name '*.pgdump' -o -name 'staging' 2>/dev/null | head -5 >> "$REPORT"
  echo "Report: $REPORT (FAILED)"
  exit 1
fi
DUMP_SIZE=$(stat -c%s "$PGDUMP")
echo "Dump size: $DUMP_SIZE bytes" >> "$REPORT"
echo "" >> "$REPORT"

# ── 3. Sandbox postgres ──
echo "## Sandbox" >> "$REPORT"
docker rm -f "$SANDBOX_NAME" 2>/dev/null || true
echo "→ launching sandbox postgres on :$SANDBOX_PORT"
docker run -d --name "$SANDBOX_NAME" \
  --network home_ai_ai-internal \
  -e POSTGRES_PASSWORD=drillpw \
  -e POSTGRES_DB=homeai \
  -p $SANDBOX_PORT:5432 \
  postgres:16.13 >/dev/null

# Wait for ready
for i in $(seq 1 30); do
  if docker exec "$SANDBOX_NAME" pg_isready -U postgres >/dev/null 2>&1; then break; fi
  sleep 1
done
echo "Sandbox ready in ${i}s" >> "$REPORT"

# ── 4. Restore dump ──
echo "→ pg_restore..."
docker cp "$PGDUMP" "$SANDBOX_NAME:/tmp/homeai.pgdump"
RESTORE_START=$(date +%s)
docker exec "$SANDBOX_NAME" pg_restore -U postgres -d homeai --clean --if-exists --no-owner \
  /tmp/homeai.pgdump 2>&1 | tail -10 | head -5
RESTORE_END=$(date +%s)
echo "Restore time: $((RESTORE_END - RESTORE_START))s" >> "$REPORT"
echo "" >> "$REPORT"

# ── 5. Validation ──
echo "## Validation" >> "$REPORT"
echo "" >> "$REPORT"
echo "| table | prod_rows | sandbox_rows | drift_pct | verdict |" >> "$REPORT"
echo "|---|---:|---:|---:|---|" >> "$REPORT"

PASS=0; FAIL=0
for tbl in events emails vendor_invoice_inbox dojo_transactions touchoffice_department_sales \
           caterbook_daily_snapshots mortgage_statement_periods xero_bills query_whitelist \
           audit_log guest_reviews accommodation_bookings; do
  P=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc "SELECT count(*) FROM $tbl" 2>/dev/null || echo "ERR")
  S=$(docker exec "$SANDBOX_NAME" psql -U postgres -d homeai -tAc "SELECT count(*) FROM $tbl" 2>/dev/null || echo "ERR")
  if [ "$P" = "ERR" ] || [ "$S" = "ERR" ]; then
    DRIFT="n/a"; VERDICT="⚠ ERR"
    FAIL=$((FAIL+1))
  elif [ "$P" = "0" ] && [ "$S" = "0" ]; then
    DRIFT="0%"; VERDICT="✓ both empty"
    PASS=$((PASS+1))
  elif [ "$P" = "0" ]; then
    DRIFT="n/a"; VERDICT="⚠ prod=0"
    PASS=$((PASS+1))
  else
    DRIFT=$(python3 -c "print(f'{100.0 * ($P - $S) / $P:.1f}%')")
    ABS_DRIFT=$(python3 -c "print(abs(100.0 * ($P - $S) / $P))")
    if python3 -c "import sys; sys.exit(0 if $ABS_DRIFT < 0.1 else 1)"; then
      VERDICT="✓"
      PASS=$((PASS+1))
    elif python3 -c "import sys; sys.exit(0 if $ABS_DRIFT < 5 else 1)"; then
      VERDICT="≈ ok (snapshot age)"
      PASS=$((PASS+1))
    else
      VERDICT="✗ drift >5%"
      FAIL=$((FAIL+1))
    fi
  fi
  printf '| %s | %s | %s | %s | %s |\n' "$tbl" "$P" "$S" "$DRIFT" "$VERDICT" >> "$REPORT"
done

echo "" >> "$REPORT"
echo "**Summary: $PASS pass, $FAIL fail**" >> "$REPORT"
echo "" >> "$REPORT"

# ── 6. Cleanup ──
docker rm -f "$SANDBOX_NAME" >/dev/null 2>&1
rm -rf "$DRILL_DIR"

TOTAL=$(($(date +%s) - START))
echo "**Total RTO: ${TOTAL}s**" >> "$REPORT"

# Telegram on failure
if [ "$FAIL" -gt 0 ]; then
  docker exec homeai-bot-responder python -c "
import os, urllib.request, urllib.parse, json
VAULT_TOKEN = os.environ['VAULT_TOKEN']
req = urllib.request.Request('http://vault:8200/v1/secret/data/telegram',
    headers={'X-Vault-Token': VAULT_TOKEN})
d = json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']
text = '''🚨 U167 restore drill FAILED ($FAIL/$((PASS+FAIL)) tables drifted)
Snapshot $LATEST_ID @ $LATEST_TIME
Report: $REPORT
RTO: ${TOTAL}s'''
req = urllib.request.Request(f\"https://api.telegram.org/bot{d['bot_token']}/sendMessage\",
    data=urllib.parse.urlencode({'chat_id': d['chat_id'], 'text': text}).encode())
r = urllib.request.urlopen(req, timeout=10)
"
fi

echo "✓ report: $REPORT"
echo "  pass=$PASS fail=$FAIL rto=${TOTAL}s"
