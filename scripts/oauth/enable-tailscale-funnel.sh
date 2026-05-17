#!/usr/bin/env bash
# enable-tailscale-funnel.sh — make Caddy publicly reachable via Tailscale Funnel
#
# Requires sudo for tailscale CLI. Run once. Settings persist across reboots.
#
# After running, https://jolybox.tailc27dff.ts.net/ becomes publicly resolvable
# and the /data/* path serves the data-proxy (already wired in Caddyfile).

set -euo pipefail

echo "── Current Funnel state:"
tailscale funnel status 2>&1 | head -5

cat <<EOF

── Enabling Funnel on port 443 (Caddy's TLS listener) ─────────────────────

This makes https://jolybox.tailc27dff.ts.net/ public on the internet.
Existing routes:
  /              → Authelia-gated build-dashboard (unchanged)
  /auth/*        → Authelia portal (always open)
  /data/*        → bearer-token-gated data-proxy (used by Vercel)
  /app/*         → homeai-frontend (Next.js)

Will run: sudo tailscale funnel --bg --https 443 https+insecure://localhost:443
EOF

read -r -p "Continue? [Y/n] " go
go="${go:-Y}"
[[ "$go" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }

echo
sudo tailscale funnel --bg --https 443 https+insecure://localhost:443

echo
sleep 2
echo "── New funnel status:"
tailscale funnel status 2>&1 | head -10

echo
echo "── Public DNS resolution check:"
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
else
  echo "⚠ DNS still NXDOMAIN. Tailscale Funnel propagation can take 1-2 minutes."
  echo "  Try again with:  curl https://jolybox.tailc27dff.ts.net/data/healthz"
fi

echo
echo "── Done. Vercel app https://homai-tau.vercel.app should now load live data."
echo "  Cache may take 30-60s to expire — Vercel functions don't cache misses long."
