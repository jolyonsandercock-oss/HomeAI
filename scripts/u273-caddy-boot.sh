#!/bin/bash
# u273-caddy-boot.sh — close the Caddy boot race at its source.
#
# Caddy binds the Tailscale IP (<tip>:443). On host boot, Docker restarts Caddy
# (restart: unless-stopped) which can fire BEFORE tailscaled has assigned the IP
# → Caddy comes up with NO published ports → FQDN dead. This runs from @reboot:
# it waits for Docker + the tailnet IP to be ready, then (re)creates Caddy so it
# binds correctly. The */5 u272 watchdog remains the ongoing backstop.
set -uo pipefail
cd /home_ai || exit 1
log(){ echo "$(date -Is) [u273-caddy-boot] $*"; }

# Wait up to ~150s for Docker daemon + a tailnet IPv4 to exist.
TIP=""
for i in $(seq 1 75); do
  if docker info >/dev/null 2>&1; then
    TIP=$(tailscale ip -4 2>/dev/null | head -1)
    [ -n "$TIP" ] && break
  fi
  sleep 2
done

if [ -z "$TIP" ]; then
  log "tailnet IP not assigned after wait — leaving recovery to the */5 watchdog"
  exit 1
fi
log "ready: docker up, tailnet IP=$TIP"

# Ensure Caddy is bound to <tip>:443; recreate if not.
bound=$(docker port homeai-caddy 2>/dev/null | grep -c "443/tcp -> $TIP:443" || true)
if [ "$bound" -ge 1 ]; then
  log "caddy already bound to $TIP:443 — no action"
else
  log "caddy NOT bound to $TIP:443 — recreating via compose"
  docker compose up -d --no-deps --force-recreate caddy >/dev/null 2>&1
  sleep 3
  log "post-recreate ports: $(docker port homeai-caddy 2>/dev/null | tr '\n' ' ')"
fi
log "done"
exit 0
