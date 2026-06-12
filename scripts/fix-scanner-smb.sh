#!/bin/bash
# fix-scanner-smb.sh — restore Brother ADS-2800W scanner → Samba [scans] path.
# Root cause (2026-06-12): two independent breaks
#   1. smb.conf bound `interfaces = lo wlx6c4cbc0a3f34` (old USB wifi dongle,
#      gone since the 2026-06-07 reboot; box is wired on enp1s0 now) with
#      `bind interfaces only = yes` → smbd silently bound loopback only.
#   2. box-hardening-root.sh (2026-06-11) set ufw default deny incoming with
#      only 22/tcp + tailscale0 allowed → SMB from LAN blocked regardless.
# Fix: rebind to enp1s0, restart smbd/nmbd, allow Samba app profile from LAN.
# Run as root: sudo bash /home_ai/scripts/fix-scanner-smb.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "must run as root"; exit 1; }

CONF=/etc/samba/smb.conf
LAN_NET=192.168.1.0/24
LAN_IP=$(ip -4 -br addr show enp1s0 | awk '{print $3}' | cut -d/ -f1)
[ -n "$LAN_IP" ] || { echo "enp1s0 has no IPv4 address — aborting"; exit 1; }

echo "== 1. Backup =="
BK="${CONF}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$CONF" "$BK"
echo "backed up to $BK"

echo "== 2. Rebind interfaces (wlx6c4cbc0a3f34 → enp1s0) =="
sed -i 's/^\(\s*interfaces = \)lo wlx6c4cbc0a3f34\s*$/\1lo enp1s0/' "$CONF"
grep -n "^\s*interfaces = " "$CONF" | head -1

echo "== 3. Validate config =="
if ! testparm -s "$CONF" >/dev/null 2>&1; then
  echo "testparm FAILED — restoring backup, no changes applied"
  cp -a "$BK" "$CONF"
  exit 1
fi
echo "testparm OK"

echo "== 4. Restart smbd + nmbd =="
systemctl restart smbd nmbd
sleep 2

echo "== 5. UFW: allow Samba from LAN only =="
ufw allow from "$LAN_NET" to any app Samba >/dev/null
ufw status | grep -i samba || true

echo "== 6. Verify =="
ss -tln | grep -E "${LAN_IP}:445" \
  && echo "PASS: smbd listening on ${LAN_IP}:445" \
  || { echo "FAIL: smbd not listening on ${LAN_IP}:445"; exit 1; }
timeout 3 bash -c "cat < /dev/null > /dev/tcp/${LAN_IP}/445" \
  && echo "PASS: 445 reachable on LAN IP" \
  || { echo "FAIL: 445 not reachable on ${LAN_IP}"; exit 1; }
echo "Done. Now press scan on the Brother to confirm end-to-end."
