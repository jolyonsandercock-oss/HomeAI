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
  PLAIN=$(printf '%s\n' "${KEYS[@]}")
  unset KEYS

  printf '%s' "$PLAIN" | age --passphrase --armor > "$CIPHER" <<EOF
$MACHINE_PASS
$MACHINE_PASS
EOF
  unset PLAIN
  chmod 600 "$CIPHER"
  chown root:root "$CIPHER"
  echo -e "${GREEN}✓${NC} encrypted keys → $CIPHER (mode 600, root:root)"
fi

# ── 4. Install runtime script ─────────────────────────────────
cat > "$RUNTIME" <<'RUNTIME_EOF'
#!/bin/bash
# /home_ai/security/vault-autounseal.sh
# Decrypts unseal keys with the machine-bound passphrase and submits them
# to Vault. Retries up to 60 times (5 min) waiting for Vault to become ready.

set -uo pipefail
CIPHER=/home_ai/security/.vault-unseal.age
VAULT_URL=${VAULT_URL:-http://127.0.0.1:8200}

[[ -r "$CIPHER" ]] || { echo "✗ $CIPHER unreadable"; exit 1; }
[[ -r /etc/machine-id ]] || { echo "✗ /etc/machine-id unreadable"; exit 1; }

MID=$(cat /etc/machine-id)
MACHINE_PASS=$(printf '%s|home_ai|vault-autounseal' "$MID" | sha256sum | cut -d' ' -f1)

# Wait for Vault
for i in $(seq 1 60); do
  if curl -sf --max-time 3 "$VAULT_URL/v1/sys/seal-status" >/dev/null; then break; fi
  sleep 5
done

# Check seal state — exit 0 if already unsealed
SEAL=$(curl -sf --max-time 5 "$VAULT_URL/v1/sys/seal-status")
if printf '%s' "$SEAL" | grep -q '"sealed":false'; then
  echo "$(date -Iseconds) vault already unsealed"
  exit 0
fi

# Decrypt
PLAIN=$(echo "$MACHINE_PASS" | age --decrypt --passphrase "$CIPHER")
[[ -n "$PLAIN" ]] || { echo "✗ decryption produced empty"; exit 1; }

while IFS= read -r KEY; do
  [[ -z "$KEY" ]] && continue
  RESP=$(curl -sf --max-time 5 -X POST -d "{\"key\":\"$KEY\"}" "$VAULT_URL/v1/sys/unseal")
  printf '%s\n' "$RESP" | grep -q '"sealed":false' && { echo "$(date -Iseconds) unsealed"; unset PLAIN; exit 0; }
done <<< "$PLAIN"
unset PLAIN

# Final check
SEAL=$(curl -sf --max-time 5 "$VAULT_URL/v1/sys/seal-status")
if printf '%s' "$SEAL" | grep -q '"sealed":false'; then
  echo "$(date -Iseconds) unsealed (post-loop)"
  exit 0
fi
echo "$(date -Iseconds) ✗ still sealed after submitting all keys"
exit 1
RUNTIME_EOF
chmod 700 "$RUNTIME"
chown root:root "$RUNTIME"
echo -e "${GREEN}✓${NC} runtime script → $RUNTIME"

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
