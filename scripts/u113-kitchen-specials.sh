#!/bin/bash
# u113-kitchen-specials.sh — U113
#
# 10:00 cron: send chef a prompt for today's daily specials. Polls for
# reply, Haiku-parses into kitchen_daily_specials. The parsed specials
# get surfaced in:
#   - the daily reality email
#   - tonight's breakfast email (so guests see "tonight's specials")
#
# TEST mode locked. Set KITCHEN_LIVE=1 in /home_ai/.env to actually email
# kitchen@malthousetintagel.com.

set -uo pipefail
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
MODE="${1:-prompt}"  # 'prompt' = send 10am prompt; 'poll' = check for reply
LIVE="${KITCHEN_LIVE:-0}"

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e LIVE="$LIVE" -e MODE="$MODE" homeai-bot-responder python3 -u <<'PYEOF'
import os, json, urllib.request, asyncio, asyncpg
from datetime import date

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
LIVE        = os.environ.get("LIVE", "0") == "1"
MODE        = os.environ.get("MODE", "prompt")
KITCHEN_TO  = "kitchen@malthousetintagel.com"
TEST_TO     = "jolyon.sandercock@gmail.com"


def vault(p):
    r = urllib.request.urlopen(urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{p}",
        headers={"X-Vault-Token": VAULT_TOKEN}), timeout=5)
    return json.loads(r.read())["data"]["data"]


def send_prompt():
    today = date.today()
    to = KITCHEN_TO if LIVE else TEST_TO
    body_text = (
        f"Morning chef,\n\n"
        f"What are today's specials ({today.strftime('%A %d %B')})? "
        f"Reply to this email with:\n"
        f"  - Starter specials (any)\n"
        f"  - Main specials\n"
        f"  - Pudding specials\n"
        f"  - Wine pairings to push\n"
        f"  - Anything you want pushed via the daily guest email\n\n"
        f"Reply by 11:30 so it goes into the daily breakfast email.\n\n"
        f"— Home AI bot"
    )
    payload = {
        "to": to,
        "subject": f"[Kitchen prompt] Daily specials — {today.strftime('%a %d %b')}",
        "body_text": body_text,
        "reply_to": "info@malthousetintagel.com",
    }
    # Send from admin@ identity (or jolyboxbot in TEST mode)
    account = "admin" if LIVE else "bot"
    r = urllib.request.urlopen(urllib.request.Request(
        f"http://google-fetch:8011/send/{account}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type":"application/json"}, method="POST"), timeout=20)
    return json.loads(r.read())


def haiku_parse(reply_text, anth_key):
    SYSTEM = (
        "You are parsing a head chef's reply listing today's specials for an "
        "English pub/restaurant. Extract structured fields. If a section "
        "isn't mentioned, return empty string."
    )
    TOOL = {
        "name": "record_specials",
        "description": "Capture today's specials.",
        "input_schema": {
            "type": "object",
            "properties": {
                "starters": {"type": "string"},
                "mains":    {"type": "string"},
                "puddings": {"type": "string"},
                "wine_pairings": {"type": "string"},
                "guest_push_message": {"type": "string"},
            },
        },
    }
    payload = {
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 1000,
        "system": [{"type":"text","text":SYSTEM,"cache_control":{"type":"ephemeral"}}],
        "tools": [{**TOOL, "cache_control":{"type":"ephemeral"}}],
        "tool_choice": {"type":"tool","name":"record_specials"},
        "messages": [{"role":"user","content":f"Chef reply:\n\n{reply_text[:4000]}"}],
    }
    r = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(payload).encode(),
        headers={"x-api-key":anth_key,"anthropic-version":"2023-06-01",
                 "content-type":"application/json"}, method="POST")
    j = json.loads(urllib.request.urlopen(r, timeout=60).read())
    for b in j.get("content") or []:
        if b.get("type") == "tool_use":
            return b["input"], j.get("usage")
    return None, j.get("usage")


async def main():
    pg = vault("postgres")["password"]
    anth = vault("anthropic")["api_key"]
    conn = await asyncpg.connect(f"postgresql://postgres:{pg}@homeai-postgres:5432/homeai")
    await conn.execute("SELECT home_ai.set_realm('owner')")

    today = date.today()

    if MODE == "prompt":
        # Send the 10am prompt
        existing = await conn.fetchrow(
            "SELECT id, prompt_message_id FROM kitchen_daily_specials WHERE service_date=$1",
            today)
        if existing and existing["prompt_message_id"]:
            print(f"prompt already sent today (msg {existing['prompt_message_id']})")
            return
        if not LIVE:
            print(f"[TEST] would send prompt to {KITCHEN_TO}; sending to {TEST_TO} instead")
        resp = send_prompt()
        msg_id = resp.get("message_id")
        print(f"prompt sent: {msg_id}")
        await conn.execute("""
            INSERT INTO kitchen_daily_specials
              (service_date, prompt_sent_at, prompt_message_id, realm)
            VALUES ($1, NOW(), $2, 'work')
            ON CONFLICT (service_date) DO UPDATE SET
              prompt_sent_at=EXCLUDED.prompt_sent_at,
              prompt_message_id=EXCLUDED.prompt_message_id
        """, today, msg_id)

    elif MODE == "poll":
        # Check for chef reply
        row = await conn.fetchrow("""
            SELECT id, prompt_message_id FROM kitchen_daily_specials
             WHERE service_date=$1 AND reply_received_at IS NULL
               AND prompt_sent_at IS NOT NULL
        """, today)
        if not row:
            print("no pending prompt for today")
            return
        print(f"[poll stub] would scan thread {row['prompt_message_id']} for reply, "
              "then Haiku-parse. Needs google-fetch thread enum endpoint.")
        # Same google-fetch thread-enum gap as u112. When that endpoint
        # lands, fetch the reply body, call haiku_parse(), persist.

    await conn.close()

asyncio.run(main())
PYEOF
