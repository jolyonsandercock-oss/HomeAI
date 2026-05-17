#!/usr/bin/env bash
# enable-tailscale-funnel.sh — make Caddy publicly reachable via Tailscale Funnel
#
# New CLI (post-1.84): `tailscale funnel <target>` is one command. No more
# separate "funnel on" toggle. The flag --bg backgrounds the listener so it
# persists across SSH sessions.

set -euo pipefail

echo "── Current state ─────────────────────────────────────────────────────"
echo "Serve:"
tailscale serve status 2>&1 | sed 's/^/  /'
echo
echo "Funnel:"
tailscale funnel status 2>&1 | sed 's/^/  /'

cat <<EOF

── Plan ──────────────────────────────────────────────────────────────────

  1. sudo tailscale serve reset            # clear the tailnet-only TCP entry
  2. sudo tailscale funnel --bg https+insecure://localhost:443

Step 2 publishes Caddy on port 443 to the public internet.
The +insecure is needed because Tailscale daemon doesn't verify the cert
by name, even though Caddy serves a valid Tailscale-issued cert to clients.

EOF

read -r -p "Continue? [Y/n] " go
go="${go:-Y}"
[[ "$go" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }

echo
echo "── Step 1: reset previous serve config:"
sudo tailscale serve reset

echo
echo "── Step 2: start funnel (public on 443 → Caddy on localhost:443):"
sudo tailscale funnel --bg https+insecure://localhost:443

echo
sleep 2
echo "── New funnel status:"
tailscale funnel status 2>&1 | sed 's/^/  /'

echo
echo "── DNS propagation check (up to 30 s):"
DNS_OK=""
for i in 1 2 3 4 5 6; do
  if nslookup jolybox.tailc27dff.ts.net 8.8.8.8 2>&1 | grep -q "Address: "; then
    DNS_OK=1; break
  fi
  echo "  attempt $i: NXDOMAIN, retry in 5 s…"
  sleep 5
done

if [ -n "$DNS_OK" ]; then
  echo "✓ public DNS resolves"
  echo
  echo "── Test data path publicly:"
  curl -sS --max-time 10 https://jolybox.tailc27dff.ts.net/data/healthz && echo
  echo
  echo "── Bounce a Vercel /api/health to confirm:"
  curl -sS --max-time 15 https://homai-tau.vercel.app/api/health && echo
else
  echo "⚠ DNS still NXDOMAIN after 30 s. Either propagation is slow, or"
  echo "  Funnel feature isn't enabled for this node in tailnet ACL:"
  echo "  https://login.tailscale.com/admin/settings/funnel"
fi

echo
echo "── Done."
