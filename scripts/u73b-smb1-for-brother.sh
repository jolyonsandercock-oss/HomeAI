#!/usr/bin/env bash
# u73b-smb1-for-brother.sh — Path B from the diagnosis: allow SMB1/NTLMv1
# so the Brother ADS-2800W can negotiate, while binding Samba to lo + LAN
# only so the loosened auth isn't reachable over Tailscale or the wider
# internet.
#
# Idempotent. Re-runs are safe.

set -euo pipefail

SMB_CONF="/etc/samba/smb.conf"
LAN_IFACE="wlx6c4cbc0a3f34"           # detected from `ip -br a` (Wi-Fi)
LAN_CIDR="192.168.1.0/24"
GLOBAL_MARKER="# === U73b Brother-compat + LAN-bind ==="

# 1. Drop the dead `server min protocol = SMB2` line that we accidentally
#    parked inside the [scans] block — it's a [global]-only parameter so it
#    does nothing there, but it misleads anyone reading the conf.
sed -i '/^\s*# Brother MFCs do not negotiate SMB3 reliably — allow SMB2\.$/d' "$SMB_CONF"
sed -i '/^\s*server min protocol = SMB2$/d' "$SMB_CONF"

# 2. Append the global-block overrides if not present.
if ! grep -q "$GLOBAL_MARKER" "$SMB_CONF"; then
    # Inject just BEFORE the first non-global section header (e.g. "[printers]")
    # so the new directives land inside [global]. awk handles this safely.
    awk -v marker="$GLOBAL_MARKER" -v iface="$LAN_IFACE" -v cidr="$LAN_CIDR" '
        BEGIN {injected=0}
        /^\[/ && NR>1 && !injected {
            print ""
            print "   " marker
            print "   server min protocol = NT1"
            print "   client min protocol = NT1"
            print "   ntlm auth = ntlmv1-permitted"
            print "   interfaces = lo " iface
            print "   bind interfaces only = yes"
            print "   hosts allow = 127.0.0.1 " cidr
            print ""
            injected=1
        }
        {print}
    ' "$SMB_CONF" > "${SMB_CONF}.new"
    mv "${SMB_CONF}.new" "$SMB_CONF"
    echo "✓ appended Brother-compat + LAN-bind block"
else
    echo "• Brother-compat block already in $SMB_CONF"
fi

# 3. Install smbclient so we can self-test from this host.
if ! command -v smbclient >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq smbclient
    echo "✓ installed smbclient"
else
    echo "• smbclient already installed"
fi

# 4. Validate + reload.
testparm -s >/dev/null
systemctl restart smbd
sleep 1
systemctl is-active smbd && echo "✓ smbd active"

# 5. Show the effective protocol/auth knobs the server now advertises.
echo
echo "Effective config (relevant knobs):"
testparm -s 2>/dev/null | grep -E "server min protocol|client min protocol|ntlm auth|interfaces|bind interfaces|hosts allow" | sed 's/^/  /'

# 6. Verify SMB is now ONLY on loopback + LAN.
echo
echo "Listening sockets:"
ss -tlnp 2>/dev/null | grep -E ':445|:139' | sed 's/^/  /'

# 7. Self-test: list shares as the scanner user.
VT=$(docker inspect homeai-bot-responder \
     --format '{{range .Config.Env}}{{println .}}{{end}}' \
     | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault \
     vault kv get -field=password secret/samba/scanner)
unset VT

echo
echo "smbclient self-test (lists shares as 'scanner'):"
smbclient -L //127.0.0.1 -U "scanner%$PW" 2>&1 | grep -E 'scans|Sharename|Disk|Protocol|Anonymous' | head -10 | sed 's/^/  /'

unset PW
echo
echo "Now retry from the Brother — Test Connection should succeed."
