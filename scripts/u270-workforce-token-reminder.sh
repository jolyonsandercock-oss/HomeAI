#!/bin/bash
# u270-workforce-token-reminder.sh — one-shot Telegram reminder for Jo.
#
# Created 2026-06-09 at Jo's request: nudge him on Thu 2026-06-11 to regenerate
# the Workforce.com (Tanda) API token WITH the `settings` + `organisation` scopes
# (keeping existing read scopes), so we can read the configured on-cost % and make
# our labour costs match the Workforce reports.
#
# Self-deleting: after sending, it removes its own line from joly's crontab so it
# fires exactly once even though the cron expression ("57 8 11 6 *") would
# otherwise recur annually.

set -euo pipefail

MARKER="u270-workforce-token-reminder"

VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-bot-responder python3 -u <<'PYEOF'
import os, json, urllib.request
TOK = os.environ["VAULT_TOKEN"]
def vault(p):
    r = urllib.request.urlopen(urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{p}",
        headers={"X-Vault-Token": TOK}), timeout=5)
    return json.loads(r.read())["data"]["data"]
tg = vault("telegram")
text = (
    "⏰ *Reminder: Workforce token re-scope*\n\n"
    "Regenerate the Workforce.com (Tanda) API access token with the *Settings* and "
    "*Organisation* scopes added — keep all existing read scopes (Staff / Rosters / "
    "Timesheets / Payroll) too, or the shift sync breaks.\n\n"
    "1. https://my.workforce.com/api/oauth/access_tokens → generate new token (tick all read scopes)\n"
    "2. Store it: `./scripts/u29-workforce-creds.sh`\n\n"
    "This unlocks the real on-cost % (holiday + employer NI + pension) so labour "
    "costs match your Workforce reports. Once it's stored, tell Claude and it will "
    "read the on-cost figure, rebuild costing, and backfill full history to 2023-06."
)
req = urllib.request.Request(
    f"https://api.telegram.org/bot{tg['bot_token']}/sendMessage",
    data=json.dumps({"chat_id": tg["chat_id"], "text": text,
                     "parse_mode": "Markdown", "disable_web_page_preview": True}).encode(),
    headers={"Content-Type": "application/json"}, method="POST")
resp = urllib.request.urlopen(req, timeout=10).read()
print("sent:", json.loads(resp).get("ok"))
PYEOF
rc=$?

# Self-delete this job from crontab so it never fires again (one-shot).
crontab -l 2>/dev/null | grep -v "$MARKER" | crontab -

exit $rc
