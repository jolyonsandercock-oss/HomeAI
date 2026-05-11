#!/bin/bash
# Probes all 5 Google identities (3 OAuth + 2 SA-impersonated)
# to confirm Stage A/B/C wiring works end-to-end.
#
# Reads VAULT_TOKEN from env. Prints PASS/FAIL per identity.
set -uo pipefail

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "✗ VAULT_TOKEN not set. Run: export VAULT_TOKEN='<token>'  first."
  exit 1
fi

PASS=0
FAIL=0

probe_consumer() {
  local LABEL=$1
  local EXPECTED_EMAIL=$2

  echo "── consumer: $LABEL ($EXPECTED_EMAIL) ──"
  local CID CSEC RTOK
  CID=$(docker exec -e VAULT_TOKEN homeai-vault vault kv get -field=oauth_client_id "secret/google/$LABEL" 2>&1)
  CSEC=$(docker exec -e VAULT_TOKEN homeai-vault vault kv get -field=oauth_client_secret "secret/google/$LABEL" 2>&1)
  RTOK=$(docker exec -e VAULT_TOKEN homeai-vault vault kv get -field=refresh_token "secret/google/$LABEL" 2>&1)

  if [[ -z "$CID" || -z "$CSEC" || -z "$RTOK" ]]; then
    echo "  ✗ FAIL: Vault read incomplete (cid=${#CID} csec=${#CSEC} rtok=${#RTOK})"
    FAIL=$((FAIL+1)); return
  fi

  # Refresh access token
  RESP=$(curl -sS -X POST https://oauth2.googleapis.com/token \
    -d "client_id=$CID" \
    -d "client_secret=$CSEC" \
    -d "refresh_token=$RTOK" \
    -d "grant_type=refresh_token")
  ATOK=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)

  if [[ -z "$ATOK" ]]; then
    echo "  ✗ FAIL: token refresh failed: $RESP"
    FAIL=$((FAIL+1)); return
  fi

  # Verify identity via Gmail /me
  PROFILE=$(curl -sS -H "Authorization: Bearer $ATOK" \
    "https://gmail.googleapis.com/gmail/v1/users/me/profile")
  ACTUAL=$(echo "$PROFILE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('emailAddress',''))" 2>/dev/null)
  TOTAL=$(echo "$PROFILE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('messagesTotal',0))" 2>/dev/null)

  if [[ "$(echo $ACTUAL | tr A-Z a-z)" == "$(echo $EXPECTED_EMAIL | tr A-Z a-z)" ]]; then
    echo "  ✓ PASS: $ACTUAL — $TOTAL total messages"
    PASS=$((PASS+1))
  else
    echo "  ✗ FAIL: expected $EXPECTED_EMAIL, got '$ACTUAL'"
    FAIL=$((FAIL+1))
  fi
}

probe_workspace() {
  local SUBJECT=$1
  echo "── workspace: $SUBJECT ──"

  RESULT=$(SA_JSON=$(docker exec -e VAULT_TOKEN homeai-vault vault kv get -field=json_key secret/google/sa-malthouse 2>&1) \
    docker run --rm --network home_ai_ai-egress \
      -e SA_JSON="$SA_JSON" -e TARGET_EMAIL="$SUBJECT" \
      python:3.11-slim sh -c '
        pip install --quiet google-auth google-auth-httplib2 google-api-python-client 2>/dev/null
        python3 << PY
import json, os, sys
from google.oauth2 import service_account
from googleapiclient.discovery import build
info = json.loads(os.environ["SA_JSON"])
creds = service_account.Credentials.from_service_account_info(
    info, scopes=["https://www.googleapis.com/auth/gmail.modify"], subject=os.environ["TARGET_EMAIL"]
)
g = build("gmail","v1",credentials=creds,cache_discovery=False)
p = g.users().getProfile(userId="me").execute()
print(p.get("emailAddress","") + "|" + str(p.get("messagesTotal",0)))
PY
' 2>&1)

  ACTUAL_EMAIL=$(echo "$RESULT" | tail -1 | cut -d'|' -f1)
  TOTAL=$(echo "$RESULT" | tail -1 | cut -d'|' -f2)

  if [[ "$ACTUAL_EMAIL" == "$SUBJECT" ]]; then
    echo "  ✓ PASS: $ACTUAL_EMAIL — $TOTAL total messages"
    PASS=$((PASS+1))
  else
    echo "  ✗ FAIL: $RESULT"
    FAIL=$((FAIL+1))
  fi
}

# ── 3 consumer accounts via OAuth refresh ──
probe_consumer jo      jolyon.sandercock@gmail.com
probe_consumer pounana pounana@gmail.com
probe_consumer bot     jolyboxbot@gmail.com

# ── 2 workspace accounts via SA impersonation ──
probe_workspace info@malthousetintagel.com
probe_workspace admin@malthousetintagel.com

echo
echo "── Summary ──"
echo "  PASS: $PASS / 5"
echo "  FAIL: $FAIL / 5"
exit $((FAIL > 0 ? 1 : 0))
