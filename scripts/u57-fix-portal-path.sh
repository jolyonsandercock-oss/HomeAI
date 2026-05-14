#!/usr/bin/env bash
# u57-fix-portal-path.sh — apply the Authelia /auth path fix.
#
# Authelia's SPA HTML had `<base href="https://…/" />` meaning it loaded
# assets from the domain root. With Caddy stripping the /auth prefix,
# /static/* resolved to the dashboard, not back to Authelia → white page.
# Fix: tell Authelia it lives under /auth (server.address path) AND stop
# stripping the prefix in Caddy.

set -euo pipefail

echo "[u57-fix] sudo-cp Authelia config (will prompt once for password)"
sudo cp /tmp/authelia.u57.yml      /home_ai/security/authelia-v2/configuration.yml
sudo chmod 600                      /home_ai/security/authelia-v2/configuration.yml
sudo chown root:root                /home_ai/security/authelia-v2/configuration.yml

echo "[u57-fix] cp Caddyfile (joly-owned, no sudo needed)"
cp /home_ai/config/caddy/Caddyfile.u57 /home_ai/config/caddy/Caddyfile

echo "[u57-fix] force-recreate caddy + authelia"
cd /home_ai
docker compose up -d --no-deps --force-recreate caddy authelia

echo "[u57-fix] waiting for /healthz on FQDN..."
for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -sk -f -o /dev/null https://jolybox.tailc27dff.ts.net/healthz && { echo "[u57-fix] up after ${i}s"; break; }
    sleep 1
done

echo "[u57-fix] verify SPA asset path"
# Authelia SPA HTML should now have <base href> with /auth/ in it.
html=$(curl -sk https://jolybox.tailc27dff.ts.net/auth/)
if echo "$html" | grep -q 'base href="https://jolybox.tailc27dff.ts.net/auth/"'; then
    echo "[u57-fix] ✓ <base href> includes /auth/ — SPA should load correctly"
else
    echo "[u57-fix] ⚠ <base href> still pointing at root — inspect:"
    echo "$html" | grep -E 'base href|static|<title' | head -5
fi
