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

# Find a live Vault token from ANY running container — google-fetch has
# been seen empty after recreate (compose substitutes ${VAULT_TOKEN} with
# blank if the shell env doesn't have it at that moment).
for c in homeai-critical-listener homeai-n8n homeai-google-fetch homeai-bot-responder; do
  VAULT_TOKEN=$(docker inspect "$c" --format='{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^VAULT_TOKEN=' | cut -d= -f2-)
  [ -n "$VAULT_TOKEN" ] && break
done
[ -z "$VAULT_TOKEN" ] && { echo "VAULT_TOKEN not found in any container env"; exit 1; }
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

  # Google deprecated OOB (urn:ietf:wg:oauth:2.0:oob) for new auth flows
  # in Oct 2022. Modern flow: loopback redirect to a local one-shot HTTP
  # server. Port 54321 is fixed so you only register one Authorized
  # Redirect URI in Google Cloud Console.
  PORT=54321
  REDIRECT="http://127.0.0.1:$PORT/oauth/callback"

  CLIENT_ID=$(vault_kv oauth-client | python3 -c "import json,sys;print(json.load(sys.stdin)['client_id'])")
  CLIENT_SECRET=$(vault_kv oauth-client | python3 -c "import json,sys;print(json.load(sys.stdin)['client_secret'])")
  CURRENT=$(vault_kv "$IDENTITY" 2>/dev/null || echo '{}')
  EMAIL=$(echo "$CURRENT" | python3 -c "import json,sys;print(json.load(sys.stdin).get('email_address','?'))")
  SCOPES="https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/spreadsheets https://www.googleapis.com/auth/documents"

  ENCODED_REDIRECT=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote('$REDIRECT', safe=''))")
  ENCODED_SCOPES=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote('$SCOPES'))")
  AUTH_URL="https://accounts.google.com/o/oauth2/v2/auth?client_id=${CLIENT_ID}&redirect_uri=${ENCODED_REDIRECT}&response_type=code&scope=${ENCODED_SCOPES}&access_type=offline&prompt=consent"

  cat <<EOF
PRE-FLIGHT — one-time setup per OAuth client:
  1. Open https://console.cloud.google.com/apis/credentials
  2. Click the OAuth 2.0 Client (the "Web application" one).
  3. Under "Authorized redirect URIs", add:
        $REDIRECT
  4. Save. (Skip if already added — only needs doing once per client.)

PRE-FLIGHT — local prerequisites:
  Port $PORT must be free. (If running on a remote host, port-forward
  it back to your laptop with:  ssh -L $PORT:127.0.0.1:$PORT <host>)

EOF

  read -r -p "All pre-flight steps done? Press enter to continue (Ctrl-C to abort) " _

  # Spawn one-shot HTTP server in background, capture code via tempfile
  CODE_FILE=$(mktemp)
  python3 - <<PY &
import http.server, socketserver, urllib.parse, sys, os
PORT = $PORT
CODE_FILE = "$CODE_FILE"
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        qs = urllib.parse.urlparse(self.path).query
        params = dict(urllib.parse.parse_qsl(qs))
        if 'code' in params:
            open(CODE_FILE, 'w').write(params['code'])
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b"<html><body style='font:18px sans-serif;padding:40px'>"
                             b"<h1>Authorised</h1><p>You can close this tab and return to the terminal.</p>"
                             b"</body></html>")
        elif 'error' in params:
            open(CODE_FILE, 'w').write('ERR:' + params.get('error',''))
            self.send_response(400)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(("<h1>Error</h1><pre>" + params.get('error','') + "</pre>").encode())
        else:
            self.send_response(404); self.end_headers()
with socketserver.TCPServer(("127.0.0.1", PORT), H) as s:
    s.timeout = 1
    for _ in range(300):  # ~5 min
        s.handle_request()
        if os.path.exists(CODE_FILE) and os.path.getsize(CODE_FILE) > 0:
            sys.exit(0)
PY
  SERVER_PID=$!

  cat <<EOF

Open this URL in a browser SIGNED IN AS: $EMAIL

   $AUTH_URL

Waiting for Google to redirect back (up to 5 minutes)…
EOF

  # Wait for the code file to fill
  for i in $(seq 1 300); do
    if [ -s "$CODE_FILE" ]; then break; fi
    sleep 1
  done
  kill "$SERVER_PID" 2>/dev/null || true

  CODE=$(cat "$CODE_FILE" 2>/dev/null || echo "")
  rm -f "$CODE_FILE"
  if [ -z "$CODE" ] || [[ "$CODE" == ERR:* ]]; then
    echo "❌ no code received (${CODE:-timeout}). Aborted."
    exit 1
  fi
  echo "✓ Received authorization code from Google."

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
