#!/usr/bin/env bash
# u126-dext-pair.sh — interactive Dext browser pairing.
#
# Runs Playwright NATIVELY on the Ubuntu host (no Docker, no VNC).
# Browser pops up on the local desktop. Once paired, the persistent
# profile at /home_ai/data/dext-profile is reused by headless cron runs.

set -euo pipefail

# Pre-flight: profile + Playwright + Chromium binary
PROFILE_DIR=/home_ai/data/dext-profile
mkdir -p "$PROFILE_DIR"

VENV=/home_ai/data/dext-venv
if [ ! -x "$VENV/bin/python" ]; then
  echo "❌ Playwright venv missing. Run:"
  echo "    python3 -m venv $VENV"
  echo "    $VENV/bin/pip install playwright"
  exit 1
fi

# Chromium binary harvested from the homeai-playwright Docker image
# (Ubuntu 26.04 is too new for `playwright install chromium` from PyPI)
CHROME=/home_ai/data/playwright-browsers/chromium-1148/chrome-linux/chrome
[ -x "$CHROME" ] || {
  echo "❌ Chromium not found at $CHROME"
  echo "   Copy it from the Docker image:"
  echo "     docker cp homeai-playwright:/ms-playwright /home_ai/data/playwright-browsers"
  exit 1
}

# Need DISPLAY for headed mode
if [ -z "${DISPLAY:-}" ]; then
  echo "❌ DISPLAY not set — are you at the console or VNC'd in?"
  echo "   If sitting at the box, try:  export DISPLAY=:0"
  exit 1
fi

# Pull creds (won't be echoed)
VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
CREDS_JSON=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -format=json secret/dext 2>/dev/null) || {
  echo "❌ secret/dext not set. Run /home_ai/scripts/oauth/set-dext-creds.sh first."
  exit 1
}

EMAIL=$(echo "$CREDS_JSON"  | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data']['email'])")
URL=$(echo "$CREDS_JSON"    | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data']['url'])")

echo "── Starting Chromium with Playwright (native)"
echo "   URL:   $URL"
echo "   Email: $EMAIL"
echo "   Profile: $PROFILE_DIR"
echo
echo "Browser window will open. Auto-fills the form; you click submit,"
echo "complete any 2FA, then close the window when the Dext dashboard loads."
echo

# Creds via stdin so they're not in argv
"$VENV/bin/python" - "$URL" "$EMAIL" "$CHROME" "$PROFILE_DIR" <<'PY' < <(echo "$CREDS_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data']['password'])")
import sys, time
from playwright.sync_api import sync_playwright

URL, EMAIL, CHROME_EXEC, PROFILE = sys.argv[1:5]
PASSWORD = sys.stdin.read().strip()

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        PROFILE,
        executable_path=CHROME_EXEC,
        headless=False,
        viewport={'width': 1280, 'height': 900},
        args=['--no-sandbox', '--disable-dev-shm-usage'],
    )
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    page.goto(URL, wait_until='domcontentloaded', timeout=30000)
    try:
        page.fill('input[type=email], input[name=email]', EMAIL, timeout=8000)
        page.fill('input[type=password], input[name=password]', PASSWORD, timeout=4000)
        print('[auto-fill] email+password filled. Click submit in the browser.')
    except Exception as e:
        print(f'(auto-fill skipped — Dext form changed? do it manually: {e})')

    print('Browser is open. Complete login + 2FA. Close the window when done.')
    deadline = time.time() + 900
    while time.time() < deadline:
        try: _ = page.title()
        except Exception: break
        time.sleep(2)
    try: ctx.close()
    except Exception: pass
    print('✓ Session saved to', PROFILE)
PY

echo
echo "Pairing done. Try a one-shot export:"
echo "    /home_ai/scripts/u126-dext-export.sh"
