#!/usr/bin/env bash
# hermes-rotate-deepseek-key.sh — rotate the DeepSeek API key in Hermes' auth.json.
#
# Why a script (not hand-editing): the key lives in THREE places in
# ~/.hermes/auth.json —
#   1) .providers.deepseek.api_key
#   2) .credential_pool.deepseek[].access_token   (one per pool entry; currently 2)
# Editing by hand reliably misses one, leaving a stale key live. This updates
# all of them atomically, NEVER echoes the key, backs up first, and validates.
#
# Usage:  ./hermes-rotate-deepseek-key.sh
# The new key is read from a hidden prompt, or from $DEEPSEEK_NEW_KEY if you
# prefer to pipe it from Vault. It is never written anywhere except auth.json
# and never printed.
set -euo pipefail

AUTH_JSON="${HERMES_AUTH:-$HOME/.hermes/auth.json}"

command -v jq >/dev/null || { echo "ERROR: jq is required (apt-get install jq)"; exit 1; }
[[ -f "$AUTH_JSON" ]] || { echo "ERROR: $AUTH_JSON not found (set HERMES_AUTH if it lives elsewhere)"; exit 1; }
jq empty "$AUTH_JSON" 2>/dev/null || { echo "ERROR: $AUTH_JSON is not valid JSON; aborting before touching it"; exit 1; }

# 1. Get the new key without echoing it to the terminal or shell history.
NEW_KEY="${DEEPSEEK_NEW_KEY:-}"
if [[ -z "$NEW_KEY" ]]; then
  read -rsp "Paste new DeepSeek API key (input hidden): " NEW_KEY
  echo
fi
[[ -n "$NEW_KEY" ]]        || { echo "ERROR: empty key; aborting"; exit 1; }
[[ "$NEW_KEY" == sk-* ]]   || { echo "ERROR: DeepSeek keys start with 'sk-'; that doesn't — aborting"; exit 1; }

# 2. Back up first. The backup holds the OLD key, so lock it down.
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BACKUP="${AUTH_JSON}.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$AUTH_JSON" "$BACKUP"
chmod 600 "$BACKUP"
echo "Backed up -> $BACKUP  (contains the OLD key; 'shred -u' it once you're satisfied)"

# 3. Count the slots we expect to change, so we can assert afterwards.
BEFORE=$(jq '[ (.providers.deepseek.api_key // empty),
               (.credential_pool.deepseek[]?.access_token // empty) ] | length' "$AUTH_JSON")
[[ "$BEFORE" -ge 1 ]] || { echo "ERROR: found no DeepSeek key slots in auth.json; nothing to do"; exit 1; }
echo "Found $BEFORE DeepSeek key slot(s) to update."

# 4. Rewrite atomically: every deepseek provider key + every deepseek pool token.
TMP="$(mktemp "${AUTH_JSON}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
jq --arg k "$NEW_KEY" --arg ts "$NOW" '
    (.providers.deepseek.api_key)   |= (if . then $k else . end)
  | (.credential_pool.deepseek)     |= (if . then [ .[] | .access_token = $k ] else . end)
  | .updated_at = $ts
' "$AUTH_JSON" > "$TMP"

# 5. Validate BEFORE swapping: must still parse, and exactly BEFORE slots hold the new key.
jq empty "$TMP" || { echo "ERROR: rewrite produced invalid JSON; original left untouched"; exit 1; }
AFTER=$(jq --arg k "$NEW_KEY" '[ (.providers.deepseek.api_key // empty),
             (.credential_pool.deepseek[]?.access_token // empty) ]
           | map(select(. == $k)) | length' "$TMP")
[[ "$AFTER" == "$BEFORE" ]] || { echo "ERROR: expected $BEFORE slots updated, got $AFTER; aborting"; exit 1; }
chmod 600 "$TMP"
mv "$TMP" "$AUTH_JSON"
trap - EXIT
echo "Updated $AFTER DeepSeek key slot(s) in $AUTH_JSON."

# 6. Optional live check against DeepSeek (never prints the key).
if command -v curl >/dev/null; then
  printf 'Verifying key against api.deepseek.com ... '
  CODE=$(curl -s -o /dev/null -w '%{http_code}' \
           -H "Authorization: Bearer ${NEW_KEY}" \
           https://api.deepseek.com/v1/models || echo "000")
  case "$CODE" in
    200)      echo "OK (200)";;
    401|403)  echo "REJECTED ($CODE) — DeepSeek did not accept this key. It is now written to auth.json anyway; re-run with the correct key."; exit 1;;
    *)        echo "inconclusive (HTTP $CODE — connectivity?). Key written regardless.";;
  esac
fi

unset NEW_KEY DEEPSEEK_NEW_KEY
cat <<'EOF'

Done. The gateway reads auth.json only at process start, so restart it to pick
up the new key:

    hermes gateway restart        # or however your Hermes gateway is run

EOF
