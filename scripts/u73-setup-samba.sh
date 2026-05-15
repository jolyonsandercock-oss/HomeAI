#!/usr/bin/env bash
# u73-setup-samba.sh — add the [scans] share to /etc/samba/smb.conf and
# create the `scanner` Samba user. Password is generated, stored in Vault
# at secret/samba/scanner, and printed once so it can be entered on the
# Brother. Idempotent.

set -euo pipefail

SHARE_PATH="/mnt/shared_storage/scans/inbox"
SAMBA_USER="scanner"
SMB_CONF="/etc/samba/smb.conf"
SHARE_MARKER="# === U73 scans share ==="

if [[ ! -d "$SHARE_PATH" ]]; then
    echo "✗ $SHARE_PATH does not exist — run u73-format-hd.sh first"
    exit 1
fi

# 1. Add the [scans] share to smb.conf if not present.
if grep -q "$SHARE_MARKER" "$SMB_CONF"; then
    echo "• [scans] share already in $SMB_CONF"
else
    cat >> "$SMB_CONF" <<EOF

$SHARE_MARKER
[scans]
   comment        = Brother scanner drop — auto-OCR'd by Paperless
   path           = $SHARE_PATH
   browseable     = yes
   read only      = no
   guest ok       = no
   valid users    = $SAMBA_USER
   write list     = $SAMBA_USER
   force user     = $SAMBA_USER
   force group    = $SAMBA_USER
   create mask    = 0664
   directory mask = 0775
   # Brother MFCs do not negotiate SMB3 reliably — allow SMB2.
   server min protocol = SMB2
EOF
    echo "✓ appended [scans] block to $SMB_CONF"
fi

# 2. Create the Linux user (no shell, no home) if absent. Required because
#    Samba PAM-syncs against the Linux passwd database.
if ! id -u "$SAMBA_USER" >/dev/null 2>&1; then
    useradd --no-create-home --shell /usr/sbin/nologin "$SAMBA_USER"
    echo "✓ created Linux user $SAMBA_USER"
else
    echo "• Linux user $SAMBA_USER already exists"
fi

# 3. Generate password, set Samba password, lock the Linux account.
PW=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)
(echo "$PW"; echo "$PW") | smbpasswd -a -s "$SAMBA_USER" >/dev/null
smbpasswd -e "$SAMBA_USER" >/dev/null
echo "✓ Samba password set for $SAMBA_USER"

# 4. Stash in Vault so Brother config / future reruns can recover it.
VT=$(docker inspect homeai-bot-responder \
     --format '{{range .Config.Env}}{{println .}}{{end}}' \
     | grep '^VAULT_TOKEN=' | cut -d= -f2-)
docker exec -e VAULT_TOKEN="$VT" homeai-vault \
    vault kv put secret/samba/scanner \
        username="$SAMBA_USER" password="$PW" share="scans" \
        host="$(hostname -I | awk '{print $1}')" \
        path="$SHARE_PATH" >/dev/null
echo "✓ credentials stored at secret/samba/scanner"

# 5. Validate config + restart Samba.
testparm -s >/dev/null
systemctl restart smbd nmbd 2>/dev/null || systemctl restart smbd
sleep 1
systemctl is-active smbd && echo "✓ smbd active"

# 6. Print credentials for Brother setup (one-time).
TAILSCALE_IP=$(ip -4 addr show tailscale0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
LAN_IP=$(hostname -I | awk '{print $1}')
echo
echo "──────────────  BROTHER ADS-2800W setup  ──────────────"
echo "  Server (LAN):      $LAN_IP"
echo "  Server (Tailscale):${TAILSCALE_IP:+ $TAILSCALE_IP}"
echo "  Share name:        scans"
echo "  Username:          $SAMBA_USER"
echo "  Password:          $PW"
echo "  SMB protocol:      SMBv2"
echo "  Path on share:     /  (drops PDFs at /mnt/shared_storage/scans/inbox)"
echo "────────────────────────────────────────────────────────"
echo
echo "Password also stored in Vault: docker exec -e VAULT_TOKEN=\$VT homeai-vault vault kv get secret/samba/scanner"
