#!/bin/bash
# redo-google-oauth.sh — diagnose + rotate Google OAuth refresh tokens
#
# Why this exists: OAuth refresh tokens for Google apps in "Testing" status
# expire after 7 days. Apps in "Production" status need verification for
# sensitive scopes (gmail.modify is sensitive). Either way, refresh tokens
# are fragile. THE ROBUST FIX is to migrate every identity to the service
# account + Domain-Wide Delegation (we already have sa-malthouse). This
# script supports both paths.
#
# Usage:
#   ./redo-google-oauth.sh diagnose                  # print state of each identity
#   ./redo-google-oauth.sh rotate <identity>         # interactive OAuth re-auth
#   ./redo-google-oauth.sh migrate-to-dwd <identity> # convert identity to use sa-malthouse
#
# Prereqs:
#   - GCP project: see Google Cloud Console → APIs & Services → Credentials
#   - OAuth client id/secret are already in Vault at secret/google/oauth-client
#   - Service account JSON is in Vault at secret/google/sa-malthouse
#   - DWD must be authorised in Google Workspace Admin → Security → API controls

set -uo pipefail
ACTION="${1:-diagnose}"
IDENTITY="${2:-}"

VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
[ -z "$VAULT_TOKEN" ] && { echo "VAULT_TOKEN not found"; exit 1; }
export VAULT_TOKEN

vault_kv() {
  docker exec -e VAULT_TOKEN homeai-vault vault kv get -format=json "secret/google/$1" 2>/dev/null | \
    python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['data']['data']))"
}

vault_put() {
  local p="$1"; shift
  docker exec -i -e VAULT_TOKEN homeai-vault vault kv put -format=json "secret/google/$p" "$@" >/dev/null
}

case "$ACTION" in
diagnose)
  echo "── Auth state for each google identity ──"
  for id in jo bot pounana admin info; do
    creds=$(vault_kv "$id" 2>/dev/null || echo '{}')
    if [ "$creds" = "{}" ] || [ -z "$creds" ]; then
      printf "  %-10s  %s\n" "$id" "NOT IN VAULT"
      continue
    fi
    # Check what auth model
    has_refresh=$(echo "$creds" | python3 -c "import json,sys;d=json.load(sys.stdin);print('y' if d.get('refresh_token') else 'n')")
    has_sa=$(echo "$creds" | python3 -c "import json,sys;d=json.load(sys.stdin);print('y' if d.get('impersonate_via') or d.get('auth') == 'service_account' else 'n')")
    email=$(echo "$creds" | python3 -c "import json,sys;print(json.load(sys.stdin).get('email_address','?'))")
    if [ "$has_refresh" = "y" ]; then
      # Try refresh
      result=$(docker exec -e VAULT_TOKEN homeai-google-fetch python3 -c "
import json, httpx, urllib.request, os
c = json.loads(urllib.request.urlopen(urllib.request.Request(
    'http://vault:8200/v1/secret/data/google/$id',
    headers={'X-Vault-Token': os.environ['VAULT_TOKEN']})).read())['data']['data']
r = httpx.post('https://oauth2.googleapis.com/token', data={
    'client_id': c['oauth_client_id'], 'client_secret': c['oauth_client_secret'],
    'refresh_token': c['refresh_token'], 'grant_type': 'refresh_token'}, timeout=10)
if r.status_code == 200:
    print('OK')
else:
    print('FAIL: ' + (json.loads(r.text).get('error_description', r.text[:80])))
" 2>&1 | tail -1)
      printf "  %-10s  %-30s  OAuth  %s\n" "$id" "$email" "$result"
    elif [ "$has_sa" = "y" ]; then
      printf "  %-10s  %-30s  SvcAcc DWD\n" "$id" "$email"
    else
      printf "  %-10s  %-30s  UNKNOWN auth model\n" "$id" "$email"
    fi
  done
  echo
  echo "── Recommendation ──"
  echo "  Any 'FAIL' rows: re-auth with"
  echo "    $0 rotate <identity>"
  echo "  OR (preferred — survives Google's 7-day testing-app expiry):"
  echo "    $0 migrate-to-dwd <identity>"
  ;;

rotate)
  [ -z "$IDENTITY" ] && { echo "Usage: $0 rotate <identity>"; exit 1; }
  echo "── Rotating OAuth refresh token for: $IDENTITY ──"
  echo
  CLIENT_ID=$(vault_kv oauth-client | python3 -c "import json,sys;print(json.load(sys.stdin)['client_id'])")
  CLIENT_SECRET=$(vault_kv oauth-client | python3 -c "import json,sys;print(json.load(sys.stdin)['client_secret'])")
  CURRENT=$(vault_kv "$IDENTITY" 2>/dev/null || echo '{}')
  EMAIL=$(echo "$CURRENT" | python3 -c "import json,sys;print(json.load(sys.stdin).get('email_address','?'))")
  SCOPES="https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/spreadsheets https://www.googleapis.com/auth/documents"
  REDIRECT="urn:ietf:wg:oauth:2.0:oob"

  AUTH_URL="https://accounts.google.com/o/oauth2/v2/auth?client_id=${CLIENT_ID}&redirect_uri=${REDIRECT}&response_type=code&scope=$(python3 -c "import urllib.parse;print(urllib.parse.quote('$SCOPES'))")&access_type=offline&prompt=consent"

  echo "1. Open this URL in a browser SIGNED IN AS: $EMAIL"
  echo
  echo "   $AUTH_URL"
  echo
  echo "2. Grant the permissions."
  echo "3. Google will display a one-time code. Paste it below."
  echo
  read -r -p "Code: " CODE
  [ -z "$CODE" ] && { echo "No code provided, aborting"; exit 1; }

  TOKEN_JSON=$(docker exec -e VAULT_TOKEN homeai-google-fetch python3 -c "
import httpx
r = httpx.post('https://oauth2.googleapis.com/token', data={
    'client_id': '$CLIENT_ID', 'client_secret': '$CLIENT_SECRET',
    'code': '$CODE', 'redirect_uri': '$REDIRECT', 'grant_type': 'authorization_code'
}, timeout=15)
import json
print(json.dumps(r.json()))
")
  NEW_REFRESH=$(echo "$TOKEN_JSON" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('refresh_token',''))")
  if [ -z "$NEW_REFRESH" ]; then
    echo "FAILED — no refresh token returned. Response:"
    echo "$TOKEN_JSON"
    exit 1
  fi

  # Write back with all existing fields preserved
  echo "$CURRENT" | python3 -c "
import json, sys, subprocess, os
d = json.load(sys.stdin)
d['refresh_token'] = '$NEW_REFRESH'
print(json.dumps(d))
" > /tmp/google-$IDENTITY-creds.json
  docker cp /tmp/google-$IDENTITY-creds.json homeai-vault:/tmp/
  docker exec -e VAULT_TOKEN homeai-vault sh -c "vault kv put secret/google/$IDENTITY @/tmp/google-$IDENTITY-creds.json && rm /tmp/google-$IDENTITY-creds.json"
  rm /tmp/google-$IDENTITY-creds.json
  echo "✓ Updated refresh token for $IDENTITY in Vault. Restart google-fetch to clear cache:"
  echo "    docker restart homeai-google-fetch"
  ;;

migrate-to-dwd)
  [ -z "$IDENTITY" ] && { echo "Usage: $0 migrate-to-dwd <identity>"; exit 1; }
  echo "── Migrating $IDENTITY from OAuth to Service Account + DWD ──"
  CURRENT=$(vault_kv "$IDENTITY")
  EMAIL=$(echo "$CURRENT" | python3 -c "import json,sys;print(json.load(sys.stdin)['email_address'])")
  echo "  email_address: $EMAIL"
  echo
  echo "PRE-FLIGHT CHECKLIST — DWD must be authorised for sa-malthouse:"
  echo "  1. Google Workspace Admin → Security → Access and data control → API controls"
  echo "  2. Domain-wide delegation → Add new"
  echo "  3. Client ID: (paste service account's unique ID from sa-malthouse json_key)"
  echo "  4. OAuth Scopes: gmail.modify, calendar, drive, spreadsheets, documents"
  echo
  read -r -p "Confirmed DWD is set up for $EMAIL? (yes/no) " CONFIRM
  [ "$CONFIRM" != "yes" ] && { echo "Aborted"; exit 1; }

  # Replace auth model in Vault
  echo "$CURRENT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
# Drop OAuth-specific fields, add SA marker
d.pop('oauth_client_id', None)
d.pop('oauth_client_secret', None)
d.pop('refresh_token', None)
d['auth'] = 'service_account'
d['impersonate_via'] = 'sa-malthouse'
print(json.dumps(d))
" > /tmp/google-$IDENTITY-dwd.json
  docker cp /tmp/google-$IDENTITY-dwd.json homeai-vault:/tmp/
  docker exec -e VAULT_TOKEN homeai-vault sh -c "vault kv put secret/google/$IDENTITY @/tmp/google-$IDENTITY-dwd.json && rm /tmp/google-$IDENTITY-dwd.json"
  rm /tmp/google-$IDENTITY-dwd.json
  echo
  echo "✓ $IDENTITY now uses service account impersonation. Restart google-fetch:"
  echo "    docker restart homeai-google-fetch"
  echo "  google-fetch's find_account() needs to dispatch on the 'auth' field —"
  echo "  if it falls back to OAuth code path, the next call will 502. Verify:"
  echo "    curl -s http://localhost:8011/healthz && \\"
  echo "    grep -n 'auth.*service_account\\|impersonate_via' /home_ai/services/google-fetch/main.py"
  ;;

*)
  echo "Unknown action: $ACTION"
  echo "Usage: $0 {diagnose|rotate <identity>|migrate-to-dwd <identity>}"
  exit 1
  ;;
esac
