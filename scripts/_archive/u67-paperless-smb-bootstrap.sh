#!/usr/bin/env bash
# u67-paperless-smb-bootstrap.sh — install + configure Samba so the Brother
# ADS-2800W can SMB-drop scans into Paperless-ngx's consume folder.
#
# Run ONCE at the box, as root (sudo).  Idempotent.
#
# Result: a share named "paperless-consume" reachable at
#   \\100.104.82.53\paperless-consume
# with one user "scanner" (password set during install). The scanner
# writes files here; Paperless polls every 30s (PAPERLESS_CONSUMER_POLLING).

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo bash $0"
    exit 1
fi

CONSUME=/home_ai/storage/paperless/consume
SHARE_NAME=paperless-consume
SCAN_USER=scanner

if [[ ! -d "$CONSUME" ]]; then
    echo "✗ $CONSUME doesn't exist — bring Paperless up first"
    exit 1
fi

echo "Step 1/5 — installing samba server …"
apt-get update -qq
apt-get install -y -qq samba samba-common-bin
echo "  ✓ samba installed"

echo
echo "Step 2/5 — ensure consume folder is writable by the scanner …"
# Paperless container runs as UID 1000 (USERMAP_UID) — make the consume
# folder writeable by both UID 1000 AND the samba scanner user.
chown joly:joly "$CONSUME"
chmod 0775 "$CONSUME"
echo "  ✓ $CONSUME → joly:joly 775"

echo
echo "Step 3/5 — add 'scanner' system user (or skip if present) …"
# Ubuntu ships with a `scanner` group as part of sane-utils. If it exists,
# use it as the user's primary group via `-g`; otherwise let useradd auto-
# create one. Either way we add the user to `joly` as a supplementary group
# so writes inherit joly's ownership for Paperless (which runs as UID 1000).
if ! id "$SCAN_USER" >/dev/null 2>&1; then
    if getent group "$SCAN_USER" >/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin \
                -g "$SCAN_USER" --groups joly "$SCAN_USER"
        echo "  ✓ created system user '$SCAN_USER' (using existing '$SCAN_USER' group)"
    else
        useradd --system --no-create-home --shell /usr/sbin/nologin \
                --groups joly "$SCAN_USER"
        echo "  ✓ created system user '$SCAN_USER'"
    fi
else
    usermod -aG joly "$SCAN_USER"
    echo "  ✓ '$SCAN_USER' already exists, ensured in joly group"
fi

echo
echo "Step 4/5 — set Samba password for '$SCAN_USER' …"
echo "  (enter a fresh password — write it down, you'll type it into the Brother web UI next)"
smbpasswd -a "$SCAN_USER"
smbpasswd -e "$SCAN_USER" >/dev/null
echo "  ✓ samba user enabled"

echo
echo "Step 5/5 — write share definition + restart samba …"
SMB_CONF=/etc/samba/smb.conf
if ! grep -q "^\[$SHARE_NAME\]" "$SMB_CONF"; then
    cat >>"$SMB_CONF" <<EOF

# Brother ADS-2800W → Paperless-ngx consume folder (U67)
[$SHARE_NAME]
   comment    = Paperless-ngx consume folder for Brother scanner
   path       = $CONSUME
   browseable = yes
   writable   = yes
   read only  = no
   guest ok   = no
   valid users = $SCAN_USER
   force user  = joly
   force group = joly
   create mask = 0664
   directory mask = 0775
EOF
    echo "  ✓ share appended to $SMB_CONF"
else
    echo "  ✓ share '$SHARE_NAME' already in $SMB_CONF (left alone)"
fi

systemctl enable --now smbd >/dev/null 2>&1
systemctl restart smbd
systemctl is-active smbd

echo
echo "── Verification ──"
testparm -s 2>/dev/null | grep -A 1 "$SHARE_NAME" | head -10
echo
echo "── Smoke test from this host (writes a probe file) ──"
PROBE=/tmp/u67-probe-$$.txt
echo "probe from $(hostname) at $(date)" > "$PROBE"
smbclient "//127.0.0.1/$SHARE_NAME" -U "$SCAN_USER%REPLACE_WITH_PASSWORD" \
    -c "put $PROBE u67-probe.txt" 2>&1 | tail -3 || \
    echo "(skip — you'll test from the Brother in a moment)"
rm -f "$PROBE"

echo
echo "════════════════════════════════════════════════════════════════"
echo "DONE. Now configure the scanner."
echo "════════════════════════════════════════════════════════════════"
echo
echo "On the Brother ADS-2800W web UI (http://<scanner-IP>/):"
echo
echo "  1. Login → Scan → Scan to Network → Profile slot 1 → name 'AI BATCH'"
echo "  2. Network Address (Host):  100.104.82.53"
echo "  3. Share Name:              $SHARE_NAME"
echo "  4. Username / Password:     $SCAN_USER / <the password you just set>"
echo "  5. File type:               PDF (Searchable)   ← important"
echo "  6. Resolution:              300 dpi"
echo "  7. 2-sided scan:            Long-edge binding (or off for single-sided)"
echo "  8. Skip Blank Page:         OFF (separators rely on blank pages)"
echo "  9. Auto Color Detect:       ON"
echo " 10. File name:               AI_\${YYYY}\${MM}\${DD}_\${hh}\${mm}\${ss}"
echo
echo "Touchscreen → 'Scan to Network' → 'AI BATCH' → load mortgage statements"
echo "with a blank page between each → press Start."
echo
echo "Within 30s the PDFs land at $CONSUME and Paperless OCRs them."
echo "Within 15 min u62-paperless-sync.sh mirrors them into the documents table."
echo "Then they're queryable from /documents and via the bot."
