#!/bin/bash
# /home_ai/.claude/scripts/u13-bootstrap-auto-unseal.sh
#
# U13 Stage E — one-time setup for "single-passphrase Vault unseal".
#
# Why this exists:
#   start.sh currently prompts for 3 separate unseal keys at every reboot.
#   This script collects those 3 keys ONCE, encrypts them together with a
#   passphrase you choose, and saves the encrypted blob. Then at every reboot
#   you only need to type your passphrase (once) — the unseal script handles
#   the rest.
#
# Security trade-off:
#   * Before: 3 keys ever exist only in your head/keepass. Stealing the
#     machine doesn't reveal them.
#   * After: 3 keys still encrypted at rest with your chosen passphrase.
#     Stealing the machine reveals encrypted-blob-only — passphrase still
#     required. Choose a STRONG passphrase (not the same as your login).
#   * If you forget the passphrase, you can still recover by typing all 3
#     keys directly into Vault (the shamir keys still work — this is
#     additive, not a replacement).
#
# Run this ONCE on the machine. After it succeeds, use
# `u13-vault-unseal.sh` at boot instead of manual key entry.
#
# Run as root (writes to /home_ai/security/):
#   sudo bash /home_ai/.claude/scripts/u13-bootstrap-auto-unseal.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "✗ run as root: sudo bash $0"
  exit 1
fi

ENC_FILE="/home_ai/security/.vault-unseal.enc"

command -v gpg >/dev/null 2>&1 || { echo "✗ install gnupg first (apt-get install gnupg)"; exit 1; }

if [[ -f "$ENC_FILE" ]]; then
  echo "✗ $ENC_FILE already exists. To re-bootstrap, move it aside first:"
  echo "    sudo mv $ENC_FILE $ENC_FILE.bak.$(date +%s)"
  exit 1
fi

echo "── U13 Stage E: bootstrap single-passphrase Vault unseal ──"
echo
echo "You'll be asked for:"
echo "  * Three of your five Vault unseal keys (silent input — same ones start.sh asks for)"
echo "  * A new passphrase to encrypt those keys with (silent, twice)"
echo

# ── Collect keys ──────────────────────────────────────────────────
read -rsp "Unseal key 1 (silent): " K1; echo
read -rsp "Unseal key 2 (silent): " K2; echo
read -rsp "Unseal key 3 (silent): " K3; echo

[[ -z "$K1" || -z "$K2" || -z "$K3" ]] && { echo "✗ all three keys are required"; exit 1; }

# Quick sanity — try to unseal a sealed Vault to verify the keys are correct.
SEAL_STATE=$(docker exec homeai-vault vault status -format=json 2>/dev/null | jq -r '.sealed' 2>/dev/null || echo "unknown")

if [[ "$SEAL_STATE" == "true" ]]; then
  echo "→ Vault is currently sealed. Validating keys by attempting unseal…"
  for K in "$K1" "$K2" "$K3"; do
    if ! docker exec -e VKEY="$K" homeai-vault sh -c 'vault operator unseal "$VKEY" >/dev/null'; then
      echo "✗ unseal failed — at least one of those keys is wrong. No file written."
      exit 1
    fi
  done
  echo "  ✓ Vault unsealed with the 3 keys you provided"
elif [[ "$SEAL_STATE" == "false" ]]; then
  echo "  (Vault already unsealed — can't verify keys against a live unseal,"
  echo "   but we'll trust your input and write the encrypted blob.)"
else
  echo "  (Vault status unknown — trusting input. Verify manually after reboot.)"
fi

# ── Collect passphrase ────────────────────────────────────────────
echo
read -rsp "New passphrase (silent): " PASS; echo
read -rsp "Confirm passphrase    : " PASS2; echo
[[ "$PASS" != "$PASS2" ]] && { echo "✗ passphrases don't match"; exit 1; }
[[ ${#PASS} -lt 16 ]] && { echo "✗ minimum 16 chars"; exit 1; }
unset PASS2

# ── Encrypt ───────────────────────────────────────────────────────
echo "→ writing encrypted blob to $ENC_FILE"
PAYLOAD=$(printf '%s\n%s\n%s\n' "$K1" "$K2" "$K3")
unset K1 K2 K3

echo -n "$PAYLOAD" | gpg --batch --yes --pinentry-mode loopback \
  --passphrase "$PASS" \
  --symmetric --cipher-algo AES256 --output "$ENC_FILE" -
unset PAYLOAD PASS

chmod 600 "$ENC_FILE"
chown root:root "$ENC_FILE"

echo
echo "── DONE ──"
echo
echo "From now on, unseal Vault with:"
echo "  bash /home_ai/.claude/scripts/u13-vault-unseal.sh"
echo
echo "(start.sh's manual 3-key prompt still works — this is additive.)"
echo
echo "Backup the passphrase somewhere offline (paper / Keepass / 1Password)."
echo "If you lose it, you can still unseal manually with the 3 original keys."
