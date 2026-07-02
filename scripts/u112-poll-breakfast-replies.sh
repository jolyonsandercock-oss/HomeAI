#!/bin/bash
# u112-poll-breakfast-replies.sh — U112
#
# Polls Gmail for replies to the breakfast emails sent by u106. Uses Haiku
# to parse the free-text reply into structured rows in breakfast_orders.
#
# Runs ~hourly via cron — but only when there are unresponded sends.
# TEST mode: parses + logs only, does not flip responded_at. Set
# BREAKFAST_LIVE=1 in /home_ai/.env to commit.
#
# Pre-flight: needs jolyboxbot Gmail refresh token healthy.

set -euo pipefail
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
LIVE="${BREAKFAST_LIVE:-0}"

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e LIVE="$LIVE" homeai-bot-responder python3 -u <<'PYEOF'
import os, json, urllib.request, asyncio, asyncpg, re
from datetime import date

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
LIVE        = os.environ.get("LIVE", "0") == "1"


def vault(p):
    r = urllib.request.urlopen(urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{p}",
        headers={"X-Vault-Token": VAULT_TOKEN}), timeout=5)
    return json.loads(r.read())["data"]["data"]


def haiku_parse(reply_text, menu_summary, guest_count, anth_key):
    """Ask Haiku to extract structured choices. Cache markers on system."""
    SYSTEM = (
        "You are parsing a guest's free-text reply to a breakfast email "
        "from an English seaside inn. The guest may have one or more travelers. "
        "Extract one record per traveler with: guest_index (1, 2…), "
        "service_time (one of '08:00', '08:30', '09:00', or 'flexible'), "
        "hot_drink (Tea / Coffee / Other), dish (the menu item they chose — "
        "may be abbreviated; map to closest menu item), allergies (any "
        "dietary notes), notes (anything else useful for the kitchen)."
    )
    TOOL = {
        "name": "record_breakfast_choices",
        "description": "Record one row per traveler.",
        "input_schema": {
            "type": "object",
            "properties": {
                "orders": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "guest_index":  {"type": "integer"},
                            "service_time": {"type": "string"},
                            "hot_drink":    {"type": "string"},
                            "dish":         {"type": "string"},
                            "allergies":    {"type": "string"},
                            "notes":        {"type": "string"},
                        },
                        "required": ["guest_index", "dish"],
                    },
                },
            },
            "required": ["orders"],
        },
    }
    payload = {
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 800,
        "system": [{"type":"text", "text": SYSTEM,
                    "cache_control":{"type":"ephemeral"}}],
        "tools": [{**TOOL, "cache_control":{"type":"ephemeral"}}],
        "tool_choice": {"type":"tool", "name":"record_breakfast_choices"},
        "messages": [{"role":"user", "content":
            f"Menu:\n{menu_summary}\n\n"
            f"Booking has {guest_count} traveler(s).\n\n"
            f"Guest reply:\n{reply_text[:4000]}"
        }],
    }
    r = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(payload).encode(),
        headers={"x-api-key": anth_key, "anthropic-version":"2023-06-01",
                 "content-type":"application/json"}, method="POST")
    j = json.loads(urllib.request.urlopen(r, timeout=60).read())
    for b in j.get("content") or []:
        if b.get("type") == "tool_use":
            return b["input"], j.get("usage")
    return None, j.get("usage")


def fetch_thread_replies(message_id, account="bot"):
    """Pull thread starting from sent message_id; return the latest reply
    body that isn't from our outbound address."""
    req = urllib.request.Request(
        f"http://google-fetch:8011/message/{account}/{message_id}")
    m = json.loads(urllib.request.urlopen(req, timeout=15).read())
    # Look for thread_id and fetch sibling messages
    thread_id = m.get("threadId")
    if not thread_id:
        return None
    # /messages?account=bot&thread_id=… (google-fetch supports labelIds etc;
    # cheap approach: just check if the sent message has 'In-Reply-To' refs
    # in any newer messages in same thread)
    return None  # placeholder — needs google-fetch thread enumeration support


async def log_ai_usage(conn, model, usage, *, trace):
    if not usage: return
    try:
        await conn.execute("""
            INSERT INTO ai_usage
              (trace_id, task_type, model_used, tier,
               prompt_tokens, completion_tokens,
               cache_creation_tokens, cache_read_tokens,
               service, realm, provider, cached)
            VALUES (NULL, 'breakfast.parse', $1, 'cloud',
                    $2, $3, $4, $5, 'u112-poll-breakfast', 'work', 'anthropic', $6)
        """, model,
             usage.get("input_tokens", 0) or 0,
             usage.get("output_tokens", 0) or 0,
             usage.get("cache_creation_input_tokens", 0) or 0,
             usage.get("cache_read_input_tokens", 0) or 0,
             bool(usage.get("cache_read_input_tokens")))
    except Exception as e:
        print(f"[usage-log] {e}")


async def main():
    pg = vault("postgres")["password"]
    anth = vault("anthropic")["api_key"]
    conn = await asyncpg.connect(f"postgresql://postgres:{pg}@homeai-postgres:5432/homeai")
    await conn.execute("SELECT home_ai.set_realm('owner')")

    pending = await conn.fetch("""
        SELECT s.id, s.accommodation_booking_id, s.email_token, s.service_date,
               s.guest_email, s.guest_count, s.gmail_message_id
          FROM breakfast_email_sends s
         WHERE s.responded_at IS NULL
           AND s.sent_at >= NOW() - INTERVAL '36 hours'
         ORDER BY s.sent_at
    """)
    print(f"unresponded breakfast sends: {len(pending)}")
    if not pending:
        return

    # Placeholder — needs google-fetch thread enumeration. The MVP path is:
    # 1) On each send, store gmail_message_id (already done by u106)
    # 2) Poll /messages?account=bot&query=in:inbox newer_than:2d to:bot@…
    # 3) Match by In-Reply-To header → email_token
    # For now, log skeleton + count.
    matched = 0
    for s in pending:
        reply = fetch_thread_replies(s["gmail_message_id"])
        if not reply:
            continue
        matched += 1
        parsed, usage = haiku_parse(reply, "(menu cached)", s["guest_count"], anth)
        await log_ai_usage(conn, "claude-haiku-4-5-20251001", usage,
                           trace=f"breakfast-{s['email_token']}")
        if not LIVE:
            print(f"  [TEST] would insert {len(parsed.get('orders', []))} rows for token {s['email_token']}")
            continue
        for o in parsed.get("orders", []):
            await conn.execute("""
                INSERT INTO breakfast_orders
                  (accommodation_booking_id, email_token, guest_index,
                   service_date, service_time, hot_drink, dish, allergies, notes, realm)
                VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,'work')
                ON CONFLICT (email_token, guest_index) DO UPDATE SET
                  service_time=EXCLUDED.service_time,
                  hot_drink=EXCLUDED.hot_drink,
                  dish=EXCLUDED.dish,
                  allergies=EXCLUDED.allergies,
                  notes=EXCLUDED.notes
            """, s["accommodation_booking_id"], s["email_token"],
                 o.get("guest_index", 1), s["service_date"],
                 o.get("service_time"), o.get("hot_drink"),
                 o.get("dish"), o.get("allergies"), o.get("notes"))
        await conn.execute(
            "UPDATE breakfast_email_sends SET responded_at = NOW() WHERE id = $1",
            s["id"])

    print(f"matched: {matched}/{len(pending)} (LIVE={LIVE})")
    await conn.close()

asyncio.run(main())
PYEOF
