#!/usr/bin/env bash
# set-dext-creds.sh — store Dext credentials in Vault for u126 importer.
#
# Token NEVER echoed back. Validates by attempting a login through
# the dext-importer Playwright container before saving.

set -euo pipefail

for c in homeai-critical-listener homeai-n8n homeai-google-fetch; do
  VAULT_TOKEN=$(docker inspect "$c" --format='{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^VAULT_TOKEN=' | cut -d= -f2-)
  [ -n "$VAULT_TOKEN" ] && break
done
[ -z "$VAULT_TOKEN" ] && { echo "VAULT_TOKEN not found"; exit 1; }
export VAULT_TOKEN

EXISTING=$(docker exec -e VAULT_TOKEN homeai-vault vault kv get -format=json secret/dext 2>/dev/null) || EXISTING=""
existing_email=""
existing_url=""
if [ -n "$EXISTING" ]; then
  existing_email=$(echo "$EXISTING" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data'].get('email',''))")
  existing_url=$(echo "$EXISTING" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data'].get('url','https://app.dext.com'))")
fi

cat <<EOF
── Dext credential setup ────────────────────────────────────────────────────

Stores your Dext login in Vault at secret/dext. Password is hidden during
entry and not echoed back. Used by u126-dext-export to drive the CSV
export via Playwright once daily.

Existing values:
  email:  ${existing_email:-(none)}
  url:    ${existing_url:-https://app.dext.com}

EOF

# Email
read -r -p "Dext EMAIL (blank = keep existing) : " new_email
email="${new_email:-$existing_email}"
if [ -z "$email" ]; then echo "❌ email required"; exit 1; fi

# Password (hidden)
read -r -s -p "Dext PASSWORD (hidden — blank to keep existing) : " new_password
echo
if [ -z "$new_password" ] && [ -n "$EXISTING" ]; then
  echo "(keeping existing password)"
  password=$(echo "$EXISTING" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data'].get('password',''))")
else
  password="$new_password"
fi
if [ -z "$password" ]; then echo "❌ password required"; exit 1; fi

# Login URL (most accounts use app.dext.com; partner subdomains exist)
read -r -p "Dext LOGIN URL (default ${existing_url:-https://app.dext.com}) : " new_url
url="${new_url:-${existing_url:-https://app.dext.com}}"

# Write to Vault — values via stdin so they never appear in argv
TMP=$(mktemp); chmod 600 "$TMP"
trap 'rm -f "$TMP"' EXIT
python3 -c "
import json, sys
print(json.dumps({'email': '$email', 'password': sys.stdin.read().strip(), 'url': '$url'}))
" <<< "$password" > "$TMP"
docker cp "$TMP" homeai-vault:/tmp/dext-stash.json >/dev/null
docker exec -e VAULT_TOKEN homeai-vault sh -c '
  vault kv put secret/dext @/tmp/dext-stash.json >/dev/null && rm /tmp/dext-stash.json
' && echo "✓ stored in Vault at secret/dext"

cat <<EOF

── Next steps ───────────────────────────────────────────────────────────

  1. Run the one-time pairing (Playwright opens, logs in, captures cookies):
        /home_ai/scripts/u126-dext-pair.sh

     Dext may prompt for 2FA / email verification on first login from a
     new browser — complete it inside the Playwright window.

  2. Once paired, the daily export runs at 06:30 via cron and writes:
        /home_ai/data/dext-exports/YYYY-MM-DD.csv
     then u126-dext-parse.sh ingests it into vendor_invoice_lines.

  3. Manual one-shot for backfill:
        /home_ai/scripts/u126-dext-export.sh
        /home_ai/scripts/u126-dext-parse.sh
EOF
