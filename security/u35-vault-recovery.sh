#!/bin/bash
# u35-vault-recovery.sh — one-shot unseal + cipher rebuild.
#
# - Prompts for the 5 Shamir unseal keys (silent)
# - Submits the first 3 to vault to unseal it now
# - Generates a fresh age identity (no passphrase, no TTY)
# - Re-encrypts all 5 keys to .vault-unseal.age using identity-file mode
# - Round-trip tests the decrypt before declaring success
#
# Run as root (writes to /home_ai/security/).

set -uo pipefail

SECDIR=/home_ai/security
CIPHER="$SECDIR/.vault-unseal.age"
IDENTITY="$SECDIR/.vault-identity.txt"
VAULT_CONTAINER=homeai-vault

if [[ $EUID -ne 0 ]]; then
  echo "✗ must run as root (writes to $SECDIR with mode 0600)"
  exit 1
fi

if ! docker inspect "$VAULT_CONTAINER" >/dev/null 2>&1; then
  echo "✗ container $VAULT_CONTAINER not found"
  exit 1
fi

is_sealed() {
  # vault status exits 2 when sealed; capture first so pipefail doesn't
  # propagate that through the pipe and corrupt our boolean.
  local s
  s=$(docker exec "$VAULT_CONTAINER" vault status -format=json 2>/dev/null)
  [[ -n "$s" ]] && printf '%s' "$s" | grep -q '"sealed": *true'
}

if is_sealed; then
  ALREADY_OPEN=0
else
  echo "ℹ vault reports unsealed — will refresh cipher only"
  ALREADY_OPEN=1
fi

echo
echo "Enter the 5 Shamir unseal keys one at a time."
echo "Input is hidden. Press Enter after each."
echo

declare -a KEYS
for i in 1 2 3 4 5; do
  while true; do
    printf "  key %d of 5: " "$i" > /dev/tty
    IFS= read -rs K < /dev/tty
    printf '\n' > /dev/tty
    K="${K//[[:space:]]/}"
    if [[ -z "$K" ]]; then
      echo "    (empty — retry)" > /dev/tty
      continue
    fi
    # base64 unseal keys are typically 44 chars; accept 30-100 to be safe
    if (( ${#K} < 30 || ${#K} > 100 )); then
      echo "    (length ${#K} looks wrong — retry)" > /dev/tty
      continue
    fi
    KEYS[$i]="$K"
    break
  done
done

echo
echo "→ submitting keys to vault…"

if [[ $ALREADY_OPEN -eq 0 ]]; then
  PROGRESS=0
  for i in 1 2 3 4 5; do
    RESP=$(docker exec "$VAULT_CONTAINER" vault operator unseal -format=json "${KEYS[$i]}" 2>&1)
    if printf '%s' "$RESP" | grep -q '"sealed": *false'; then
      echo "  ✓ unsealed after key $i"
      break
    fi
    if printf '%s' "$RESP" | grep -q '"progress"'; then
      PROGRESS=$((PROGRESS+1))
      echo "  · key $i accepted (progress $PROGRESS/3)"
    else
      echo "  ✗ key $i rejected:"
      printf '%s\n' "$RESP" | sed 's/^/      /'
      # don't abort — bad key, keep trying remainder
    fi
  done

  if is_sealed; then
    echo "✗ vault still sealed after submitting all 5 keys — aborting before cipher rewrite"
    unset KEYS
    exit 1
  fi
else
  echo "  (skipped — vault was already open)"
fi

echo
echo "→ regenerating age identity at $IDENTITY"
umask 077
TMP_ID=$(mktemp -u /tmp/vault-id.XXXXXX)  # name only — age-keygen refuses to overwrite
# age-keygen 1.2 writes the secret key + `# public key:` comment to the file
# and ALSO prints "Public key: …" to stderr. Capture stderr to surface real errors.
if ! KEYGEN_ERR=$(age-keygen -o "$TMP_ID" 2>&1); then
  echo "✗ age-keygen failed: $KEYGEN_ERR"
  shred -u "$TMP_ID" 2>/dev/null || rm -f "$TMP_ID"
  unset KEYS
  exit 1
fi
RECIPIENT=$(grep -E '^# public key:' "$TMP_ID" | awk '{print $NF}')
if [[ -z "$RECIPIENT" ]]; then
  # fall back to the stderr line ("Public key: age1…")
  RECIPIENT=$(printf '%s\n' "$KEYGEN_ERR" | awk -F': *' '/[Pp]ublic key/ {print $NF; exit}')
fi
if [[ -z "$RECIPIENT" ]]; then
  echo "✗ no recipient could be extracted"
  echo "  file ($TMP_ID) contents:"
  sed 's/^/      /' "$TMP_ID"
  echo "  age-keygen stderr:"
  printf '%s\n' "$KEYGEN_ERR" | sed 's/^/      /'
  shred -u "$TMP_ID" 2>/dev/null || rm -f "$TMP_ID"
  unset KEYS
  exit 1
fi
echo "  recipient: $RECIPIENT"

echo "→ encrypting keys to $CIPHER"
TMP_CIPHER=$(mktemp)
{
  for i in 1 2 3 4 5; do
    printf '%s\n' "${KEYS[$i]}"
  done
} | age -r "$RECIPIENT" --armor -o "$TMP_CIPHER"

# round-trip test
echo "→ round-trip test"
DECRYPTED=$(age --decrypt -i "$TMP_ID" "$TMP_CIPHER")
ROUNDTRIP_OK=1
for i in 1 2 3 4 5; do
  if ! printf '%s' "$DECRYPTED" | grep -Fxq "${KEYS[$i]}"; then
    echo "  ✗ key $i missing from round-trip"
    ROUNDTRIP_OK=0
  fi
done
unset DECRYPTED KEYS

if [[ $ROUNDTRIP_OK -ne 1 ]]; then
  echo "✗ round-trip failed — NOT installing new cipher"
  shred -u "$TMP_ID" "$TMP_CIPHER" 2>/dev/null || rm -f "$TMP_ID" "$TMP_CIPHER"
  exit 1
fi
echo "  ✓ all 5 keys round-trip"

# Install — back up the old files first
TS=$(date +%Y%m%d-%H%M%S)
[[ -f "$CIPHER" ]] && cp -a "$CIPHER" "$CIPHER.bak.$TS"
[[ -f "$IDENTITY" ]] && cp -a "$IDENTITY" "$IDENTITY.bak.$TS"

install -m 0600 -o root -g root "$TMP_CIPHER" "$CIPHER"
install -m 0600 -o root -g root "$TMP_ID" "$IDENTITY"

shred -u "$TMP_ID" "$TMP_CIPHER" 2>/dev/null || rm -f "$TMP_ID" "$TMP_CIPHER"

echo
echo "✓ done"
echo "  cipher:   $CIPHER"
echo "  identity: $IDENTITY"
echo "  backups:  *.bak.$TS (if any prior files existed)"
echo
echo "next: update vault-autounseal.sh to identity-file mode, then enable the service."
