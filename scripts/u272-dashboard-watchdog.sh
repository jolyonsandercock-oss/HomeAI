#!/bin/bash
# u272-dashboard-watchdog.sh — self-test + self-repair for the remote dashboard stack.
#
# Surfaces covered end-to-end:
#   FRONT DOOR  Caddy on the tailnet IP (<tip>:443) — the FQDN entrypoint.
#   /app        homeai-frontend  (Next.js — the dashboard Jo uses).
#   /work,/*    homeai-build-dashboard (FastAPI — counterparty-review, ops pages).
#
# WHY each layer is checked separately:
#   - Caddy binds the Tailscale IP directly; a boot race (Caddy up before
#     tailscaled assigns the IP) or a host port conflict leaves Caddy "Up" with
#     NO published ports → FQDN dead while everything looks healthy.
#   - Backends sit behind Authelia forward_auth, so a PUBLIC probe of /app or
#     /work returns 302 (auth redirect) even when the backend is DEAD. Backend
#     health must be probed INTERNALLY (container→container), bypassing auth.
#
# Repairs: Caddy → recreate via compose (needs the port rebind); backends →
# docker restart. All rate-limited per-surface. Telegram on action/failure.
# Plus an image-vs-source drift alert for build-dashboard (baked, not mounted).
#
# Cron: every 5 min. Idempotent; no-op when healthy.
set -uo pipefail
cd /home_ai || exit 1

LOG_TAG="u272-dashboard-watchdog"
STATE_DIR="/home_ai/logs/.u272-state"
mkdir -p "$STATE_DIR"
MAX_REPAIRS_PER_HR=3

log(){ echo "$(date -Is) [$LOG_TAG] $*"; }

tg_alert(){
  local msg="$1" vt
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

# Per-surface rate limit. $1 = surface key. Returns 0 if a repair is allowed.
repair_allowed(){
  local key="$1" now rf count
  now=$(date +%s); rf="$STATE_DIR/repairs_$key"
  if [ -f "$rf" ]; then
    awk -v c=$((now-3600)) '$1>c' "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
    count=$(wc -l < "$rf")
  else count=0; fi
  [ "$count" -lt "$MAX_REPAIRS_PER_HR" ]
}
record_repair(){ date +%s >> "$STATE_DIR/repairs_$1"; }

# ── derive identity dynamically (tailnet IPs/names are not hardcoded) ──
TIP=$(tailscale ip -4 2>/dev/null | head -1)
FQDN=$(tailscale status --json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null)

if [ -z "$TIP" ] || [ -z "$FQDN" ]; then
  log "FAIL: tailscaled down or no tailnet IP/FQDN (TIP='$TIP' FQDN='$FQDN')"
  tg_alert "🔴 *Dashboard watchdog*: tailscaled appears DOWN (no tailnet IP). Remote dashboard unreachable. Check \`tailscale status\` on jolybox."
  exit 1
fi

# ── FRONT DOOR: Caddy ──────────────────────────────────────────────────────
healthz(){ curl -sk --max-time 8 --resolve "$FQDN:443:$TIP" -o /dev/null -w "%{http_code}" "https://$FQDN/healthz" 2>/dev/null; }
running=$(docker inspect -f '{{.State.Running}}' homeai-caddy 2>/dev/null || echo false)
bound443=$(docker port homeai-caddy 2>/dev/null | grep -c "443/tcp -> $TIP:443" || true)
code=$(healthz)
if [ "$running" = "true" ] && [ "$bound443" -ge 1 ] && [ "$code" = "200" ]; then
  log "OK caddy: running, :443 bound on $TIP, /healthz=200"
else
  log "UNHEALTHY caddy: running=$running bound443=$bound443 healthz=$code"
  if repair_allowed caddy; then
    record_repair caddy
    docker compose up -d --no-deps --force-recreate caddy >/dev/null 2>&1
    sleep 3
    if [ "$(healthz)" = "200" ] && [ "$(docker port homeai-caddy 2>/dev/null | grep -c "443/tcp -> $TIP:443")" -ge 1 ]; then
      log "REPAIRED caddy"; tg_alert "🟢 *Dashboard watchdog*: Caddy front door was down — auto-repaired. https://$FQDN/ is back."
    else
      log "REPAIR FAILED caddy"; tg_alert "🔴 *Dashboard watchdog*: Caddy auto-repair FAILED — likely a port conflict on the tailnet IP. Check \`docker compose up caddy\` on jolybox."; exit 1
    fi
  else
    tg_alert "🔴 *Dashboard watchdog*: Caddy down and repair rate-limit hit. Manual attention needed."; exit 1
  fi
fi

# ── BACKENDS: internal probe (bypasses Authelia), restart on failure ────────
# $1=key  $2=container  $3=internal URL (reached from caddy's network)  $4=label
check_backend(){
  local key="$1" cont="$2" url="$3" label="$4" run probe_rc
  run=$(docker inspect -f '{{.State.Running}}' "$cont" 2>/dev/null || echo false)
  docker exec homeai-caddy wget -q -T 6 -O /dev/null "$url" >/dev/null 2>&1; probe_rc=$?
  if [ "$run" = "true" ] && [ "$probe_rc" -eq 0 ]; then
    log "OK backend $label ($cont)"
    return 0
  fi
  log "UNHEALTHY backend $label ($cont): running=$run probe_rc=$probe_rc"
  if ! repair_allowed "$key"; then
    tg_alert "🔴 *Dashboard watchdog*: \`$label\` ($cont) down and repair rate-limit hit. Manual attention needed."
    return 1
  fi
  record_repair "$key"
  docker restart "$cont" >/dev/null 2>&1
  sleep 5
  docker exec homeai-caddy wget -q -T 6 -O /dev/null "$url" >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    log "REPAIRED backend $label ($cont)"
    tg_alert "🟢 *Dashboard watchdog*: \`$label\` ($cont) was down — auto-restarted, now serving."
  else
    log "REPAIR FAILED backend $label ($cont)"
    tg_alert "🔴 *Dashboard watchdog*: restart of \`$label\` ($cont) FAILED — still not responding. Manual attention needed."
    return 1
  fi
}

check_backend frontend       homeai-frontend        "http://homeai-frontend:3000/app"               "/app (frontend)"
check_backend builddashboard homeai-build-dashboard "http://homeai-build-dashboard:8090/api/healthz" "/work + counterparty (build-dashboard)"

# ── DRIFT: build-dashboard image vs source (alert only; rebuild is manual) ──
src_md5=$(md5sum services/build-dashboard/main.py 2>/dev/null | cut -d' ' -f1)
img_md5=$(docker exec homeai-build-dashboard md5sum /app/main.py 2>/dev/null | cut -d' ' -f1)
if [ -n "$src_md5" ] && [ -n "$img_md5" ] && [ "$src_md5" != "$img_md5" ]; then
  log "DRIFT: build-dashboard image main.py != source"
  flag="$STATE_DIR/drift_alerted"
  if [ "$(cat "$flag" 2>/dev/null)" != "$src_md5" ]; then
    tg_alert "🟡 *Dashboard watchdog*: build-dashboard image is STALE vs source (main.py differs). Rebuild: \`docker compose build build-dashboard && docker compose up -d build-dashboard\` (Vault POSTGRES_PASSWORD first)."
    echo "$src_md5" > "$flag"
  fi
else
  rm -f "$STATE_DIR/drift_alerted" 2>/dev/null || true
fi

log "done"
exit 0
