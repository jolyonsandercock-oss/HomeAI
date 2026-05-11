#!/bin/bash
# /home_ai/.claude/scripts/u26-post-wake.sh
#
# Autonomous cleanup that should run AFTER ./start.sh restores all services.
# Specifically:
#   1. Re-enable the Vault Prometheus scrape (vault.hcl telemetry was staged
#      in U14 but only activates on a fresh Vault start, which start.sh does).
#   2. Probe homeai-google-fetch /healthz and /openapi.json to confirm the
#      new /attachments + /attachment endpoints landed.
#   3. Probe the gmail-poll-driver-v1 next fire — should now succeed.
#   4. Backfill any pending email attachment metadata (Caterbook PDFs we
#      can fetch now that google-fetch is back).
#   5. Refresh dashboard's debt.yaml entries for items now resolved.
#
# Idempotent. Safe to re-run. Run as your normal user.

set -uo pipefail
GREEN='\033[0;32m'; YEL='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'

step() { echo; echo -e "${YEL}→${NC} $1"; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YEL}!${NC} $1"; }
err()  { echo -e "  ${RED}✗${NC} $1"; }

# ── 1. Vault Prometheus scrape ────────────────────────────────────────────
step "Re-enabling Vault Prometheus scrape (staged in U14)"

# First: probe the vault metrics endpoint to see if telemetry is actually live.
# Telemetry config requires a Vault CONTAINER restart, not just an unseal —
# start.sh only unseals. If telemetry isn't live, we skip uncommenting so
# Prometheus doesn't fire TargetDown alerts.
if docker exec homeai-prometheus wget -qO- 'http://homeai-vault:8200/v1/sys/metrics?format=prometheus' 2>&1 | head -c 50 | grep -q '^# HELP'; then
  ok "Vault metrics endpoint is responding (telemetry config IS live)"
  if grep -qE '^\s*-\s*job_name:\s*vault\s*$' /home_ai/monitoring/prometheus.yml; then
    ok "scrape already uncommented"
  else
    if grep -q '^  # - job_name: vault' /home_ai/monitoring/prometheus.yml; then
      sed -i \
        -e 's|^  # - job_name: vault$|  - job_name: vault|' \
        -e 's|^  #   metrics_path: /v1/sys/metrics$|    metrics_path: /v1/sys/metrics|' \
        -e 's|^  #   params:$|    params:|' \
        -e 's|^  #     format: \[prometheus\]$|      format: [prometheus]|' \
        -e 's|^  #   static_configs:$|    static_configs:|' \
        -e 's|^  #     - targets: \[homeai-vault:8200\]$|      - targets: [homeai-vault:8200]|' \
          /home_ai/monitoring/prometheus.yml
      ok "uncommented vault scrape job"
      docker restart homeai-prometheus >/dev/null 2>&1 && ok "prometheus restarted"
    fi
  fi
else
  warn "Vault metrics endpoint returns 403 — telemetry config not yet active"
  warn "  start.sh unseals but doesn't restart the vault container."
  warn "  To activate metrics, run: docker restart homeai-vault && bash /home_ai/.claude/scripts/u13-vault-unseal.sh"
  warn "  Skipping prometheus uncomment to avoid TargetDown noise."
fi

# ── 2. google-fetch health + new endpoints ────────────────────────────────
step "Verifying google-fetch + new /attachments endpoints"
if ! docker ps --filter name=homeai-google-fetch --filter status=running --format '{{.Names}}' | grep -q homeai-google-fetch; then
  err "homeai-google-fetch is NOT running — re-run ./start.sh first"
  exit 1
fi
ok "container running"

ROUTES=$(docker exec homeai-google-fetch python3 -c "
import urllib.request, json
print(' '.join(sorted(json.loads(urllib.request.urlopen('http://localhost:8011/openapi.json').read())['paths'].keys())))
" 2>/dev/null)
if echo "$ROUTES" | grep -q '/attachment'; then
  ok "/attachments + /attachment endpoints live"
else
  err "new endpoints missing — was the image rebuilt? expected /attachments and /attachment"
fi

# ── 3. gmail-poll-driver-v1 next fire ─────────────────────────────────────
step "Checking gmail-poll-driver-v1 recent fires"
RECENT_SUCCESS=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc \
  "SELECT COUNT(*) FROM execution_entity WHERE \"workflowId\"='gmail-poll-driver-v1' AND \"startedAt\" > NOW() - INTERVAL '20 minutes' AND status='success';" 2>/dev/null)
RECENT_ERROR=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc \
  "SELECT COUNT(*) FROM execution_entity WHERE \"workflowId\"='gmail-poll-driver-v1' AND \"startedAt\" > NOW() - INTERVAL '20 minutes' AND status='error';" 2>/dev/null)
if [[ "${RECENT_SUCCESS:-0}" -gt 0 ]]; then
  ok "$RECENT_SUCCESS successful poll(s) in last 20 min"
else
  warn "no successful polls yet (last 20m) — wait one full cron cycle and check again"
fi
[[ "${RECENT_ERROR:-0}" -gt 0 ]] && warn "$RECENT_ERROR error(s) in last 20m — inspect via /dashboard or /forensics"

# ── 4. Attachment backfill probe ──────────────────────────────────────────
step "Probing attachment availability on existing Caterbook emails"
SAMPLE=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc \
  "SELECT account || ' ' || gmail_message_id FROM emails WHERE from_address LIKE '%caterbook%' AND has_attachment=true LIMIT 1;" 2>/dev/null)
if [[ -n "$SAMPLE" ]]; then
  ACC=$(echo "$SAMPLE" | awk '{print $1}')
  GMID=$(echo "$SAMPLE" | awk '{print $2}')
  RESP=$(docker exec homeai-google-fetch python3 -c "
import urllib.request, json
try:
    r = urllib.request.urlopen(f'http://localhost:8011/attachments/${ACC}/${GMID}', timeout=10)
    d = json.loads(r.read())
    print(f'OK {len(d[\"attachments\"])} attachment(s)')
except Exception as e:
    print('ERR', e)
" 2>&1)
  if echo "$RESP" | grep -q '^OK'; then
    ok "$RESP — attachment fetch works end-to-end (sample: $GMID)"
  else
    warn "attachment fetch returned: $RESP"
  fi
else
  warn "no Caterbook-with-attachment emails in inbox right now"
fi

# ── 5. Refresh debt.yaml ──────────────────────────────────────────────────
step "Updating dashboard debt.yaml for items now resolved"
DEBT=/home_ai/services/build-dashboard/data/debt.yaml
# Remove the google-fetch-stopped entry now that it's back
if grep -q 'google-fetch container stopped' "$DEBT"; then
  python3 -c "
import re
src = open('$DEBT').read()
# Remove the 'google-fetch container stopped' item (4 lines starting at 'severity: high')
src = re.sub(r'\n\s*- severity: high\n\s*title: google-fetch container stopped.*?(?=\n  - |\Z)', '', src, count=1, flags=re.DOTALL)
open('$DEBT', 'w').write(src)
"
  ok "removed google-fetch-stopped debt entry"
fi

# Vault metrics: change title since it's now active
if grep -q 'Vault metrics scrape — staged' "$DEBT"; then
  if grep -qE '^\s*-\s*job_name:\s*vault\s*$' /home_ai/monitoring/prometheus.yml; then
    python3 -c "
import re
src = open('$DEBT').read()
src = re.sub(r'\n\s*- severity: low\n\s*title: Vault metrics scrape — staged.*?(?=\n  - |\Z)', '', src, count=1, flags=re.DOTALL)
open('$DEBT', 'w').write(src)
"
    ok "removed Vault metrics debt entry (scrape now live)"
  fi
fi

echo
echo -e "${GREEN}── post-wake done ──${NC}"
# Mark the touch-file so the orchestrator knows this chunk has run
touch /home_ai/.claude/.u26-post-wake-done
echo "Run u26-menu.sh to see the updated state."
