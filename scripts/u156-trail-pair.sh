#!/usr/bin/env bash
# u156-trail-pair.sh — interactive Trail (Access aCloud OAuth) login via Playwright.
# Mirrors u128-xero-pair.sh pattern.

set -euo pipefail

PROFILE_DIR=/home_ai/data/trail-profile
VENV=/home_ai/data/dext-venv
CHROME=/home_ai/data/playwright-browsers/chromium-1148/chrome-linux/chrome
mkdir -p "$PROFILE_DIR"

rm -f "$PROFILE_DIR/Singleton"* 2>/dev/null || true

[ -x "$VENV/bin/python" ] || { echo "venv missing at $VENV — run u126 dext setup first"; exit 1; }
[ -x "$CHROME" ]          || { echo "chromium missing at $CHROME"; exit 1; }
[ -z "${DISPLAY:-}" ]     && { echo "DISPLAY not set — run at console (export DISPLAY=:0)"; exit 1; }

VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
CREDS_JSON=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -format=json secret/trail 2>/dev/null) || {
  echo "❌ secret/trail not set"
  exit 1
}

ENV_FILE=$(mktemp); chmod 600 "$ENV_FILE"
RUNNER=$(mktemp --suffix=.py)
trap 'rm -f "$ENV_FILE" "$RUNNER"' EXIT

python3 -c "
import json, sys, shlex
d = json.loads('''$CREDS_JSON''')['data']['data']
print(f'TRAIL_USER={shlex.quote(d[\"username\"])}')
print(f'TRAIL_PW={shlex.quote(d[\"password\"])}')
print(f'TRAIL_WEB={shlex.quote(d.get(\"web_url\",\"https://web.trailapp.com\"))}')
print(f'TRAIL_LOGIN={shlex.quote(d.get(\"login_url\",\"https://identity.accessacloud.com/auth/password\"))}')
" > "$ENV_FILE"
printf 'CHROME_EXEC=%q\n'   "$CHROME"      >> "$ENV_FILE"
printf 'PROFILE_DIR=%q\n'   "$PROFILE_DIR" >> "$ENV_FILE"

cat > "$RUNNER" <<'PY'
import os, sys, time
from playwright.sync_api import sync_playwright

USER  = os.environ['TRAIL_USER']
PW    = os.environ['TRAIL_PW']
WEB   = os.environ['TRAIL_WEB']
LOGIN = os.environ['TRAIL_LOGIN']
CHROME  = os.environ['CHROME_EXEC']
PROFILE = os.environ['PROFILE_DIR']

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        PROFILE,
        executable_path=CHROME,
        headless=False,
        viewport={'width': 1280, 'height': 900},
        args=['--no-sandbox', '--disable-dev-shm-usage'],
    )
    page = ctx.pages[0] if ctx.pages else ctx.new_page()

    # Go to the Trail web app — it'll redirect through Access aCloud OAuth
    try:
        page.goto(WEB, wait_until='domcontentloaded', timeout=30000)
    except Exception as e:
        print(f'goto warning: {e}')

    # Try auto-fill on Access aCloud login form
    try:
        page.wait_for_selector('input[type=email], input[name=username], input[name=Username]', timeout=10000)
        page.fill('input[type=email], input[name=username], input[name=Username]', USER, timeout=5000)
        for sel in ['button[type=submit]', 'button:has-text("Continue")', 'button:has-text("Next")', 'button:has-text("Log in")']:
            try: page.click(sel, timeout=2000); break
            except Exception: continue
        page.wait_for_timeout(2000)
        page.fill('input[type=password], input[name=password], input[name=Password]', PW, timeout=8000)
        page.wait_for_timeout(500)
        for sel in ['button[type=submit]', 'button:has-text("Log in")', 'button:has-text("Sign in")']:
            try: page.click(sel, timeout=2000); break
            except Exception: continue
        print('  auto-fill complete — complete any 2FA in the window')
    except Exception as e:
        print(f'  (auto-fill skipped: {e}) — fill manually')

    print('Waiting for redirect to web.trailapp.com (up to 15 min)…')
    deadline = time.time() + 900
    reached = False
    while time.time() < deadline:
        try:
            url = page.url
        except Exception:
            break
        if 'web.trailapp.com' in url and 'auth' not in url:
            print(f'  post-login URL: {url}')
            reached = True
            break
        time.sleep(2)

    if not reached:
        print('✗ Never reached web.trailapp.com — did you complete login?', file=sys.stderr)
        try: ctx.close()
        except Exception: pass
        sys.exit(2)

    page.wait_for_timeout(3000)
    cookies = ctx.cookies()
    trail_cookies = [c for c in cookies if 'trailapp.com' in c.get('domain','')]
    print(f'  web.trailapp.com cookies captured: {len(trail_cookies)}')
    for c in trail_cookies[:6]:
        print(f'    {c["domain"]:25s} {c["name"]}')

    if not trail_cookies:
        print('✗ No web.trailapp.com cookies', file=sys.stderr)
        try: ctx.close()
        except Exception: pass
        sys.exit(3)

    try: ctx.close()
    except Exception: pass
    print(f'✓ Trail session saved to {PROFILE} ({len(trail_cookies)} cookies)')
PY

cat <<EOF
── Starting Chromium for Trail login
   User:    $(grep '^TRAIL_USER=' "$ENV_FILE" | cut -d= -f2- | tr -d "'")
   Profile: $PROFILE_DIR

Browser opens with email pre-filled. Complete login + any 2FA → wait for the Trail
web app to load → script auto-detects success and closes.

EOF

set -a; . "$ENV_FILE"; set +a
set +e
"$VENV/bin/python" "$RUNNER"
rc=$?
set -e

if [ $rc -eq 0 ]; then
  echo "Pairing done. Next step:"
  echo "    /home_ai/scripts/u156-trail-scrape.sh   # populates trail_reports"
else
  echo "✗ Pairing failed (rc=$rc)"
  exit $rc
fi
