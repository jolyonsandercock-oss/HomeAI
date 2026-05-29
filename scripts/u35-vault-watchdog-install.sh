#!/bin/bash
# u35-vault-watchdog-install.sh — one-shot installer for the vault watchdog.
# Pulls telegram creds from vault, drops a root-only creds file, installs
# the systemd unit, enables the timer, seeds the state file.
#
# Run as root.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "✗ must run as root"
  exit 1
fi

CREDS=/home_ai/security/.vault-watchdog-creds
SCRIPT=/home_ai/scripts/vault-watchdog.sh
SVC_SRC=/home_ai/scripts/vault-watchdog.service
TMR_SRC=/home_ai/scripts/vault-watchdog.timer

[[ -x "$SCRIPT" || -r "$SCRIPT" ]] || { echo "✗ $SCRIPT missing"; exit 1; }
[[ -r "$SVC_SRC" ]] || { echo "✗ $SVC_SRC missing"; exit 1; }
[[ -r "$TMR_SRC" ]] || { echo "✗ $TMR_SRC missing"; exit 1; }

echo "→ pulling telegram creds from vault"
VT=$(docker inspect homeai-bot-responder \
       --format '{{range .Config.Env}}{{println .}}{{end}}' \
     | grep '^VAULT_TOKEN=' | cut -d'=' -f2-)
[[ -n "$VT" ]] || { echo "✗ no VAULT_TOKEN in bot-responder"; exit 1; }

CREDS_JSON=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault \
               vault kv get -format=json secret/telegram)
BT=$(printf '%s' "$CREDS_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["data"]["bot_token"])')
CI=$(printf '%s' "$CREDS_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["data"]["chat_id"])')
[[ -n "$BT" && -n "$CI" ]] || { echo "✗ failed to extract creds"; exit 1; }
echo "  bot_token tail: …${BT: -6}"
echo "  chat_id:        $CI"

echo "→ writing $CREDS (root-only)"
umask 077
{
  printf 'TG_BOT_TOKEN=%s\n' "$BT"
  printf 'TG_CHAT_ID=%s\n'   "$CI"
} > "$CREDS"
chown root:root "$CREDS"
chmod 0600 "$CREDS"

echo "→ tightening watchdog script perms"
chown root:root "$SCRIPT"
chmod 0700 "$SCRIPT"

echo "→ installing systemd units"
install -m 0644 "$SVC_SRC" /etc/systemd/system/vault-watchdog.service
install -m 0644 "$TMR_SRC" /etc/systemd/system/vault-watchdog.timer
systemctl daemon-reload
systemctl enable --now vault-watchdog.timer

echo "→ seeding state file (first run, no page)"
systemctl start vault-watchdog.service
sleep 2

echo
echo "--- service status ---"
systemctl status vault-watchdog.service --no-pager | head -12
echo
echo "--- timer next-fire ---"
systemctl list-timers vault-watchdog.timer --no-pager | head -5
echo
echo "--- state file ---"
cat /var/lib/vault-watchdog/last-state 2>/dev/null || echo "(no state yet)"
echo
echo "✓ done. Watchdog will page Telegram on next sealed↔unsealed transition."
