#!/usr/bin/env bash
# u310-gbp-setup.sh — one-shot: store Google Business Profile creds in Vault,
# then run the first reviews sync. Run this yourself (Jo) so the secret values
# never pass through chat or git.
#
# Usage:
#   bash /home_ai/scripts/u310-gbp-setup.sh
# It will prompt for the three values from the setup walkthrough
# (docs/setup/gbp-reviews-setup.md). Secret inputs are hidden as you type.
#
# Re-runnable: run it again any time to rotate the credential + re-sync.
set -euo pipefail

echo "== Google Business Profile — credential setup =="
echo "Paste the three values from the OAuth setup (input is hidden):"
read -rp   "  Client ID:      " GBP_CLIENT_ID
read -rsp  "  Client secret:  " GBP_CLIENT_SECRET; echo
read -rsp  "  Refresh token:  " GBP_REFRESH_TOKEN; echo

if [[ -z "$GBP_CLIENT_ID" || -z "$GBP_CLIENT_SECRET" || -z "$GBP_REFRESH_TOKEN" ]]; then
  echo "All three values are required — nothing written." >&2
  exit 1
fi

VAULT_TOKEN=$(docker inspect homeai-google-fetch \
  --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

echo "→ Writing secret/gbp to Vault…"
docker exec -i \
  -e VAULT_TOKEN="$VAULT_TOKEN" \
  -e GBP_CLIENT_ID="$GBP_CLIENT_ID" \
  -e GBP_CLIENT_SECRET="$GBP_CLIENT_SECRET" \
  -e GBP_REFRESH_TOKEN="$GBP_REFRESH_TOKEN" \
  homeai-google-fetch python3 - <<'PY'
import os, json, urllib.request
VT = os.environ["VAULT_TOKEN"]
data = {"client_id": os.environ["GBP_CLIENT_ID"],
        "client_secret": os.environ["GBP_CLIENT_SECRET"],
        "refresh_token": os.environ["GBP_REFRESH_TOKEN"]}
req = urllib.request.Request(
    "http://vault:8200/v1/secret/data/gbp",
    data=json.dumps({"data": data}).encode(),
    headers={"X-Vault-Token": VT, "Content-Type": "application/json"}, method="POST")
urllib.request.urlopen(req, timeout=10)
print("   secret/gbp written.")
PY

echo "→ Running the first Google reviews sync…"
bash /home_ai/scripts/u310-gbp-reviews.sh
echo
echo "== Done. From here it runs automatically; the reviews appear on the"
echo "   reviews dashboard (source=google). Tell Claude it's set up and the"
echo "   daily 07:00 cron gets wired in. =="
