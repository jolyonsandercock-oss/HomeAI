#!/bin/bash
# /home_ai/scripts/u35-vault-autounseal-bootstrap.sh
#
# ONE-SHOT bootstrap for unattended Vault unsealing on boot.
#
# Run with sudo. You'll be prompted for 3 of the 5 unseal keys interactively.
# After this completes, a `systemctl reboot` no longer needs Jo to be present.
#
# What it does:
#  1. Installs the `age` package.
#  2. Derives a machine-bound passphrase from /etc/machine-id (stable across
#     reboots, root-only readable, never leaves the box).
#  3. Encrypts the 3 unseal keys you paste in, writes them to
#     /home_ai/security/.vault-unseal.age (mode 600, root-owned).
#  4. Installs /home_ai/security/vault-autounseal.sh — the runtime script
#     that decrypts + submits keys via Vault HTTP API on boot.
#  5. Installs /etc/systemd/system/vault-autounseal.service — fires after
#     Docker comes up, with retry loop until Vault responds.
#  6. Enables (not starts) the service. To dry-run before reboot:
#       sudo systemctl start vault-autounseal.service
#       sudo journalctl -u vault-autounseal -f
#
# Idempotent — safe to re-run. Will skip steps already completed.

set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "✗ run with sudo: sudo bash $0"
  exit 1
fi

RED='\033[0;31m'; YEL='\033[0;33m'; GREEN='\033[0;32m'; NC='\033[0m'

SEC=/home_ai/security
CIPHER=$SEC/.vault-unseal.age
RUNTIME=$SEC/vault-autounseal.sh
SYSTEMD=/etc/systemd/system/vault-autounseal.service

# ── 1. Install age ────────────────────────────────────────────
if ! command -v age >/dev/null 2>&1; then
  echo -e "${YEL}→${NC} installing age"
  apt-get update -qq
  apt-get install -y age
else
  echo -e "${GREEN}✓${NC} age already installed: $(age --version 2>/dev/null | head -1)"
fi
# age ≥1.2 reads the passphrase from /dev/tty, ignoring stdin. We drive it via
# `expect` in a PTY (same pattern as /home_ai/security/vault-autounseal.sh).
if ! command -v expect >/dev/null 2>&1; then
  echo -e "${YEL}→${NC} installing expect"
  apt-get install -y expect
fi

# ── 2. Derive machine passphrase ──────────────────────────────
if [[ ! -r /etc/machine-id ]]; then
  echo -e "${RED}✗${NC} /etc/machine-id unreadable — can't derive machine key"
  exit 1
fi
MID=$(cat /etc/machine-id)
# Stretch with sha256 so the on-disk artefact isn't directly /etc/machine-id
MACHINE_PASS=$(printf '%s|home_ai|vault-autounseal' "$MID" | sha256sum | cut -d' ' -f1)

# ── 3. Encrypt unseal keys ────────────────────────────────────
if [[ -s "$CIPHER" ]]; then
  echo -e "${GREEN}✓${NC} $CIPHER already exists (size=$(stat -c%s "$CIPHER")) — skipping re-encrypt"
  echo "   (if keys are wrong, delete the file and re-run this script)"
else
  echo
  echo -e "${YEL}→${NC} paste 3 of your 5 Vault unseal keys, one per line"
  echo "   Each key is 32 chars + 1 trailing digit (the share index)."
  echo "   Just paste, press Enter; we read silently."
  echo
  declare -a KEYS=()
  for i in 1 2 3; do
    read -rsp "  Unseal key $i: " K
    printf '\n'
    [[ -n "$K" ]] || { echo "✗ empty key"; exit 1; }
    KEYS+=("$K")
  done
  PLAIN_FILE=$(mktemp)
  chmod 600 "$PLAIN_FILE"
  printf '%s\n' "${KEYS[@]}" > "$PLAIN_FILE"
  unset KEYS

  # Drive age via expect so the passphrase prompt (and confirm-prompt) get the
  # machine passphrase from a PTY. The plaintext (unseal keys) comes from the
  # input file via -. Without expect, age 1.2 dies under cron/systemd with
  # "could not read passphrase from /dev/tty". Without the input file, the
  # pipe-and-heredoc trick of the prior version silently encrypted the
  # passphrase string as the plaintext (cipher unrecoverable).
  MACHINE_PASS="$MACHINE_PASS" PLAIN_FILE="$PLAIN_FILE" CIPHER="$CIPHER" \
  expect <<'EXPECT' >/dev/null
log_user 0
set timeout 20
spawn -noecho sh -c "age --passphrase --armor -o $env(CIPHER) $env(PLAIN_FILE)"
expect {
  -re "passphrase.*:" { send -- "$env(MACHINE_PASS)\r"; exp_continue }
  -re "[Cc]onfirm.*:" { send -- "$env(MACHINE_PASS)\r"; exp_continue }
  -re "[Rr]e-type.*:" { send -- "$env(MACHINE_PASS)\r"; exp_continue }
  eof
}
EXPECT
  rm -f "$PLAIN_FILE"
  if [[ ! -s "$CIPHER" ]]; then
    echo -e "${RED}✗${NC} encryption produced empty cipher — abort"
    exit 1
  fi
  chmod 600 "$CIPHER"
  chown root:root "$CIPHER"
  echo -e "${GREEN}✓${NC} encrypted keys → $CIPHER (mode 600, root:root, size $(stat -c%s "$CIPHER")B)"

  # Round-trip self-test: decrypt and confirm we get back exactly the 3 keys.
  DECRYPTED=$(MACHINE_PASS="$MACHINE_PASS" CIPHER="$CIPHER" expect <<'EXPECT2' | tr -d '\r' | sed '/^$/d'
log_user 0
set timeout 10
spawn -noecho age --decrypt $env(CIPHER)
expect "passphrase*:"
send -- "$env(MACHINE_PASS)\r"
log_user 1
expect eof
EXPECT2
)
  lines=$(printf '%s\n' "$DECRYPTED" | wc -l)
  if [[ "$lines" -ne 3 ]]; then
    echo -e "${RED}✗${NC} round-trip self-test failed: expected 3 lines, got $lines — cipher is corrupt"
    rm -f "$CIPHER"
    exit 1
  fi
  echo -e "${GREEN}✓${NC} round-trip self-test passed (3 keys recoverable)"
  unset DECRYPTED
fi

# ── 4. Install runtime script ─────────────────────────────────
# Runtime script is maintained in-tree at this canonical location and copied
# into place. Single source of truth — no risk of bootstrap drifting from
# the deployed script (the previous inlined-heredoc version did, and shipped
# a broken `echo $PASS | age` pattern that doesn't work on age ≥1.2).
RUNTIME_SOURCE="$(dirname "$(readlink -f "$0")")/../security/vault-autounseal.sh"
if [[ ! -f "$RUNTIME_SOURCE" ]]; then
  echo -e "${RED}✗${NC} canonical runtime script missing: $RUNTIME_SOURCE"
  exit 1
fi
install -m 700 -o root -g root "$RUNTIME_SOURCE" "$RUNTIME"
echo -e "${GREEN}✓${NC} runtime script → $RUNTIME (from $RUNTIME_SOURCE)"

# ── 5. systemd unit ───────────────────────────────────────────
cat > "$SYSTEMD" <<'UNIT_EOF'
[Unit]
Description=Home AI — Vault auto-unseal
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/home_ai/security/vault-autounseal.sh
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT_EOF
chmod 644 "$SYSTEMD"
systemctl daemon-reload
systemctl enable vault-autounseal.service
echo -e "${GREEN}✓${NC} systemd unit installed + enabled"

# ── 6. Dry-run hint ───────────────────────────────────────────
echo
echo "── done ──"
echo
echo "Dry-run (won't actually reboot):"
echo "  sudo systemctl start vault-autounseal.service"
echo "  sudo journalctl -u vault-autounseal -f      # tail logs"
echo
echo "Full reboot test (when you're ready to walk away from the machine):"
echo "  sudo reboot"
echo "  # then from another tailnet machine in ~2 min:"
echo "  curl -sf http://100.104.82.53:8200/v1/sys/seal-status | grep sealed"
echo "  # expect: \"sealed\":false"
