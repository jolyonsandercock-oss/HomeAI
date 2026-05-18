#!/usr/bin/env bash
# u128-xero-pair.sh — interactive Xero login + 2FA via Playwright.
# Mirrors u126-dext-pair.sh — same native-host Chromium pattern.

set -euo pipefail

PROFILE_DIR=/home_ai/data/xero-profile
VENV=/home_ai/data/dext-venv   # reuse Playwright venv from U126
CHROME=/home_ai/data/playwright-browsers/chromium-1148/chrome-linux/chrome
mkdir -p "$PROFILE_DIR"

# Stale lock from a failed previous run
rm -f "$PROFILE_DIR/Singleton"* 2>/dev/null || true

[ -x "$VENV/bin/python" ] || { echo "venv missing at $VENV — run u126 dext setup first"; exit 1; }
[ -x "$CHROME" ]          || { echo "chromium missing at $CHROME"; exit 1; }
[ -z "${DISPLAY:-}" ]     && { echo "DISPLAY not set — run at console (export DISPLAY=:0)"; exit 1; }

VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
CREDS_JSON=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -format=json secret/xero 2>/dev/null) || {
  echo "❌ secret/xero not set. Run set-xero-creds.sh first."
  exit 1
}

# Network pre-flight
echo "── Waiting for login.xero.com to be reachable…"
for try in 1 2 3 4 5; do
  if curl -sI --max-time 8 https://login.xero.com/ -o /dev/null -w "%{http_code}" 2>&1 | grep -qE '^(200|301|302|303)$'; then
    echo "  reachable"; break
  fi
  sleep 5
  [ "$try" -eq 5 ] && { echo "❌ login.xero.com unreachable"; exit 1; }
done

ENV_FILE=$(mktemp); chmod 600 "$ENV_FILE"
RUNNER=$(mktemp --suffix=.py)
trap 'rm -f "$ENV_FILE" "$RUNNER"' EXIT

CREDS_JSON_FILE=$(mktemp); chmod 600 "$CREDS_JSON_FILE"
echo "$CREDS_JSON" > "$CREDS_JSON_FILE"
python3 - "$CREDS_JSON_FILE" <<'PYEOF' > "$ENV_FILE"
import json, sys, shlex
d = json.load(open(sys.argv[1]))['data']['data']
# shlex.quote each value — URLs + passwords routinely contain & ? ! # that
# bash would otherwise interpret when sourcing this file with `.`
print(f'XERO_EMAIL={shlex.quote(d["email"])}')
print(f'XERO_PASSWORD={shlex.quote(d["password"])}')
print(f'XERO_LOGIN_URL={shlex.quote(d.get("login_url","https://login.xero.com"))}')
print(f'XERO_BILLS_URL={shlex.quote(d["bills_url"])}')
PYEOF
rm -f "$CREDS_JSON_FILE"
printf 'CHROME_EXEC=%q\n'   "$CHROME"      >> "$ENV_FILE"
printf 'PROFILE_DIR=%q\n'   "$PROFILE_DIR" >> "$ENV_FILE"
echo "CHROME_EXEC=$CHROME"   >> "$ENV_FILE"
echo "PROFILE_DIR=$PROFILE_DIR" >> "$ENV_FILE"

cat > "$RUNNER" <<'PY'
import os, sys, time
from playwright.sync_api import sync_playwright

EMAIL    = os.environ['XERO_EMAIL']
PASSWORD = os.environ['XERO_PASSWORD']
LOGIN_URL  = os.environ['XERO_LOGIN_URL']
BILLS_URL = os.environ['XERO_BILLS_URL']
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

    for attempt in range(1, 5):
        try:
            page.goto(LOGIN_URL, wait_until='domcontentloaded', timeout=30000)
            break
        except Exception as e:
            print(f'goto attempt {attempt}/4: {e}')
            time.sleep(3)

    # Auto-fill. Xero currently uses a unified form (email + password on
    # one page). Older split-form layout has email first, then password
    # on a second page after Continue. Handle both.
    try:
        page.fill('input[type=email], input[name=Username], #xl-form-email',
                  EMAIL, timeout=8000)

        try:
            page.fill('input[type=password], input[name=Password], #xl-form-password',
                      PASSWORD, timeout=2500)
            print('  unified form — filled email + password')
        except Exception:
            print('  split form — pressing Continue, waiting for password page')
            page.click('button#xl-form-submit, button:has-text("Continue")',
                       timeout=4000)
            page.wait_for_timeout(2000)
            page.fill('input[type=password], input[name=Password], #xl-form-password',
                      PASSWORD, timeout=8000)

        page.wait_for_timeout(500)
        try:
            page.click('button#xl-form-submit, button:has-text("Log in")',
                       timeout=4000)
            print('  Log in clicked — complete 2FA in the window')
        except Exception as e:
            print(f'  could not click final Log in ({e}) — click it manually')
    except Exception as e:
        print(f'(auto-fill skipped — Xero login form changed: {e}) — fill manually')

    print('Browser is open. Click Log in + complete 2FA (SMS or auth app).')
    print('Waiting for redirect off login.xero.com (up to 15 min)…')
    deadline = time.time() + 900
    reached_post_login = False
    while time.time() < deadline:
        try:
            url = page.url
        except Exception:
            break
        if 'login.xero.com' not in url and ('go.xero.com' in url or 'my.xero.com' in url):
            print(f'  post-login URL detected: {url}')
            reached_post_login = True
            break
        time.sleep(2)

    if not reached_post_login:
        print('✗ Never saw a post-login URL. Did you complete 2FA?', file=sys.stderr)
        try: ctx.close()
        except Exception: pass
        sys.exit(2)

    # Force go.xero.com cookies to be set by navigating to the bills page.
    print(f'  navigating to bills URL to capture go.xero.com session cookies…')
    try:
        page.goto(BILLS_URL, wait_until='domcontentloaded', timeout=60000)
        page.wait_for_timeout(3000)
    except Exception as e:
        print(f'  (bills nav warning: {e})')

    cookies = ctx.cookies()
    go_cookies = [c for c in cookies if 'go.xero.com' in c.get('domain','')]
    print(f'  go.xero.com cookies captured: {len(go_cookies)}')
    for c in go_cookies[:6]:
        print(f'    {c["domain"]:25s} {c["name"]}')

    if not go_cookies:
        print('✗ No go.xero.com cookies — session not fully established.', file=sys.stderr)
        try: ctx.close()
        except Exception: pass
        sys.exit(3)

    try: ctx.close()
    except Exception: pass
    print(f'✓ Xero session saved to {PROFILE} ({len(go_cookies)} go.xero.com cookies)')
PY

cat <<EOF
── Starting Chromium for Xero login
   Email:    $(grep '^XERO_EMAIL=' "$ENV_FILE" | cut -d= -f2-)
   Profile:  $PROFILE_DIR

Browser opens with email pre-filled (and password if Xero uses single-form).
Click Log in → complete 2FA → close window when Xero dashboard loads.

EOF

set -a; . "$ENV_FILE"; set +a
set +e
"$VENV/bin/python" "$RUNNER"
rc=$?
set -e
echo
if [ $rc -eq 0 ]; then
  echo "Pairing done. Pull bills CSV now (session is hot):"
  echo "    DISPLAY=:0 XERO_HEADED=1 /home_ai/scripts/u128-xero-export.sh"
else
  echo "✗ Pairing failed (rc=$rc) — see messages above. Retry when ready."
  exit $rc
fi
