#!/usr/bin/env bash
# u126-dext-pair.sh — interactive Dext browser pairing (native host).

set -euo pipefail

PROFILE_DIR=/home_ai/data/dext-profile
VENV=/home_ai/data/dext-venv
CHROME=/home_ai/data/playwright-browsers/chromium-1148/chrome-linux/chrome
mkdir -p "$PROFILE_DIR"

[ -x "$VENV/bin/python" ] || { echo "venv missing at $VENV"; exit 1; }
[ -x "$CHROME" ]          || { echo "chromium missing at $CHROME"; exit 1; }
[ -z "${DISPLAY:-}" ]     && { echo "DISPLAY not set — try: export DISPLAY=:0"; exit 1; }

VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
CREDS_JSON=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -format=json secret/dext 2>/dev/null) || {
  echo "❌ secret/dext not set. Run set-dext-creds.sh first."
  exit 1
}

# Build env-file (mode 600) — password lives there, not in argv
ENV_FILE=$(mktemp); chmod 600 "$ENV_FILE"
RUNNER=$(mktemp --suffix=.py)
trap 'rm -f "$ENV_FILE" "$RUNNER"' EXIT

echo "$CREDS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)['data']['data']
print(f'DEXT_EMAIL={d[\"email\"]}')
print(f'DEXT_PASSWORD={d[\"password\"]}')
print(f'DEXT_URL={d[\"url\"]}')
" > "$ENV_FILE"
echo "CHROME_EXEC=$CHROME"     >> "$ENV_FILE"
echo "PROFILE_DIR=$PROFILE_DIR" >> "$ENV_FILE"

cat > "$RUNNER" <<'PY'
import os, time, sys
from playwright.sync_api import sync_playwright

URL      = os.environ['DEXT_URL']
EMAIL    = os.environ['DEXT_EMAIL']
PASSWORD = os.environ['DEXT_PASSWORD']
CHROME   = os.environ['CHROME_EXEC']
PROFILE  = os.environ['PROFILE_DIR']

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        PROFILE,
        executable_path=CHROME,
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
        print(f'(auto-fill skipped — fill manually if Dext form changed: {e})')
    print('Browser is open. Complete login + 2FA. Close the window when done.')
    deadline = time.time() + 900
    while time.time() < deadline:
        try: _ = page.title()
        except Exception: break
        time.sleep(2)
    try: ctx.close()
    except Exception: pass
    print(f'✓ Session saved to {PROFILE}')
PY

cat <<EOF
── Starting Chromium with Playwright (native)
   URL:     $(grep '^DEXT_URL='   "$ENV_FILE" | cut -d= -f2-)
   Email:   $(grep '^DEXT_EMAIL=' "$ENV_FILE" | cut -d= -f2-)
   Profile: $PROFILE_DIR

Browser window will open. Auto-fills the form; click submit,
complete any 2FA, then close the window when Dext dashboard loads.

EOF

# Source the env file into the child python's environment
set -a; . "$ENV_FILE"; set +a
"$VENV/bin/python" "$RUNNER"

echo
echo "Pairing done. Try a one-shot export:"
echo "    /home_ai/scripts/u126-dext-export.sh"
