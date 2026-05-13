#!/bin/bash
# /home_ai/scripts/u39-review-drafter.sh
#
# For each new guest_reviews row (status='new'), draft a Sonnet response.
# Per SPEC §7.4. Uses tool-use with input_schema (per U38 pattern).
# Hospitality-tone, location-aware. Cached system prompt for cost.
#
# Cron candidate: */10 * * * *  (frequent enough to catch reviews fast,
# rate-limited by checking status='new' so re-runs are cheap).
#
# Telegram-alerts immediately on rating ≤3 (separate from the draft path).

set -uo pipefail
LIMIT="${1:-20}"
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e LIMIT="$LIMIT" homeai-bot-responder python << 'PYEOF'
import os, json, urllib.request, urllib.parse, asyncio, asyncpg, hashlib
import anthropic

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN      = os.environ["PG_DSN"]
LIMIT       = int(os.environ.get("LIMIT", "20"))
MODEL       = "claude-sonnet-4-6"
SCHEMA_VERSION = "review-drafter@U39"


def vault_get(p):
    r = urllib.request.Request(f"http://vault:8200/v1/secret/data/{p}",
                                headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(r, timeout=5).read())["data"]["data"]


def tg_send(text):
    """Best-effort Telegram. Logs to telegram_outbox via the notify-telegram.sh path
    would need host-side execution; here we do direct API and INSERT to outbox via DB."""
    try:
        d = vault_get("telegram")
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{d['bot_token']}/sendMessage",
            data=urllib.parse.urlencode({
                "chat_id": d["chat_id"], "text": text,
                "disable_notification": "false",
            }).encode())
        urllib.request.urlopen(req, timeout=10)
        return True
    except Exception as e:
        print(f"tg err: {e}")
        return False


# ── System prompt (cached) ───────────────────────────────────
SYSTEM_BLOCKS = [{
    "type": "text",
    "text": (
        "You draft hospitality review responses for Jo's two Tintagel businesses:\n"
        "  - The Olde Malthouse Inn (location='malthouse'): a Cornish pub + inn. Tone: warm, "
        "    Cornish-friendly, mention the pub itself naturally (a pint, the bar, the rooms).\n"
        "  - The Artisan Sandwich Shop (location='sandwich'): an artisan cafe / sandwich shop. "
        "    Tone: warm, food-focused (good coffee, fresh sandwiches), inviting return visits.\n"
        "\n"
        "Tone rules — non-negotiable:\n"
        "  - Always thank the reviewer by their first name if given. If anonymous, use 'thanks for taking the time'.\n"
        "  - Address SPECIFIC points from the review. Never write generic 'thank you for your review'.\n"
        "  - For 1-3 star reviews: acknowledge the specific issue, offer a path forward "
        "    (manager email, return visit). Never defensive, never 'I'm sorry you feel that way'.\n"
        "  - Never invent staff names. Use 'the manager' or 'Jo (owner)'.\n"
        "  - 80-150 words. No markdown — review platforms strip it.\n"
        "  - End with a warm invitation to return (if positive) or to email if there's something "
        "    we should follow up on (if negative).\n"
        "\n"
        "Call the record_draft tool with the response text — never produce free text."
    ),
    "cache_control": {"type": "ephemeral"},
}]

DRAFT_TOOL = {
    "name": "record_draft",
    "description": "Record a drafted hospitality response for a guest review.",
    "input_schema": {
        "type": "object",
        "properties": {
            "draft_text": {
                "type": "string",
                "minLength": 50,
                "maxLength": 1500,
                "description": "The response text, 80-150 words."
            },
            "tone": {
                "type": "string",
                "enum": ["positive_thanks", "neutral_acknowledge", "negative_repair"],
                "description": "Tone bucket for analytics."
            },
            "address_email": {
                "type": ["string", "null"],
                "description": "If the response invites a follow-up email, the email address to use (info@malthousetintagel.com for both)."
            },
            "needs_human_review": {
                "type": "boolean",
                "description": "True if the review is ambiguous, mentions a serious issue (allergic reaction, injury, theft), or otherwise needs Jo to draft personally."
            }
        },
        "required": ["draft_text", "tone", "needs_human_review"]
    }
}


async def main():
    api_key = vault_get("anthropic")["api_key"]
    client  = anthropic.Anthropic(api_key=api_key)
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity='1'")

    rows = await conn.fetch("""
      SELECT review_id, source, location, rating, reviewer_name, body, posted_at
        FROM guest_reviews
       WHERE status='new'
       ORDER BY posted_at DESC NULLS LAST, scraped_at DESC
       LIMIT $1
    """, LIMIT)

    print(f"new reviews to draft: {len(rows)}")
    drafted = 0
    alerted = 0

    for r in rows:
        # Telegram alert on ≤3 star — fires BEFORE drafting attempt
        if (r["rating"] or 5) <= 3:
            star_str = "★" * (r["rating"] or 0)
            body_preview = (r["body"] or "")[:120].replace("\n", " ")
            tg_send(
                f"⭐ {r['rating']}★ review on {r['source']} for {r['location']}\n"
                f"From: {r['reviewer_name'] or 'anonymous'}\n"
                f"\"{body_preview}\"\n\n"
                f"Response drafted in Action Queue."
            )
            alerted += 1

        user_msg = (
            f"Location: {r['location']}\n"
            f"Source: {r['source']}\n"
            f"Rating: {r['rating']} stars\n"
            f"Reviewer: {r['reviewer_name'] or 'anonymous'}\n"
            f"Review:\n{r['body'] or '(empty body)'}"
        )

        try:
            resp = client.messages.create(
                model=MODEL,
                max_tokens=600,
                system=SYSTEM_BLOCKS,
                tools=[DRAFT_TOOL],
                tool_choice={"type": "tool", "name": "record_draft"},
                messages=[{"role": "user", "content": user_msg}],
            )
        except Exception as e:
            print(f"  {r['source']}/{r['review_id']} api err: {str(e)[:120]}")
            continue

        tool_uses = [b for b in resp.content if b.type == "tool_use"]
        if not tool_uses:
            print(f"  {r['source']}/{r['review_id']} no tool_use")
            continue
        d = tool_uses[0].input
        cache_hit = (getattr(resp.usage, "cache_read_input_tokens", 0) or 0) > 0

        async with conn.transaction():
            await conn.execute("SET LOCAL app.current_entity='1'")
            await conn.execute("""
              INSERT INTO review_drafts (review_id, source, draft_text, sonnet_model, schema_version, prompt_cache_hit)
              VALUES ($1, $2, $3, $4, $5, $6)
            """, r["review_id"], r["source"], d["draft_text"], MODEL, SCHEMA_VERSION, cache_hit)
            await conn.execute("""
              UPDATE guest_reviews SET status='drafted' WHERE review_id=$1 AND source=$2
            """, r["review_id"], r["source"])

            # ai_usage log
            try:
                await conn.execute("""
                  INSERT INTO ai_usage (task_type, model_used, tier, prompt_tokens, completion_tokens, cached, provider)
                  VALUES ('review_drafter', $1, 'cloud', $2, $3, $4, 'anthropic')
                """, MODEL, resp.usage.input_tokens, resp.usage.output_tokens, cache_hit)
            except Exception: pass

        drafted += 1
        print(f"  ✓ drafted {r['source']}/{r['review_id']} (cache_hit={cache_hit})")

    await conn.close()
    print(f"\ndone. drafted={drafted}  ≤3-star alerts={alerted}")

asyncio.run(main())
PYEOF
