#!/bin/bash
# /home_ai/security/vault-autounseal.sh
# Decrypts unseal keys via age identity-file mode and submits them to Vault
# via `docker exec` (vault container doesn't publish to host).
# Retries up to 60 times (5 min) waiting for Vault to become ready.
#
# Identity-file mode avoids all TTY/PTY gymnastics — no expect, no pipe-vs-
# heredoc stdin collision (root cause of the May 2026 cipher corruption).

set -uo pipefail
CIPHER=/home_ai/security/.vault-unseal.age
IDENTITY=/home_ai/security/.vault-identity.txt
VAULT_CONTAINER=${VAULT_CONTAINER:-homeai-vault}

[[ -r "$CIPHER" ]]   || { echo "✗ $CIPHER unreadable"; exit 1; }
[[ -r "$IDENTITY" ]] || { echo "✗ $IDENTITY unreadable"; exit 1; }

vault_status() { docker exec "$VAULT_CONTAINER" vault status -format=json 2>/dev/null; }

# Wait for Vault to respond. `vault status` exits 2 when sealed, 0 when unsealed
# — both produce valid JSON, so success = parseable JSON, not exit-zero.
for i in $(seq 1 60); do
  SEAL=$(vault_status)
  if [[ -n "$SEAL" ]] && printf '%s' "$SEAL" | grep -q '"sealed"'; then break; fi
  sleep 5
done

if printf '%s' "$SEAL" | grep -q '"sealed": *false'; then
  echo "$(date -Iseconds) vault already unsealed"
  exit 0
fi

PLAIN=$(age --decrypt -i "$IDENTITY" "$CIPHER")
[[ -n "$PLAIN" ]] || { echo "✗ decryption produced empty"; exit 1; }

while IFS= read -r KEY; do
  [[ -z "$KEY" ]] && continue
  RESP=$(docker exec "$VAULT_CONTAINER" vault operator unseal -format=json "$KEY" 2>&1)
  printf '%s\n' "$RESP" | grep -q '"sealed": *false' && { echo "$(date -Iseconds) unsealed"; unset PLAIN; exit 0; }
done <<< "$PLAIN"
unset PLAIN

SEAL=$(vault_status)
if [[ -n "$SEAL" ]] && printf '%s' "$SEAL" | grep -q '"sealed": *false'; then
  echo "$(date -Iseconds) unsealed (post-loop)"
  exit 0
fi
echo "$(date -Iseconds) ✗ still sealed after submitting all keys"
exit 1
