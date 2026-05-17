#!/usr/bin/env bash
# u126-dext-pair.sh — interactive one-time Dext browser pairing.
#
# Spawns a headed Playwright window so you can complete login + any 2FA
# Dext requires. Persistent profile is saved to /home_ai/data/dext-profile
# so subsequent runs of u126-dext-export.sh re-use the cookies.
#
# Requires a display (X11/VNC). For headless host setup, use VNC:
#   docker run --rm -p 5900:5900 ... (see PAIRING.md in wa-bridge)

set -euo pipefail

VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
mkdir -p /home_ai/data/dext-profile /home_ai/data/dext-exports

# Read creds (won't be echoed — passed via env to a one-off container)
CREDS_JSON=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -format=json secret/dext 2>/dev/null) || {
  echo "❌ secret/dext not set. Run /home_ai/scripts/oauth/set-dext-creds.sh first."
  exit 1
}
EMAIL=$(echo "$CREDS_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data']['email'])")
PASSWORD=$(echo "$CREDS_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data']['password'])")
URL=$(echo "$CREDS_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data']['url'])")

echo "── Spawning headed browser. Complete any 2FA challenges manually."
echo "   URL: $URL"
echo "   Email: $EMAIL"
echo
echo "When the Dext dashboard is loaded, close the browser to save the session."

# Pass creds via env-file so they don't appear in `ps aux`
ENV_FILE=$(mktemp); chmod 600 "$ENV_FILE"
trap 'rm -f "$ENV_FILE"' EXIT
{
  echo "DEXT_EMAIL=$EMAIL"
  echo "DEXT_PASSWORD=$PASSWORD"
  echo "DEXT_URL=$URL"
} > "$ENV_FILE"

docker run --rm -it \
  --network home_ai_ai-egress \
  -v /home_ai/data/dext-profile:/profile \
  -e DISPLAY="${DISPLAY:-:0}" \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  --env-file "$ENV_FILE" \
  --shm-size 2g \
  mcr.microsoft.com/playwright/python:v1.45.0-jammy \
  python3 -c "
import os, time
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        '/profile',
        headless=False,
        viewport={'width': 1280, 'height': 900},
    )
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    page.goto(os.environ['DEXT_URL'], wait_until='domcontentloaded', timeout=20000)

    # Best-effort auto-fill — if Dext changes selectors this just falls through
    try:
        page.fill('input[type=email], input[name=email]', os.environ['DEXT_EMAIL'])
        page.fill('input[type=password], input[name=password]', os.environ['DEXT_PASSWORD'])
        # Don't auto-submit; let user click to handle 2FA etc.
    except Exception as e:
        print(f'(auto-fill skipped: {e})')

    print('Browser open. Complete login + 2FA manually. Close the window when done.')
    # Wait for browser close or 10 min timeout
    deadline = time.time() + 600
    while time.time() < deadline:
        try:
            _ = page.title()
        except Exception:
            break
        time.sleep(2)
    ctx.close()
    print('Session saved to /profile')
"

echo
echo "✓ Pairing complete. Try a one-shot export:"
echo "    /home_ai/scripts/u126-dext-export.sh"
