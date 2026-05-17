#!/usr/bin/env bash
# u126-dext-pair.sh — interactive Dext browser pairing via VNC.
#
# Host has no X server, so the script spawns Xvfb + x11vnc inside the
# Playwright container and exposes VNC on port 5902. You connect from
# your Mac:
#
#   # On your Mac (in a separate terminal):
#   ssh -L 5902:127.0.0.1:5902 jolybox
#   # Then open VNC viewer (macOS: Cmd+K in Finder → vnc://localhost:5902)
#
# Inside VNC you see the Dext login page (auto-filled), click submit,
# handle any 2FA Dext asks, wait until the Dext dashboard loads,
# then close VNC. The persistent profile saves cookies for u126-export.

set -euo pipefail

VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
mkdir -p /home_ai/data/dext-profile

CREDS_JSON=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -format=json secret/dext 2>/dev/null) || {
  echo "❌ secret/dext not set. Run /home_ai/scripts/oauth/set-dext-creds.sh first."
  exit 1
}
EMAIL=$(echo "$CREDS_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data']['email'])")
PASSWORD=$(echo "$CREDS_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data']['password'])")
URL=$(echo "$CREDS_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data']['url'])")

# Stop any prior pair container that might be holding port 5902
docker rm -f dext-pair 2>/dev/null || true

ENV_FILE=$(mktemp); chmod 600 "$ENV_FILE"
trap 'rm -f "$ENV_FILE"' EXIT
{
  echo "DEXT_EMAIL=$EMAIL"
  echo "DEXT_PASSWORD=$PASSWORD"
  echo "DEXT_URL=$URL"
} > "$ENV_FILE"

cat <<EOF
── Spawning Playwright + VNC container ──────────────────────────────────

VNC will be exposed on host port 5902. From your Mac:

  1. In a separate terminal, port-forward:
       ssh -L 5902:127.0.0.1:5902 jolybox

  2. Open VNC viewer:
       Finder → Cmd+K → vnc://localhost:5902
       (or any VNC client — TightVNC, RealVNC, macOS built-in)
       No password.

  3. You'll see Chromium with the Dext login page (auto-filled).
     Click submit. Handle any 2FA Dext asks. Wait for dashboard.
     Then close this terminal (Ctrl+C) — the script saves session.

URL: $URL
Email: $EMAIL
Browser will stay open up to 15 minutes.

EOF

docker run --rm -d --name dext-pair \
  --network home_ai_ai-egress \
  -p 127.0.0.1:5902:5902 \
  -v /home_ai/data/dext-profile:/profile \
  --env-file "$ENV_FILE" \
  --shm-size 2g \
  home_ai-playwright-service:latest \
  bash -c "
    set -e
    # Install x11vnc + xvfb if not present
    which x11vnc >/dev/null 2>&1 || apt-get update >/dev/null 2>&1 && apt-get install -y x11vnc xvfb >/dev/null 2>&1
    Xvfb :99 -screen 0 1280x900x24 &
    sleep 1
    x11vnc -display :99 -nopw -forever -rfbport 5902 -shared -bg
    sleep 1
    DISPLAY=:99 python3 -c \"
import os, time
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        '/profile', headless=False,
        viewport={'width': 1280, 'height': 900},
        args=['--no-sandbox'],
    )
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    page.goto(os.environ['DEXT_URL'], wait_until='domcontentloaded', timeout=20000)
    try:
        page.fill('input[type=email], input[name=email]', os.environ['DEXT_EMAIL'])
        page.fill('input[type=password], input[name=password]', os.environ['DEXT_PASSWORD'])
    except Exception as e:
        print(f'(auto-fill skipped: {e})')
    deadline = time.time() + 900
    while time.time() < deadline:
        try: _ = page.title()
        except Exception: break
        time.sleep(2)
    ctx.close()
\"
"

sleep 8
docker ps --filter name=dext-pair --format '  {{.Status}}  ports: {{.Ports}}'
echo
echo "Container running. VNC ready on 127.0.0.1:5902."
echo "When done, kill it:  docker stop dext-pair"
