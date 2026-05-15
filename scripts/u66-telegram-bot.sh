#!/usr/bin/env bash
# u66-telegram-bot.sh — Telegram bot: polls every minute, silently swallows
# /epos, replies to free-text via Sonnet. Replaces telegram-bot-v1 n8n flow.
#
# Cron: */1 * * * *
#
# Behaviour:
#   * Polls Telegram getUpdates with offset persisted in telegram_bot_state.
#   * Only responds to messages from the configured chat_id (vault telegram).
#   * /epos          → silently swallowed (logged but no reply) per Jo 2026-05-15
#   * /help /start   → quick command list (legacy parity)
#   * /digest /queue /book /invoices /dl  → reply "Use the dashboard, or ask
#                                            me in plain English" (replaces
#                                            the old n8n stats dispatcher)
#   * /pause /resume /sweep                → "Not wired in v1 — ask me in
#                                            plain English" (deferred)
#   * Anything else  → forward to Claude Sonnet with the existing
#                      finance/research slug catalog, reply via Telegram.

set -uo pipefail

VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PG_PW=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -field=password secret/postgres)
PG_DSN="postgresql://postgres:${PG_PW}@homeai-postgres:5432/homeai"
ANTH_KEY=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -field=api_key secret/anthropic)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e PG_DSN="$PG_DSN" -e ANTHROPIC_API_KEY="$ANTH_KEY" \
    homeai-bot-responder python /dev/stdin <<'PYEOF'
import os, json, asyncio, re, urllib.parse
import httpx, asyncpg

PG_DSN = os.environ["PG_DSN"]
ANTH_KEY = os.environ["ANTHROPIC_API_KEY"]
VAULT_TOKEN = os.environ["VAULT_TOKEN"]
VAULT_ADDR = "http://vault:8200"

# Commands Jo asked to SILENTLY suppress (no reply, no error).
SILENCE = {"/epos"}
# Quick canned replies (legacy slash commands → "use the dashboard / ask in
# plain English"). They still ACK so Jo knows the bot heard him.
CANNED = {
    "/help":     ("📜 The bot now understands plain English. Try:\n"
                  "  • how much interest have I paid this year?\n"
                  "  • what was today's pub gross?\n"
                  "  • show me recent invoices from Forest Produce\n"
                  "Slash commands /epos /digest /queue etc are retired — "
                  "open the dashboard for live data."),
    "/start":    ("👋 Hi Jo. Type any question in plain English.\n"
                  "  • Finance: https://jolybox.tailc27dff.ts.net/finance\n"
                  "  • Mission Control: https://jolybox.tailc27dff.ts.net/"),
    "/digest":   "Open https://jolybox.tailc27dff.ts.net/ — Mission Control has live digest tiles.",
    "/queue":    "Open https://jolybox.tailc27dff.ts.net/tasks — full task feed there.",
    "/book":     "Open https://jolybox.tailc27dff.ts.net/caterbook — today + tomorrow accommodation.",
    "/bookings": "Open https://jolybox.tailc27dff.ts.net/caterbook — today + tomorrow accommodation.",
    "/invoices": "Open https://jolybox.tailc27dff.ts.net/invoices — full inbox with filters.",
    "/dl":       "Open https://jolybox.tailc27dff.ts.net/forensics — dead letters.",
    "/pause":    "Pause is wired in n8n only — re-enable telegram-bot-v1 if you need it. (Or just say so in plain English.)",
    "/resume":   "Resume is wired in n8n only — re-enable telegram-bot-v1 if you need it.",
    "/sweep":    "Sweep is wired in n8n only — re-enable telegram-bot-v1 if you need it.",
}

ANTHROPIC_MODEL = "claude-sonnet-4-6"

async def vault_get(client, path):
    r = await client.get(f"{VAULT_ADDR}/v1/secret/data/{path}",
                         headers={"X-Vault-Token": VAULT_TOKEN}, timeout=5)
    r.raise_for_status()
    return r.json()["data"]["data"]

async def tg_get_updates(client, bot_token, offset):
    r = await client.get(
        f"https://api.telegram.org/bot{bot_token}/getUpdates",
        params={"offset": offset, "timeout": 0, "allowed_updates": '["message"]'},
        timeout=10)
    r.raise_for_status()
    return r.json().get("result", [])

async def tg_send(client, bot_token, chat_id, text):
    # Telegram has a 4096-char hard limit
    text = (text or "").strip()
    if not text:
        return None
    if len(text) > 4000:
        text = text[:3996] + "\n…"
    r = await client.post(
        f"https://api.telegram.org/bot{bot_token}/sendMessage",
        data={"chat_id": chat_id, "text": text, "parse_mode": "HTML",
              "disable_web_page_preview": "true"},
        timeout=15)
    return r.status_code

async def call_sonnet(client, question):
    """Whole-system bot. Routes through /api/bot/ask which has access to ALL
    approved query_whitelist slugs + a queue_instruction tool for actions."""
    try:
        r = await client.post(
            "http://homeai-build-dashboard:8090/api/bot/ask",
            headers={"X-Realm": "owner", "content-type": "application/json"},
            json={"question": question, "channel": "telegram"},
            timeout=90)
        if r.status_code == 200:
            j = r.json()
            narrative = (j.get("narrative") or "").strip()
            if narrative and not narrative.startswith("(tool-loop did not"):
                slugs_used = [t.get("slug") for t in (j.get("tool_results") or []) if t.get("slug")]
                bi = j.get("instruction_id")
                if bi:
                    narrative += f"\n\n<i>queued as bot_instructions #{bi}</i>"
                if slugs_used:
                    narrative += f"\n<i>via: {', '.join(slugs_used)}</i>"
                return narrative
            if narrative.startswith("(tool-loop"):
                return ("I needed too many lookups to answer that. Try narrowing "
                        "the question, or open https://jolybox.tailc27dff.ts.net/.")
    except Exception:
        pass
    # Fallback — bare Sonnet, no data access
    r = await client.post(
        "https://api.anthropic.com/v1/messages",
        headers={"x-api-key": ANTH_KEY, "anthropic-version": "2023-06-01",
                 "content-type": "application/json"},
        json={
            "model": ANTHROPIC_MODEL,
            "max_tokens": 600,
            "system": ("You are jolyboxbot, Jo's home-AI assistant. Reply in "
                       "1-3 short paragraphs. If you need data you don't have, "
                       "say what dashboard or page would have it. Money is "
                       "GBP, format £x,xxx.xx."),
            "messages": [{"role": "user", "content": question}],
        },
        timeout=60)
    if r.status_code != 200:
        return f"[anthropic error {r.status_code}]"
    j = r.json()
    return "".join(b.get("text", "") for b in (j.get("content") or [])
                    if b.get("type") == "text").strip() or "(no reply)"

async def log_command(conn, user_id, command, args, result, note=None):
    # command_log.result is CHECK-constrained to (success|denied|error). Map
    # internal states to one of those + carry the real label in result_note.
    res_map = {"success": "success", "denied": "denied", "error": "error"}
    real_result = res_map.get(result, "success")
    if result not in res_map and not note:
        note = result  # preserve the internal label
    async with conn.transaction():
        await conn.execute("SET LOCAL app.current_entity = 'all'")
        await conn.execute("SELECT home_ai.set_realm('owner')")
        await conn.execute("""
            INSERT INTO command_log (user_id, command, args, result, result_note, channel)
            VALUES ($1, $2, $3, $4, $5, 'telegram')
        """, user_id, command, args or "", real_result, note)

async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity = 'all'")
    await conn.execute("SET app.current_realm  = 'owner'")

    async with httpx.AsyncClient() as client:
        tg = await vault_get(client, "telegram")
        bot_token = tg["bot_token"]
        configured_chat = str(tg["chat_id"])

        offset = await conn.fetchval(
            "SELECT last_update_id FROM telegram_bot_state WHERE bot_id='homeai'") or 0
        updates = await tg_get_updates(client, bot_token, offset + 1)
        if not updates:
            print("u66-telegram-bot: no new updates")
            await conn.close()
            return

        max_id = offset
        n_replies = n_silenced = n_canned = n_ai = 0
        for u in updates:
            uid = u.get("update_id", 0)
            max_id = max(max_id, uid)
            m = u.get("message") or {}
            if not m:
                continue
            from_chat = str((m.get("chat") or {}).get("id", ""))
            if from_chat != configured_chat:
                continue
            user_id = str((m.get("from") or {}).get("id", ""))
            text = (m.get("text") or "").strip()
            if not text:
                continue

            # Slash command branch
            if text.startswith("/"):
                cmd = text.split()[0].split("@")[0].lower()
                args = " ".join(text.split()[1:])
                if cmd in SILENCE:
                    await log_command(conn, user_id, cmd, args, "silenced",
                                      "user requested no /epos replies 2026-05-15")
                    n_silenced += 1
                    continue
                if cmd in CANNED:
                    await tg_send(client, bot_token, configured_chat, CANNED[cmd])
                    await log_command(conn, user_id, cmd, args, "success", "canned")
                    n_canned += 1
                    continue
                # Unknown slash — treat as plain text question to Sonnet
                # (e.g. /milk_last_month → "milk last month")
                question = (cmd.lstrip("/").replace("_", " ") + " " + args).strip()
                answer = await call_sonnet(client, question)
                await tg_send(client, bot_token, configured_chat, answer)
                await log_command(conn, user_id, cmd, args, "success", "unknown_slash_as_question")
                n_ai += 1
            else:
                # Free-text — Sonnet via /api/finance/ask
                answer = await call_sonnet(client, text)
                await tg_send(client, bot_token, configured_chat, answer)
                await log_command(conn, user_id, "(text)", text[:200], "success", "free_text")
                n_replies += 1
                n_ai += 1

        # Persist offset
        async with conn.transaction():
            await conn.execute("SET LOCAL app.current_entity = 'all'")
            await conn.execute("SELECT home_ai.set_realm('owner')")
            await conn.execute("""
                UPDATE telegram_bot_state
                   SET last_update_id = GREATEST(last_update_id, $1),
                       updated_at = NOW()
                 WHERE bot_id = 'homeai'
            """, max_id)
        print(f"u66-telegram-bot: {n_replies} replies, {n_silenced} silenced, "
              f"{n_canned} canned, {n_ai} AI, max_update_id={max_id}")

    await conn.close()

asyncio.run(main())
PYEOF
