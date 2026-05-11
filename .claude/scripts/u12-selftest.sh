#!/bin/bash
# U12 selftest — validates Phase 2 Hardening deliverables.
set -uo pipefail
PASS=0; FAIL=0
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

check() {
  if [ "$3" = "$2" ]; then
    echo -e "${GREEN}PASS${NC} $1 (=$3)"; PASS=$((PASS+1))
  else
    echo -e "${RED}FAIL${NC} $1 (expected=$2 got=$3)"; FAIL=$((FAIL+1))
  fi
}

echo "=== U12 Phase 2 Hardening — selftest ==="
echo

echo "--- B. Image pinning (compose patch-pinned, not :latest or major-only) ---"
check "postgres pinned to 16.x patch"  "1" "$(grep -cE 'image: postgres:16\.[0-9]+' /home_ai/docker-compose.yml)"
check "redis pinned to 7.x patch"      "1" "$(grep -cE 'image: redis:7\.[0-9]+\.[0-9]+-alpine' /home_ai/docker-compose.yml)"
check "caddy pinned to 2.x patch"      "1" "$(grep -cE 'image: caddy:2\.[0-9]+\.[0-9]+-alpine' /home_ai/docker-compose.yml)"
check "netdata pinned to vX.Y.Z"       "1" "$(grep -cE 'image: netdata/netdata:v[0-9]+\.[0-9]+\.[0-9]+' /home_ai/docker-compose.yml)"
check "no remaining :latest tags"      "0" "$(grep -cE 'image: [^#]*:latest' /home_ai/docker-compose.yml || true)"

echo
echo "--- C. Caddy reverse-proxy routes ---"
check "Caddy /healthz returns ok"      "ok"  "$(wget -qO- http://100.104.82.53/healthz 2>/dev/null)"
check "Caddy /dashboard reaches API"   "1"   "$([ "$(wget -qO- http://100.104.82.53/dashboard/api/snapshot 2>/dev/null | head -c 50 | grep -c 'generated_at')" -gt 0 ] && echo 1 || echo 0)"
check "Caddy /auth returns 503 holder" "503" "$(wget -SqO- http://100.104.82.53/auth 2>&1 | grep -oE 'HTTP/1.1 [0-9]+' | head -1 | awk '{print $2}')"
check "Caddy port 80 bound on Tailscale" "1" "$(docker port homeai-caddy 2>/dev/null | grep -c '^80/tcp -> 100.104.82.53:80')"
check "Caddy still serves n8n on 5678" "1" "$([ "$(wget -SqO- http://100.104.82.53:5678/healthz 2>&1 | grep -c '200 OK')" -gt 0 ] && echo 1 || echo 0)"

echo
echo "--- D. Authelia (deferred — should NOT be running) ---"
check "Authelia gated by phase2 profile" "1" "$(awk '/^  [a-z-]+:$/{srv=$1} /phase2/ && srv=="authelia:" {print "yes"}' /home_ai/docker-compose.yml | grep -c yes)"
check "Authelia container not running"   "0" "$(docker ps --filter name=homeai-authelia --format '{{.Names}}' | wc -l)"

echo
echo "=========================================="
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
