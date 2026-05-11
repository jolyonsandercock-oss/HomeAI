#!/bin/bash
# /home_ai/.claude/scripts/u13-vault-unseal.sh
#
# U13 — single-passphrase Vault unseal (companion to bootstrap script).
#
# Run after Vault has been started (e.g. from start.sh) but before any
# service that needs Vault. Reads the encrypted blob created by
# u13-bootstrap-auto-unseal.sh, prompts for the passphrase ONCE, and feeds
# the three keys to `vault operator unseal`.
#
# Idempotent: if Vault is already unsealed, exits 0 with a message.
# Falls through to a clear error if the encrypted blob doesn't exist
# (means the user hasn't bootstrapped yet — they need to use start.sh's
# manual 3-key prompt instead).
#
# Run as your normal user (it's just docker exec + gpg):
#   bash /home_ai/.claude/scripts/u13-vault-unseal.sh

set -euo pipefail

ENC_FILE="/home_ai/security/.vault-unseal.enc"

command -v gpg >/dev/null 2>&1 || { echo "✗ install gnupg first"; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "✗ install jq first"; exit 1; }

# ── Is Vault running and sealed? ──────────────────────────────────
if ! docker ps --filter name=homeai-vault --format '{{.Names}}' | grep -q homeai-vault; then
  echo "✗ homeai-vault container is not running. Start it first (./start.sh or docker compose up -d vault)."
  exit 1
fi

SEALED=$(docker exec homeai-vault vault status -format=json 2>/dev/null | jq -r '.sealed' 2>/dev/null || echo "unknown")

case "$SEALED" in
  false)
    echo "✓ Vault is already unsealed. Nothing to do."
    exit 0
    ;;
  true)
    echo "→ Vault is sealed — proceeding with passphrase unseal"
    ;;
  *)
    echo "✗ Could not determine seal status (got: $SEALED). Inspect manually:"
    echo "  docker exec homeai-vault vault status"
    exit 1
    ;;
esac

# ── Encrypted blob present? ───────────────────────────────────────
if [[ ! -f "$ENC_FILE" ]]; then
  echo "✗ no encrypted blob at $ENC_FILE."
  echo "  Either:"
  echo "    1. Run sudo bash /home_ai/.claude/scripts/u13-bootstrap-auto-unseal.sh"
  echo "    2. Or unseal manually: docker exec -it homeai-vault vault operator unseal"
  exit 1
fi

# Need to read root-owned blob — use sudo only for this one read.
if [[ ! -r "$ENC_FILE" ]]; then
  echo "→ blob is root-owned — will need sudo to read"
  SUDO_PREFIX="sudo"
else
  SUDO_PREFIX=""
fi

# ── Prompt + decrypt + unseal ─────────────────────────────────────
read -rsp "Vault unseal passphrase (silent): " PASS; echo
[[ -z "$PASS" ]] && { echo "✗ empty passphrase"; exit 1; }

DECRYPTED=$($SUDO_PREFIX bash -c "gpg --batch --pinentry-mode loopback --passphrase \"\$1\" --decrypt \"\$2\" 2>/dev/null" _ "$PASS" "$ENC_FILE" || true)
unset PASS

if [[ -z "$DECRYPTED" ]]; then
  echo "✗ decryption failed — wrong passphrase or corrupted blob"
  exit 1
fi

# Send each line as an unseal key
echo "→ feeding 3 keys to Vault…"
i=0
while IFS= read -r KEY; do
  [[ -z "$KEY" ]] && continue
  i=$((i+1))
  if ! docker exec -e VKEY="$KEY" homeai-vault sh -c 'vault operator unseal "$VKEY" >/dev/null'; then
    echo "✗ unseal step $i failed"
    unset DECRYPTED KEY
    exit 1
  fi
done <<< "$DECRYPTED"
unset DECRYPTED KEY

# ── Confirm ───────────────────────────────────────────────────────
NEW_SEALED=$(docker exec homeai-vault vault status -format=json 2>/dev/null | jq -r '.sealed')
if [[ "$NEW_SEALED" == "false" ]]; then
  echo "✓ Vault unsealed."
  exit 0
else
  echo "✗ Vault still sealed after 3 unseal calls. Inspect manually."
  exit 1
fi
