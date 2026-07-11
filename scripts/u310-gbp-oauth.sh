#!/usr/bin/env bash
# u310-gbp-oauth.sh — get a refresh token bound to the CORRECT OAuth client,
# without the OAuth Playground (which keeps issuing tokens for the wrong client).
#
# Uses the client_id/client_secret ALREADY stored + validated in Vault
# secret/gbp. You only click a link, approve as admin@, and paste back the code.
set -euo pipefail

REDIRECT="http://localhost"
SCOPE="https://www.googleapis.com/auth/business.manage"

VAULT_TOKEN=$(docker inspect homeai-google-fetch \
  --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

# Step 1 — build the consent URL from the validated client_id in Vault.
URL=$(docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e REDIRECT="$REDIRECT" -e SCOPE="$SCOPE" \
  homeai-google-fetch python3 - <<'PY'
import os, json, urllib.request, urllib.parse
VT=os.environ["VAULT_TOKEN"]
c=json.loads(urllib.request.urlopen(urllib.request.Request(
    "http://vault:8200/v1/secret/data/gbp", headers={"X-Vault-Token":VT}), timeout=10).read())["data"]["data"]
q=urllib.parse.urlencode({
    "client_id": c["client_id"], "redirect_uri": os.environ["REDIRECT"],
    "response_type": "code", "scope": os.environ["SCOPE"],
    "access_type": "offline", "prompt": "consent"})
print("https://accounts.google.com/o/oauth2/v2/auth?"+q)
PY
)

echo
echo "STEP 1 — open this URL in the browser where you are signed in as admin@malthousetintagel.com:"
echo
echo "$URL"
echo
echo "STEP 2 — approve access. Your browser will then try to load a 'localhost'"
echo "page and show \"This site can't be reached\" — THAT IS EXPECTED."
echo "Look at the address bar. Copy the value after 'code=' (up to the next '&')."
echo "  e.g.  http://localhost/?code=4/0AXXXXXXXX&scope=...  -> copy 4/0AXXXXXXXX"
echo
read -rp "STEP 3 — paste the code here: " CODE
[[ -z "$CODE" ]] && { echo "no code entered — aborted."; exit 1; }

# Step 4 — exchange the code for a refresh token, store it, and sync.
docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e CODE="$CODE" -e REDIRECT="$REDIRECT" \
  homeai-google-fetch python3 - <<'PY'
import os, json, urllib.request, urllib.parse, urllib.error
VT=os.environ["VAULT_TOKEN"]
def vault_get(p):
    return json.loads(urllib.request.urlopen(urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{p}", headers={"X-Vault-Token":VT}), timeout=10).read())["data"]["data"]
def vault_put(p, d):
    urllib.request.urlopen(urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{p}", data=json.dumps({"data":d}).encode(),
        headers={"X-Vault-Token":VT,"Content-Type":"application/json"}, method="POST"), timeout=10)
c=vault_get("gbp")
code=urllib.parse.unquote(os.environ["CODE"].strip())
body=urllib.parse.urlencode({
    "code": code, "client_id": c["client_id"], "client_secret": c["client_secret"],
    "redirect_uri": os.environ["REDIRECT"], "grant_type": "authorization_code"}).encode()
try:
    r=json.loads(urllib.request.urlopen(urllib.request.Request(
        "https://oauth2.googleapis.com/token", data=body, method="POST"), timeout=30).read())
except urllib.error.HTTPError as e:
    print("EXCHANGE FAILED:", e.code, e.read().decode()[:300]); raise SystemExit(1)
rt=r.get("refresh_token")
if not rt:
    print("No refresh_token returned (Google only issues one on fresh consent). "
          "Re-run and make sure you approve the consent screen fully."); raise SystemExit(1)
vault_put("gbp", {**{k:c[k] for k in ("client_id","client_secret")}, "refresh_token": rt})
print("refresh_token stored. verifying...")
vbody=urllib.parse.urlencode({"client_id":c["client_id"],"client_secret":c["client_secret"],
    "refresh_token":rt,"grant_type":"refresh_token"}).encode()
urllib.request.urlopen(urllib.request.Request("https://oauth2.googleapis.com/token",data=vbody,method="POST"),timeout=30)
print("token refresh OK - credentials are now valid.")
PY

echo
echo "STEP 5 — pulling your reviews now:"
bash /home_ai/scripts/u310-gbp-reviews.sh
