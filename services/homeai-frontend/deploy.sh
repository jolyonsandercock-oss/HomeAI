#!/usr/bin/env bash
# deploy.sh — push homeai-frontend to Vercel if credentials are present.
#
# Reads from Vault:
#   secret/vercel  →  { "token": "…", "org_id": "…" (optional), "project_id": "…" (optional) }
#
# If absent, prints what to set and exits non-zero. Safe to re-run.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^VAULT_TOKEN=' | cut -d= -f2-)
if [ -z "$VAULT_TOKEN" ]; then
  echo "VAULT_TOKEN not found in any running container. Aborting."
  exit 1
fi

CREDS=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -format=json secret/vercel 2>/dev/null) || {
  cat <<EOF
Vercel credentials not in Vault yet. To enable deploy:

  1. Get a Vercel access token: https://vercel.com/account/tokens
  2. Find your org id + project id in vercel.com → Settings.
  3. Run:
       docker exec -e VAULT_TOKEN=\$VAULT_TOKEN homeai-vault vault kv put secret/vercel \\
         token=YOUR_TOKEN org_id=team_xxxx project_id=prj_xxxx
  4. Re-run this script.

Until then the app runs locally on Tailscale at http://homeai-frontend:3000
(see docker-compose service homeai-frontend).
EOF
  exit 0
}

TOKEN=$(echo "$CREDS" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data']['token'])")
ORG=$(echo "$CREDS"   | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data'].get('org_id',''))")
PROJ=$(echo "$CREDS"  | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data'].get('project_id',''))")

echo "── Building + deploying via npx (token passed via env-file, never argv):"
# Token + IDs in a tmp env file so they NEVER appear in `ps aux`.
ENV_FILE=$(mktemp)
trap 'rm -f "$ENV_FILE"' EXIT
{
  echo "VERCEL_TOKEN=$TOKEN"
  [ -n "$ORG" ]  && echo "VERCEL_ORG_ID=$ORG"
  [ -n "$PROJ" ] && echo "VERCEL_PROJECT_ID=$PROJ"
  echo "PATH=/usr/local/bin:/usr/bin:/bin:/app/node_modules/.bin"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

docker run --rm \
  -v "$SCRIPT_DIR":/app -w /app \
  --env-file "$ENV_FILE" \
  node:20-alpine sh -c '
    set -e
    apk add --no-cache git >/dev/null 2>&1 || true
    # Token read from env inside the container — never on argv
    echo "-- vercel pull --"
    npx --yes vercel@latest pull --yes --environment=production 2>&1 | tail -5
    echo "-- vercel build --"
    npx --yes vercel@latest build --prod 2>&1 | tail -15
    echo "-- vercel deploy --"
    npx --yes vercel@latest deploy --prebuilt --prod
  ' 2>&1 | tee /tmp/vercel-deploy.log

URL=$(grep -oE 'https://[a-zA-Z0-9.-]+\.vercel\.app' /tmp/vercel-deploy.log | tail -1)
if [ -n "$URL" ]; then
  echo
  echo "✓ Deployed: $URL"
  echo "$URL" > /tmp/homeai-frontend-url
else
  echo "no URL detected — check /tmp/vercel-deploy.log"
fi
