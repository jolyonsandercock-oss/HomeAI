#!/bin/bash
# u119-wa-approval-loop.sh — U119
#
# Walks wa_outbound_queue. For every status='pending_approval' row, posts
# a Telegram message to Jo with the draft + a one-line approve command.
# Jo replies "approve <id>" (handled by bot-responder); status flips to
# 'approved'. Worker (this script in 'dispatch' mode, or cron at :07/min)
# ships approved rows.
#
# Usage:
#   ./u119-wa-approval-loop.sh notify     # post pending drafts to Telegram
#   ./u119-wa-approval-loop.sh dispatch   # ship every approved row via wa-bridge
#
# Approval mechanics: Jo replies in his pinned Home AI Telegram thread:
#   approve 42        → flips wa_outbound_queue id=42 to 'approved'
#   approve all       → flips every pending row
#   reject 42 [reason]
# These commands handled by the bot-responder's instruction queue.

set -uo pipefail
MODE="${1:-notify}"

VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

case "$MODE" in
notify)
  docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-bot-responder python3 -u <<'PYEOF'
import os, json, urllib.request, asyncio, asyncpg
TOK = os.environ["VAULT_TOKEN"]

def vault(p):
    r = urllib.request.urlopen(urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{p}",
        headers={"X-Vault-Token": TOK}), timeout=5)
    return json.loads(r.read())["data"]["data"]

def tg_send(text):
    tg = vault("telegram")
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{tg['bot_token']}/sendMessage",
        data=json.dumps({
            "chat_id": tg["chat_id"], "text": text,
            "parse_mode": "Markdown", "disable_web_page_preview": True,
        }).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    return urllib.request.urlopen(req, timeout=10).read()

async def main():
    pg = vault("postgres")["password"]
    conn = await asyncpg.connect(f"postgresql://postgres:{pg}@homeai-postgres:5432/homeai")
    await conn.execute("SELECT home_ai.set_realm('owner')")
    pending = await conn.fetch("""
        SELECT id, account, target_label, target_jid, body, draft_reason, created_at
          FROM wa_outbound_queue
         WHERE status = 'pending_approval'
           AND (approval_msg_id IS NULL OR
                created_at >= NOW() - INTERVAL '4 hours')
         ORDER BY created_at LIMIT 10
    """)
    if not pending:
        print("nothing pending")
        return
    for r in pending:
        msg = (
            f"📲 *WA draft for approval* — id `{r['id']}`\n"
            f"_account_: {r['account']}\n"
            f"_to_: *{r['target_label'] or r['target_jid']}*\n"
            f"_reason_: {r['draft_reason'] or '(no reason)'}\n\n"
            f"```\n{r['body'][:500]}\n```\n"
            f"Reply `approve {r['id']}` or `reject {r['id']}`"
        )
        try:
            tg_send(msg)
            await conn.execute(
                "UPDATE wa_outbound_queue SET approval_msg_id='tg' WHERE id=$1", r["id"])
            print(f"  notified id={r['id']}")
        except Exception as e:
            print(f"  TG send failed for id={r['id']}: {e}")
    await conn.close()

asyncio.run(main())
PYEOF
  ;;

dispatch)
  echo "── Posting to wa-bridge to ship approved rows:"
  curl -sX POST http://localhost:8770/outbound/dispatch | python3 -m json.tool
  ;;

*)
  echo "Usage: $0 {notify|dispatch}"
  exit 1
  ;;
esac
