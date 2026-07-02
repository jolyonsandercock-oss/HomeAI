#!/bin/bash
# /home_ai/scripts/u51-companies-house-creds.sh
#
# Prompts Jo for a Companies House Public Data API key, validates it
# against a known company (00000006 = THE SCOTTISH WIDOWS' FUND — a
# stable historical record), stashes to Vault under secret/companies-house.
#
# Sign-up flow Jo needs to complete first:
#   1. https://developer.company-information.service.gov.uk/
#   2. Sign in (Government Gateway or new account)
#   3. "Applications" → "Create an application"
#   4. Application type = "Live"
#   5. Copy the API key shown

set -euo pipefail

echo "── Companies House Public Data API key intake ──"
echo "If you don't have an app yet:"
echo "  https://developer.company-information.service.gov.uk/ → Applications → Create"
echo
read -r -p "API key: " API_KEY
if [[ -z "$API_KEY" ]]; then echo "Aborted (no key entered)."; exit 1; fi

echo
echo "Testing key against /company/00000006 …"
HTTP=$(curl -s -o /tmp/ch_test.json -w "%{http_code}" \
  -u "${API_KEY}:" "https://api.company-information.service.gov.uk/company/00000006" || echo "000")
if [[ "$HTTP" != "200" ]]; then
  echo "  ✗ HTTP $HTTP — key rejected. Response:"
  cat /tmp/ch_test.json | head -c 400; echo
  exit 2
fi
NAME=$(python3 -c "import json; print(json.load(open('/tmp/ch_test.json')).get('company_name',''))")
echo "  ✓ key accepted ($NAME)"

VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

echo "Stashing to Vault secret/companies-house …"
docker exec -i -e VT="$VAULT_TOKEN" -e KEY="$API_KEY" homeai-playwright python <<'PYEOF'
import os, json, urllib.request
body = json.dumps({"data": {"api_key": os.environ["KEY"]}}).encode()
req = urllib.request.Request("http://vault:8200/v1/secret/data/companies-house",
    data=body, method="POST",
    headers={"X-Vault-Token": os.environ["VT"], "Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=5).read()
print("  ✓ stashed")
PYEOF

rm -f /tmp/ch_test.json
echo
echo "Done. Test from any container:"
echo '  curl -u "$(vault kv get -field=api_key secret/companies-house):" \\'
echo '       https://api.company-information.service.gov.uk/company/<number>'
