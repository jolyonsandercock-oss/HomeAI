#!/usr/bin/env bash
# set-xero-creds.sh — interactive helper to store Xero login credentials
# in Vault for u128 import pipeline.
#
# Xero requires email + password + 2FA on login. The pair script that
# follows handles 2FA interactively (Playwright window) — this just
# stashes the static credentials.
#
# Token NEVER echoed back. Re-runnable.

set -uo pipefail

for c in homeai-critical-listener homeai-n8n homeai-google-fetch; do
  VAULT_TOKEN=$(docker inspect "$c" --format='{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
                | grep '^VAULT_TOKEN=' | cut -d= -f2-)
  [ -n "$VAULT_TOKEN" ] && break
done
[ -z "$VAULT_TOKEN" ] && { echo "VAULT_TOKEN not found in any container"; exit 1; }
export VAULT_TOKEN

EXISTING=$(docker exec -e VAULT_TOKEN homeai-vault vault kv get -format=json secret/xero 2>/dev/null) || EXISTING=""
existing_email=""
existing_tenant_path=""
existing_bills_url=""
if [ -n "$EXISTING" ]; then
  existing_email=$(echo "$EXISTING"   | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data'].get('email',''))")
  existing_tenant_path=$(echo "$EXISTING" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data'].get('tenant_path',''))")
  existing_bills_url=$(echo "$EXISTING" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data'].get('bills_url',''))")
fi

cat <<EOF
── Xero credential setup ───────────────────────────────────────────────────

Stores your Xero login in Vault at secret/xero. Used by u128-xero-pair
(Playwright window for 2FA) and u128-xero-export (headless daily bills
download once paired).

Existing values:
  email:        ${existing_email:-(none)}
  tenant_path:  ${existing_tenant_path:-(none — derived from URL below)}
  bills_url:    ${existing_bills_url:-https://go.xero.com/app/!g--Nh/bills/list/all}

Press enter on any prompt to keep the existing value.

EOF

# Email
read -r -p "Xero EMAIL : " new_email
email="${new_email:-$existing_email}"
[ -z "$email" ] && { echo "❌ email required"; exit 1; }

# Password (hidden)
read -r -s -p "Xero PASSWORD (hidden — blank to keep existing) : " new_password
echo
if [ -z "$new_password" ] && [ -n "$EXISTING" ]; then
  password=$(echo "$EXISTING" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data'].get('password',''))")
  echo "(keeping existing password)"
else
  password="$new_password"
fi
[ -z "$password" ] && { echo "❌ password required"; exit 1; }

# Bills list URL — the one you pasted contains your tenant code
default_url="${existing_bills_url:-https://go.xero.com/app/!g--Nh/bills/list/all?deletedAndVoided=dontShow&searchWithin=anyDate&type=all&pageNumber=1}"
read -r -p "Xero BILLS LIST URL [default shown is the one you pasted]
  > $default_url
  > " new_url
bills_url="${new_url:-$default_url}"

# Extract tenant_path from URL (the !g--Nh segment between /app/ and /bills/)
tenant_path=$(python3 -c "
import re, sys
url = sys.argv[1]
m = re.search(r'/app/([!a-zA-Z0-9_-]+)/', url)
print(m.group(1) if m else '')
" "$bills_url")
if [ -z "$tenant_path" ]; then
  echo "⚠ Couldn't extract tenant code from URL. Continuing anyway."
fi

# Write to Vault via stdin so password never appears in argv
TMP=$(mktemp); chmod 600 "$TMP"
trap 'rm -f "$TMP"' EXIT
python3 -c "
import json, sys
print(json.dumps({
    'email':       '$email',
    'password':    sys.stdin.read().strip(),
    'bills_url':   '$bills_url',
    'tenant_path': '$tenant_path',
    'login_url':   'https://login.xero.com',
}))
" <<< "$password" > "$TMP"
docker cp "$TMP" homeai-vault:/tmp/xero-stash.json >/dev/null
docker exec -e VAULT_TOKEN homeai-vault sh -c '
  vault kv put secret/xero @/tmp/xero-stash.json >/dev/null && rm /tmp/xero-stash.json
' && echo "✓ stored in Vault at secret/xero"

cat <<EOF

── Next steps ──────────────────────────────────────────────────────────

  1. One-time pairing — opens Chromium so you can complete 2FA:
        /home_ai/scripts/u128-xero-pair.sh

     Xero sends a 6-digit code by SMS or authenticator app. Enter it
     in the Playwright window. Session cookies save to
     /home_ai/data/xero-profile and persist (typically ~30 days).

  2. After pairing, download bills (default last 100 days):
        /home_ai/scripts/u128-xero-export.sh
        # or for full 300d backfill:
        DAYS_BACK=300 /home_ai/scripts/u128-xero-export.sh

  3. Daily cron at 06:45 (after Dext's 06:30) — keeps Xero bills synced.

EOF
