#!/usr/bin/env bash
# enable-tailscale-funnel.sh — make Caddy publicly reachable via Tailscale Funnel
#
# Modern syntax: `tailscale serve` defines the local route, `tailscale funnel on`
# exposes it to the public internet. Requires sudo + Funnel feature enabled
# in https://login.tailscale.com/admin/acls (which Jo has done).

set -euo pipefail

echo "── Current state ─────────────────────────────────────────────────────"
echo "Serve:"
tailscale serve status 2>&1 | sed 's/^/  /'
echo "Funnel:"
tailscale funnel status 2>&1 | sed 's/^/  /'

cat <<EOF

── Setting up Funnel on port 443 ────────────────────────────────────────

This makes https://jolybox.tailc27dff.ts.net/ public.
Caddy is already listening on host :443 with the tailscale cert; we tell
Tailscale to proxy public 443 traffic to localhost:443 (Caddy).

Will run (in this order):
  sudo tailscale serve --bg --tcp 443 tcp://localhost:443
  sudo tailscale funnel 443 on
EOF

read -r -p "Continue? [Y/n] " go
go="${go:-Y}"
[[ "$go" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }

echo
echo "── Step 1: serve (TCP passthrough to Caddy):"
# TCP passthrough means TLS termination happens at Caddy (which has the cert),
# not at Tailscale. SNI passes through.
sudo tailscale serve reset 2>/dev/null || true
sudo tailscale serve --bg --tcp 443 tcp://localhost:443

echo
echo "── Step 2: funnel on:"
sudo tailscale funnel 443 on

echo
sleep 2
echo "── New funnel status:"
tailscale funnel status 2>&1 | sed 's/^/  /'

echo
echo "── DNS propagation check:"
DNS_OK=""
for i in 1 2 3 4 5; do
  if nslookup jolybox.tailc27dff.ts.net 8.8.8.8 2>&1 | grep -q "Address: "; then
    DNS_OK=1; break
  fi
  echo "  attempt $i: NXDOMAIN, retry in 5s…"
  sleep 5
done

if [ -n "$DNS_OK" ]; then
  echo "✓ public DNS resolves"
  echo
  echo "── Test the data path publicly:"
  curl -sS https://jolybox.tailc27dff.ts.net/data/healthz && echo
  echo
  echo "── Bounce a Vercel /api/health to confirm:"
  curl -sS https://homai-tau.vercel.app/api/health && echo
else
  echo "⚠ DNS still NXDOMAIN. Two possible causes:"
  echo "  1. Tailscale Funnel propagation takes 1-2 minutes — re-test soon"
  echo "  2. Funnel feature not enabled for this node in tailnet ACL"
  echo "     Check https://login.tailscale.com/admin/settings/funnel"
fi

echo
echo "── Done."
