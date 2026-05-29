#!/bin/bash
# pair-local.sh — launch a Playwright auth-pairing run on the JolyBox
# local console (DISPLAY=:0). Chromium opens on the host's screen.
# Storage state is saved into /home_ai/data/playwright-state/.
#
# Usage:  ./pair-local.sh dojo
#         ./pair-local.sh trail

set -euo pipefail

SCRAPER=${1:?usage: pair-local.sh <dojo|trail>}

case "$SCRAPER" in
  dojo|trail) ;;
  *) echo "✗ unknown scraper: $SCRAPER (expected: dojo | trail)"; exit 2 ;;
esac

echo "→ pulling $SCRAPER creds from vault"
VT=$(docker inspect homeai-bot-responder \
       --format '{{range .Config.Env}}{{println .}}{{end}}' \
     | grep '^VAULT_TOKEN=' | cut -d= -f2-)

if [[ -z "$VT" ]]; then
  echo "✗ no VAULT_TOKEN in bot-responder env"
  exit 1
fi

USERNAME=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault \
             vault kv get -field=username "secret/$SCRAPER")
PASSWORD=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault \
             vault kv get -field=password "secret/$SCRAPER")

if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
  echo "✗ secret/$SCRAPER missing username or password"
  exit 1
fi

echo "  username: $USERNAME"

# Make sure local X11 access is granted for docker.
xhost +local:docker >/dev/null 2>&1 || true

echo "→ launching headed pairing — Chromium will appear on your screen"
docker exec -it -e DISPLAY=:0 homeai-playwright \
  python3 -m "scrapers.$SCRAPER" --pair \
  --username "$USERNAME" --password "$PASSWORD"

echo
echo "✓ done."
echo "  state file: /home_ai/data/playwright-state/${SCRAPER}-storage.json"
echo "  debug dumps (if any): /home_ai/storage/scraper-debug/${SCRAPER}-*"
