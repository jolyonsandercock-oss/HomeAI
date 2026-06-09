#!/bin/bash
# u272-dashboard-watchdog.sh — self-test + self-repair for the remote dashboard path.
#
# WHY: Caddy binds the Tailscale IP directly (compose: "<tailnet-ip>:443:443").
# On a boot race (Caddy starts before tailscaled assigns the IP) or a host port
# conflict, Caddy ends up "Up" but with NO published ports → the FQDN is dead
# while every container looks healthy. Nothing detected this. This watchdog
# checks the path end-to-end and repairs Caddy when the front door is shut.
#
# Checks (in order):
#   1. tailscaled up + tailnet IP assigned        (can't repair here → alert)
#   2. caddy container running
#   3. caddy publishes :443 on the tailnet IP
#   4. end-to-end HTTPS probe: GET https://<fqdn>/healthz == 200
#   5. drift: running image main.py == source main.py (alert only; rebuild is manual)
#
# Repair: docker compose up -d --no-deps --force-recreate caddy  (rate-limited).
# Alerts: Telegram on repair action, repair failure, or undetectable cause.
#
# Cron: every 5 min. Idempotent; no-op when healthy.
set -uo pipefail
cd /home_ai || exit 1

LOG_TAG="u272-dashboard-watchdog"
STATE_DIR="/home_ai/logs/.u272-state"
mkdir -p "$STATE_DIR"
RATE_FILE="$STATE_DIR/last_repair_epoch"
MAX_REPAIRS_PER_HR=3

log(){ echo "$(date -Is) [$LOG_TAG] $*"; }

tg_alert(){
  local msg="$1"
  local vt
  vt=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^VAULT_TOKEN=' | cut -d= -f2-)
  [ -z "$vt" ] && { log "tg_alert: no vault token, skipping"; return; }
  docker exec -i -e VT="$vt" -e MSG="$msg" homeai-bot-responder python3 -u - <<'PY' 2>/dev/null || true
import os, json, urllib.request
vt=os.environ["VT"]; msg=os.environ["MSG"]
def vault(p):
    r=urllib.request.urlopen(urllib.request.Request(f"http://vault:8200/v1/secret/data/{p}",headers={"X-Vault-Token":vt}),timeout=5)
    return json.loads(r.read())["data"]["data"]
tg=vault("telegram")
urllib.request.urlopen(urllib.request.Request(
  f"https://api.telegram.org/bot{tg['bot_token']}/sendMessage",
  data=json.dumps({"chat_id":tg["chat_id"],"text":msg,"parse_mode":"Markdown","disable_web_page_preview":True}).encode(),
  headers={"Content-Type":"application/json"},method="POST"),timeout=10)
PY
}

repair_allowed(){
  local now epoch count
  now=$(date +%s)
  # keep only repair timestamps within the last hour
  if [ -f "$RATE_FILE" ]; then
    awk -v cutoff=$((now-3600)) '$1>cutoff' "$RATE_FILE" > "$RATE_FILE.tmp" && mv "$RATE_FILE.tmp" "$RATE_FILE"
    count=$(wc -l < "$RATE_FILE")
  else count=0; fi
  [ "$count" -lt "$MAX_REPAIRS_PER_HR" ]
}
record_repair(){ date +%s >> "$RATE_FILE"; }

# ── derive identity dynamically (tailnet IPs/names are not hardcoded) ──
TIP=$(tailscale ip -4 2>/dev/null | head -1)
FQDN=$(tailscale status --json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null)

# ── Check 1: tailscale up ──
if [ -z "$TIP" ] || [ -z "$FQDN" ]; then
  log "FAIL: tailscaled down or no tailnet IP/FQDN (TIP='$TIP' FQDN='$FQDN') — cannot repair from here"
  tg_alert "🔴 *Dashboard watchdog*: tailscaled appears DOWN (no tailnet IP). Remote dashboard unreachable. Manual: check \`tailscale status\` on jolybox."
  exit 1
fi

probe(){ curl -sk --max-time 8 --resolve "$FQDN:443:$TIP" -o /dev/null -w "%{http_code}" "https://$FQDN/healthz" 2>/dev/null; }

# ── Checks 2-4: caddy running, :443 bound, end-to-end probe ──
running=$(docker inspect -f '{{.State.Running}}' homeai-caddy 2>/dev/null || echo false)
bound443=$(docker port homeai-caddy 2>/dev/null | grep -c "443/tcp -> $TIP:443" || true)
code=$(probe)

if [ "$running" = "true" ] && [ "$bound443" -ge 1 ] && [ "$code" = "200" ]; then
  log "OK: caddy running, :443 bound on $TIP, https://$FQDN/healthz=200"
else
  log "UNHEALTHY: running=$running bound443=$bound443 healthz=$code — attempting repair"
  if ! repair_allowed; then
    log "repair suppressed (>$MAX_REPAIRS_PER_HR/hr) — alerting only"
    tg_alert "🔴 *Dashboard watchdog*: front door down (caddy running=$running, 443bound=$bound443, healthz=$code) and repair rate-limit hit. Manual attention needed."
    exit 1
  fi
  record_repair
  docker compose up -d --no-deps --force-recreate caddy >/dev/null 2>&1
  sleep 3
  code2=$(probe)
  bound2=$(docker port homeai-caddy 2>/dev/null | grep -c "443/tcp -> $TIP:443" || true)
  if [ "$code2" = "200" ] && [ "$bound2" -ge 1 ]; then
    log "REPAIRED: caddy recreated, healthz=200, :443 bound"
    tg_alert "🟢 *Dashboard watchdog*: remote dashboard was down (healthz=$code) — auto-repaired (recreated Caddy). https://$FQDN/ is back."
  else
    log "REPAIR FAILED: healthz=$code2 bound=$bound2"
    tg_alert "🔴 *Dashboard watchdog*: auto-repair of Caddy FAILED (healthz=$code2, 443bound=$bound2). Likely a port conflict on the tailnet IP — check \`docker compose up caddy\` output on jolybox."
    exit 1
  fi
fi

# ── Check 5: image-vs-source drift (alert only; rebuild is manual + needs Vault) ──
src_md5=$(md5sum services/build-dashboard/main.py 2>/dev/null | cut -d' ' -f1)
img_md5=$(docker exec homeai-build-dashboard md5sum /app/main.py 2>/dev/null | cut -d' ' -f1)
if [ -n "$src_md5" ] && [ -n "$img_md5" ] && [ "$src_md5" != "$img_md5" ]; then
  log "DRIFT: build-dashboard image main.py != source (img=$img_md5 src=$src_md5) — rebuild needed"
  drift_flag="$STATE_DIR/drift_alerted"
  if [ ! -f "$drift_flag" ] || [ "$(cat "$drift_flag" 2>/dev/null)" != "$src_md5" ]; then
    tg_alert "🟡 *Dashboard watchdog*: build-dashboard running image is STALE vs source (main.py differs). Rebuild: \`docker compose build build-dashboard && docker compose up -d build-dashboard\` (harvest POSTGRES_PASSWORD from Vault first)."
    echo "$src_md5" > "$drift_flag"
  fi
else
  rm -f "$STATE_DIR/drift_alerted" 2>/dev/null || true
fi

exit 0
