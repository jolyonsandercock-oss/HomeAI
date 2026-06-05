#!/usr/bin/env bash
# install-n8n-vault-token.sh — write the token in security/.n8n-vault-token into
# n8n's `vault-token-header` credential WITHOUT the n8n UI, by matching n8n's
# CryptoJS-compatible AES encryption, then restart n8n so the Gmail-ingest +
# invoice pipelines pick up a working Vault token. Idempotent + reversible
# (the old encrypted blob is backed up to backups/ before the write).
#
# Run:  bash /home_ai/scripts/install-n8n-vault-token.sh
set -euo pipefail
umask 077

readonly TOKEN_FILE="/home_ai/security/.n8n-vault-token"
readonly CRED_ID="0wPA4DCDuehPC9Mf"
readonly N8N="homeai-n8n"
readonly PG="homeai-postgres"
readonly VAULT="homeai-vault"
pg() { docker exec -i "$PG" psql -U postgres -d homeai -tA "$@"; }
err() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
ok()  { printf '\033[32m✓\033[0m %s\n' "$*"; }
cleanup() { unset TOK KEY JSON BLOB BACK; }
trap cleanup EXIT INT TERM

# 1. token
[ -r "$TOKEN_FILE" ] || { err "$TOKEN_FILE missing — run the mint step first"; exit 1; }
TOK=$(tr -d '[:space:]' < "$TOKEN_FILE")
[ -n "$TOK" ] || { err "token file is empty"; exit 1; }
docker exec -e VAULT_TOKEN="$TOK" "$VAULT" vault kv get -field=payload_hmac_key secret/signing >/dev/null 2>&1 \
  || { err "token cannot read secret/signing — re-mint a valid token first"; exit 1; }
ok "token validated (reads secret/signing)"

# 2. n8n encryption key
KEY=$(docker exec "$N8N" sh -c 'cat /home/node/.n8n/config 2>/dev/null || cat ~/.n8n/config 2>/dev/null' \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["encryptionKey"])' 2>/dev/null)
[ -n "$KEY" ] || { err "could not read n8n encryptionKey from ~/.n8n/config"; exit 1; }

# 3. build the credential JSON and encrypt it (aes-256-cbc + md5 KDF == CryptoJS)
JSON=$(TOK="$TOK" python3 -c 'import os,json; print(json.dumps({"name":"X-Vault-Token","value":os.environ["TOK"]}))')
BLOB=$(printf '%s' "$JSON" | openssl enc -aes-256-cbc -md md5 -salt -base64 -A -pass pass:"$KEY")

# 4. self-check: our blob must decrypt back to exactly the same JSON before we write it
back=$(printf '%s' "$BLOB" | openssl enc -d -aes-256-cbc -md md5 -base64 -A -pass pass:"$KEY" 2>/dev/null || true)
[ "$back" = "$JSON" ] || { err "self-check failed — encrypted blob does not round-trip; aborting (no change made)"; exit 1; }
ok "credential payload encrypted + round-trip verified"

# 5. back up the current blob, then update
BACK="/home_ai/backups/cred-${CRED_ID}-$(date -u +%Y%m%dT%H%M%SZ).bak"
pg -c "select data from credentials_entity where id='${CRED_ID}';" > "$BACK"
chmod 600 "$BACK"
pg -c "update credentials_entity set data='${BLOB}', \"updatedAt\"=now() where id='${CRED_ID}';" >/dev/null
# verify the stored row now decrypts to the NEW token
stored=$(pg -c "select data from credentials_entity where id='${CRED_ID}';")
got=$(printf '%s' "$stored" | openssl enc -d -aes-256-cbc -md md5 -base64 -A -pass pass:"$KEY" 2>/dev/null \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["value"])' 2>/dev/null)
[ "$got" = "$TOK" ] || { err "post-write read-back mismatch — restoring backup"; pg -c "update credentials_entity set data='$(cat "$BACK")' where id='${CRED_ID}';" >/dev/null; exit 1; }
ok "credential updated + read-back matches (old blob: $BACK)"

# 6. restart n8n so it reloads the credential
docker restart "$N8N" >/dev/null
ok "n8n restarted — Fetch Vault Keys should now succeed; verify the pipeline drains."
