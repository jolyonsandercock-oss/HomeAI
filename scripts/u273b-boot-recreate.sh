#!/usr/bin/env bash
# u273b — after reboot, wait for the tailnet IP then heal every tailnet-bound
# port publish. Complements u273 (Caddy-only). Runs @reboot; idempotent.
set -euo pipefail
echo "START $(date -Is)"
for i in $(seq 1 60); do
  ip -4 addr show tailscale0 2>/dev/null | grep -q '100.104.82.53' && break; sleep 5
done
ip -4 addr show tailscale0 | grep -q '100.104.82.53' || { echo "tailnet IP never arrived"; exit 1; }
sleep 20   # let compose restart-policies finish their own attempts first

declare -A OWNER   # host-port -> compose service key
while read -r svc port; do OWNER[$port]=$svc; done <<'MAP'
grafana 3001
authelia 9091
open-webui 8088
llm-router 8001
homeai-data-proxy 8771
wa-bridge 8770
homeai-mcp 8765
paperless 8011
ollama 11434
build-dashboard 8090
MAP
# Caddy (80/443/5678/3000) is u273's job.

DEAD=()
for port in "${!OWNER[@]}"; do
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://100.104.82.53:${port}/") || code=000
  [ "$code" = "000" ] && DEAD+=("${OWNER[$port]}")
done
if [ "${#DEAD[@]}" -eq 0 ]; then echo "all publishes alive"; exit 0; fi
echo "dead publishes -> recreating: ${DEAD[*]}"
bash /home_ai/scripts/recreate-with-secrets.sh "${DEAD[@]}" || echo "WARN: recreate returned $? — continuing to post-heal verification"
sleep 15
STILL_DEAD=()
for port in "${!OWNER[@]}"; do
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://100.104.82.53:${port}/") || code=000
  echo "post-heal port $port -> $code"
  [ "$code" = "000" ] && STILL_DEAD+=("${OWNER[$port]}")
done
if [ "${#STILL_DEAD[@]}" -gt 0 ]; then
  echo "PARTIAL HEAL: still dead -> ${STILL_DEAD[*]}"
  echo "DONE $(date -Is)"
  exit 1
fi
echo "DONE $(date -Is)"
