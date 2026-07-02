#!/bin/bash
# u119-staff-draft.sh — draft staff WA messages from templates.
#
# Two modes today (more added as needs surface):
#   cover-request <user_id> <shift_date> <start> <end> <site>
#       Builds a wa_templates['staff.cover_request'] draft for one staff
#       member and queues it. Owner approves via Telegram.
#   rota-published [all]
#       Iterates this week's distinct workforce_users with shifts and
#       queues a rota.published nudge per person.
#
# All drafts land in wa_outbound_queue with status='pending_approval'.
# Nothing ships without Jo's explicit approve <id>.

set -euo pipefail
MODE="${1:-help}"
VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

draft() {
  local template_slug="$1" target_label="$2" target_jid="$3" body="$4" reason="$5"
  docker exec -e VAULT_TOKEN="$VAULT_TOKEN" -e SLUG="$template_slug" \
      -e LABEL="$target_label" -e JID="$target_jid" -e BODY="$body" -e REASON="$reason" \
      homeai-bot-responder python3 -u -c "
import os, json, urllib.request, asyncio, asyncpg
TOK = os.environ['VAULT_TOKEN']
pw = json.loads(urllib.request.urlopen(urllib.request.Request(
    'http://vault:8200/v1/secret/data/postgres',
    headers={'X-Vault-Token': TOK})).read())['data']['data']['password']
async def main():
    conn = await asyncpg.connect(f'postgresql://postgres:{pw}@homeai-postgres:5432/homeai')
    await conn.execute(\"SELECT home_ai.set_realm('owner')\")
    qid = await conn.fetchval('''
        INSERT INTO wa_outbound_queue
          (account, target_jid, target_label, body,
           drafted_by, draft_reason, status, realm)
        VALUES ('pub', \$1, \$2, \$3, 'u119-script', \$4, 'pending_approval', 'work')
        RETURNING id
    ''', os.environ['JID'], os.environ['LABEL'], os.environ['BODY'], os.environ['REASON'])
    print(f'queued id={qid}')
    await conn.close()
asyncio.run(main())
"
}

case "$MODE" in
cover-request)
  USER_NAME="${2:-}"
  SHIFT_DATE="${3:-}"
  SHIFT_START="${4:-}"
  SHIFT_END="${5:-}"
  SITE="${6:-pub}"
  [ -z "$USER_NAME" ] && { echo "Usage: $0 cover-request <name> <date YYYY-MM-DD> <start HH:MM> <end HH:MM> [site]"; exit 1; }

  # Resolve phone from workforce_users
  PHONE=$(docker exec homeai-postgres psql -U postgres -d homeai -At -c "
    SELECT raw_payload->>'phone' FROM workforce_users
     WHERE preferred_name ILIKE '%$USER_NAME%' OR full_name ILIKE '%$USER_NAME%'
     LIMIT 1;")
  if [ -z "$PHONE" ]; then
    echo "no phone on file for '$USER_NAME' — populate workforce_users.raw_payload->phone first"
    exit 1
  fi
  BODY="Hi $USER_NAME, could you cover $SHIFT_DATE $SHIFT_START-$SHIFT_END at the $SITE? Reply YES/NO. Thanks — Jo"
  draft "staff.cover_request" "$USER_NAME" "$PHONE" "$BODY" "cover request for $SHIFT_DATE"
  ;;

rota-published)
  echo "Drafting one rota.published per staff with a shift in next 7 days…"
  docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-bot-responder python3 -u -c "
import os, json, urllib.request, asyncio, asyncpg
TOK = os.environ['VAULT_TOKEN']
pw = json.loads(urllib.request.urlopen(urllib.request.Request(
    'http://vault:8200/v1/secret/data/postgres',
    headers={'X-Vault-Token': TOK})).read())['data']['data']['password']
async def main():
    conn = await asyncpg.connect(f'postgresql://postgres:{pw}@homeai-postgres:5432/homeai')
    await conn.execute(\"SELECT home_ai.set_realm('owner')\")
    rows = await conn.fetch('''
        SELECT DISTINCT
          u.id, u.preferred_name, u.full_name,
          u.raw_payload->>'phone' AS phone
          FROM workforce_users u
          JOIN workforce_shifts s ON s.user_external_id = u.external_id
         WHERE s.shift_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 7
           AND u.raw_payload->>'phone' IS NOT NULL
    ''')
    queued = skipped = 0
    for r in rows:
        name = (r['preferred_name'] or r['full_name'] or '').strip()
        phone = (r['phone'] or '').strip()
        if not phone:
            skipped += 1; continue
        body = (f'Hi {name}, this week\\\\\\'s rota is published in Tanda. '
                f'Reply if any clashes. Thanks — Jo')
        await conn.execute('''
            INSERT INTO wa_outbound_queue
              (account, target_jid, target_label, body,
               drafted_by, draft_reason, status, realm)
            VALUES ('pub', \$1, \$2, \$3, 'u119-rota-published', 'rota nudge', 'pending_approval', 'work')
        ''', phone, name, body)
        queued += 1
    print(f'queued {queued}, skipped {skipped} (no phone)')
    await conn.close()
asyncio.run(main())
"
  ;;

help|*)
  echo "Usage: $0 {cover-request <name> <date> <start> <end> [site]|rota-published}"
  ;;
esac
