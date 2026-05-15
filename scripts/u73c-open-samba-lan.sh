#!/usr/bin/env bash
# u73c-open-samba-lan.sh — open SMB ports for the LAN subnet only. Idempotent.
# Detects ufw / nftables / iptables and adds the appropriate rules.

set -euo pipefail

LAN_CIDR="192.168.1.0/24"
LAN_IFACE="wlx6c4cbc0a3f34"

echo "── Pre-state:"
ufw status 2>&1 | head -5 || true

if command -v ufw >/dev/null 2>&1 && ufw status 2>&1 | grep -q "Status: active"; then
    echo "→ ufw active, adding allow rules for $LAN_CIDR"
    ufw allow from "$LAN_CIDR" to any port 445 proto tcp comment 'Samba SMB (LAN)' || true
    ufw allow from "$LAN_CIDR" to any port 139 proto tcp comment 'Samba SMB (LAN)' || true
    ufw reload
elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q 'table '; then
    echo "→ nftables active, adding INPUT accept rules"
    nft add rule inet filter input ip saddr "$LAN_CIDR" tcp dport { 139, 445 } accept comment '"Samba SMB (LAN)"' 2>/dev/null || \
        echo "  (could not add nft rule — chain layout differs)"
else
    echo "→ falling back to iptables"
    iptables -I INPUT -p tcp -s "$LAN_CIDR" --dport 445 -j ACCEPT
    iptables -I INPUT -p tcp -s "$LAN_CIDR" --dport 139 -j ACCEPT
fi

echo
echo "── Post-state (ufw):"
ufw status numbered 2>&1 | grep -E '445|139|Samba' | head -5

echo
echo "── TCP self-test from host:"
timeout 3 bash -c "cat < /dev/tcp/192.168.1.141/445" >/dev/null 2>&1 \
    && echo "  ✓ 192.168.1.141:445 reachable from JolyBox" \
    || echo "  ✗ still blocked — investigate further"
