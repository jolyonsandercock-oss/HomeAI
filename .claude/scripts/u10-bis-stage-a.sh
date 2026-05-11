#!/bin/bash
# U10-bis Stage A: restart homeai-google-fetch with the user's VAULT_TOKEN
# in env, then probe /poll-and-emit to validate the Python ingestion path.
# Reads VAULT_TOKEN from env. Aborts cleanly if anything's wrong.
set -uo pipefail

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "✗ VAULT_TOKEN not set. Run: export VAULT_TOKEN='<full-token>' first."
  exit 1
fi
if (( ${#VAULT_TOKEN} < 20 )); then
  echo "✗ Token looks truncated (${#VAULT_TOKEN} chars). Vault tokens are 24-95 chars."
  echo "  Re-export with single quotes: export VAULT_TOKEN='<paste-here>'"
  exit 1
fi

echo "── Verifying token can read secret/google/oauth-client ──"
if ! docker exec -e VAULT_TOKEN homeai-vault \
  vault kv get -format=json secret/google/oauth-client > /dev/null 2>&1; then
  echo "✗ Token can't read secret/google/oauth-client."
  echo "  Either the token expired, or it's bound to a policy without google/* read."
  exit 1
fi
echo "  ✓ token has read access"

echo
echo "── Pulling other env vars from running n8n container ──"
N8N_DB_PASSWORD=$(docker exec homeai-n8n sh -c 'echo $DB_POSTGRESDB_PASSWORD')
POSTGRES_PASSWORD=$(docker exec homeai-postgres sh -c 'echo $POSTGRES_PASSWORD')

echo "── Recreating google-fetch with VAULT_TOKEN ──"
N8N_DB_PASSWORD="$N8N_DB_PASSWORD" \
POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
VAULT_TOKEN="$VAULT_TOKEN" \
docker compose up -d --no-deps --force-recreate google-fetch 2>&1 | grep -E '(Started|Recreated)'

echo
echo "── Waiting for service to boot ──"
for i in 1 2 3 4 5 6 7 8; do
  sleep 3
  if docker exec homeai-build-dashboard python3 -c \
    "import urllib.request; urllib.request.urlopen('http://google-fetch:8011/healthz', timeout=5).read()" 2>/dev/null; then
    echo "  ✓ ready (after ${i}x3s)"; break
  fi
done

echo
echo "── Calling /poll-and-emit (blocks up to 5 min) ──"

# Write Python parser to tempfile to avoid bash quoting hell
PARSER=$(mktemp)
cat > "$PARSER" <<'PYEOF'
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception as e:
    print('FAIL: non-JSON response:')
    print(raw[:500])
    sys.exit(1)

total = d.get('total_inserted', 0)
print(f'Total events inserted: {total}')
print()
print('Per account:')
for r in d.get('results', []):
    if 'error' in r:
        print('  X ' + r.get('account', '?') + ': ' + r['error'][:100])
        continue
    acct = r.get('account', '?')
    email = r.get('email', '?')
    fetched = r.get('fetched', 0)
    inserted = r.get('inserted', 0)
    dup = r.get('skipped_duplicate', 0)
    errs = r.get('errors', 0)
    line = '  OK ' + acct.ljust(8) + ' (' + email.ljust(42) + ')'
    line += '  fetched=' + str(fetched).rjust(3)
    line += '  inserted=' + str(inserted).rjust(3)
    line += '  dup=' + str(dup).rjust(3)
    line += '  errors=' + str(errs)
    print(line)
PYEOF

# Issue the call from inside the dashboard container (ai-internal network)
docker exec homeai-build-dashboard python3 -c "
import urllib.request
req = urllib.request.Request('http://google-fetch:8011/poll-and-emit', method='POST', data=b'')
print(urllib.request.urlopen(req, timeout=300).read().decode())
" | python3 "$PARSER"

rm -f "$PARSER"
