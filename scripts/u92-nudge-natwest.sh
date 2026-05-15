#!/usr/bin/env bash
# u92-nudge-natwest.sh — one-shot Telegram nudge for Jo to pull NatWest CSVs.
# Self-removes from cron after firing so it doesn't re-prompt.
#
# Triggered by:
#   30 9 * * * /home_ai/scripts/u92-nudge-natwest.sh  # tomorrow 09:30
# Script then deletes its own crontab entry.

set -uo pipefail

VT=$(docker inspect homeai-bot-responder --format '{{range .Config.Env}}{{println .}}{{end}}' \
     | grep '^VAULT_TOKEN=' | cut -d= -f2-)
TG=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -format=json secret/telegram \
     | python3 -c "import sys,json; d=json.load(sys.stdin)['data']['data']; print(d['bot_token']+'|'+d['chat_id'])")
BOT=$(echo "$TG" | cut -d'|' -f1)
CHAT=$(echo "$TG" | cut -d'|' -f2)

TEXT='🏦 *NatWest CSV pull reminder*

Per U90 in-person packet:

• Acct *48885517* (ATR Trading current #2, Dojo settlement) — full available history
• Acct *48747300* (Tax Reserve — ATR savings) — last 6 months
• Acct *SANDERCOCK J personal #3* — last 6 months
• Acct *SANDERCOCK J personal #4* — last 6 months

Save to `/home_ai/data/natwest-inbox/<acct>.csv`, then:
`bash /home_ai/scripts/u72-onboard-48885517.sh /home_ai/data/natwest-inbox/48885517-full-history.csv`

Verify: `bash /home_ai/scripts/u90-verify.sh`'

curl -sS -X POST -d "chat_id=$CHAT" --data-urlencode "text=$TEXT" \
    -d "parse_mode=Markdown" \
    "https://api.telegram.org/bot$BOT/sendMessage" >/dev/null

# Self-remove from cron
crontab -l 2>/dev/null | grep -v 'u92-nudge-natwest' | crontab -

logger -t u92-nudge-natwest "nudge sent + cron entry removed"
echo "✓ NatWest nudge sent + cron self-removed at $(date -Iseconds)"
