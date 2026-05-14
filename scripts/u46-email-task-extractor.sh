#!/bin/bash
# /home_ai/scripts/u46-email-task-extractor.sh
#
# Scan recent inbound emails and classify any operational follow-up they imply:
#   - action       (explicit ask: "please confirm", "can you reply")
#   - complaint    (refund/disappointed/lawyer/bad review)
#   - follow_up    (we sent something and they haven't replied)
#   - renewal      (insurance/licence/contract renewal coming up)
#   - enquiry      (general info request — lower urgency)
#
# Writes to `email_tasks` (idempotent on email_id).
# Severity 1–5 set by the extractor. Urgency = age_days × severity.
#
# Cron candidate: */20 * * * *

set -uo pipefail
WINDOW_HOURS="${1:-72}"
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e WINDOW_HOURS="$WINDOW_HOURS" \
  homeai-bot-responder python << 'PYEOF'
import os, json, urllib.request, asyncio, asyncpg
from datetime import date as _date
import anthropic

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN      = os.environ["PG_DSN"]
WINDOW_HOURS = int(os.environ.get("WINDOW_HOURS", "72"))
MODEL       = "claude-haiku-4-5-20251001"
SCHEMA_VERSION = "email-task-extractor@U46"


def vault_get(p):
    r = urllib.request.Request(f"http://vault:8200/v1/secret/data/{p}",
                                headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(r, timeout=5).read())["data"]["data"]


SYSTEM = [{
  "type": "text",
  "text": (
    "You triage inbound emails for Jo Sandercock (Tintagel pub + holiday lets + property co).\n"
    "Decide whether an email implies an operational task. Return a JSON tool call.\n"
    "Severity scale 1-5:\n"
    "  5 = legal / refund-now / health & safety incident\n"
    "  4 = unhappy guest, formal complaint, regulator, bank account issue\n"
    "  3 = explicit ask requiring a written reply within a few days\n"
    "  2 = booking / supplier enquiry, renewal warning, minor follow-up\n"
    "  1 = info-only / no real action implied (still tracked as 'enquiry')\n"
    "If the email is a transactional confirmation, marketing blast, no-reply auto-message, "
    "newsletter, or bot output — return needs_task=false.\n"
    "Be tight: do NOT manufacture tasks for things that are clearly read-only."
  ),
  "cache_control": {"type": "ephemeral"},
}]

TOOL = {
  "name": "classify_email_task",
  "description": "Decide if this email is an actionable task; if yes, classify it.",
  "input_schema": {
    "type": "object",
    "properties": {
      "needs_task": {"type": "boolean"},
      "task_type":  {"type": "string",
                     "enum": ["action","complaint","follow_up","renewal","enquiry","none"]},
      "severity":   {"type": "integer", "minimum": 1, "maximum": 5},
      "due_by":     {"type": ["string","null"],
                     "description": "ISO date YYYY-MM-DD if a deadline is implied, else null"},
      "summary":    {"type": "string", "description": "One sentence describing the task"},
    },
    "required": ["needs_task","task_type","severity","summary"],
  },
}


async def main():
    client = anthropic.Anthropic(api_key=vault_get("anthropic")["api_key"])
    conn = await asyncpg.connect(PG_DSN)
    # R6: emails span work/family — extractor runs as OWNER to see all.
    await conn.execute("SET app.current_realm = 'owner'")

    rows = await conn.fetch(f"""
      SELECT e.id, e.gmail_message_id, e.account, e.subject,
             COALESCE(e.body_text_safe, e.body_text) AS body,
             e.from_address, e.from_name, e.received_at
      FROM emails e
      LEFT JOIN email_tasks t ON t.email_id = e.id
      WHERE e.received_at > now() - INTERVAL '{WINDOW_HOURS} hours'
        AND t.id IS NULL
        AND COALESCE(e.from_address, '') NOT ILIKE '%noreply%'
        AND COALESCE(e.from_address, '') NOT ILIKE '%no-reply%'
        AND COALESCE(e.from_address, '') NOT ILIKE '%mailer-daemon%'
        AND COALESCE(e.from_address, '') NOT ILIKE '%notifications@%'
        AND COALESCE(e.body_text_safe, e.body_text, '') <> ''
      ORDER BY e.received_at DESC
      LIMIT 100
    """)
    print(f"candidates: {len(rows)}")

    created = 0
    for r in rows:
        body = (r["body"] or "")[:6000]
        user_msg = (
            f"FROM: {r['from_name']} <{r['from_address']}>\n"
            f"SUBJECT: {r['subject']}\n"
            f"BODY:\n{body}"
        )
        try:
            resp = client.messages.create(
                model=MODEL, max_tokens=400, system=SYSTEM,
                tools=[TOOL], tool_choice={"type": "tool", "name": "classify_email_task"},
                messages=[{"role": "user", "content": user_msg}],
            )
        except Exception as e:
            print(f"email {r['id']}: api error {e}")
            continue
        block = next((b for b in resp.content if getattr(b, "type", "") == "tool_use"), None)
        if not block:
            continue
        out = block.input or {}
        if not out.get("needs_task") or out.get("task_type") == "none":
            continue
        due_raw = out.get("due_by")
        due_d = None
        if due_raw:
            try: due_d = _date.fromisoformat(due_raw[:10])
            except Exception: due_d = None
        try:
            await conn.execute("""
              INSERT INTO email_tasks
                (email_id, gmail_message_id, account, subject,
                 task_type, severity, due_by, notes, extractor_payload)
              VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb)
              ON CONFLICT (email_id) DO NOTHING
            """, r["id"], r["gmail_message_id"], r["account"], r["subject"],
                 out["task_type"], int(out["severity"]),
                 due_d,
                 out.get("summary", ""), json.dumps({
                   "model": MODEL, "schema": SCHEMA_VERSION,
                   "input_usage": resp.usage.input_tokens,
                   "output_usage": resp.usage.output_tokens,
                 }))
            created += 1
        except Exception as e:
            print(f"email {r['id']}: insert error {e}")
    print(f"created: {created} tasks")
    await conn.close()


asyncio.run(main())
PYEOF
