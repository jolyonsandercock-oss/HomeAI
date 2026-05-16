"""bot-responder — picks one pending query-lane bot_instruction, runs it.

Pipeline:
  1. Fetch ONE row: lane='query' AND status='pending' ORDER BY received_at ASC
  2. If sender_email not in bot_sender_whitelist → mark 'rejected', log to
     query_rejections (reason='other', detail='sender not whitelisted'), exit.
  3. Otherwise call Haiku with the 6 whitelisted slugs as tools. Haiku picks
     a slug + params → we look up the row in query_whitelist, validate the
     params against param_schema, bind, run as homeai_readonly, return rows.
  4. Loop until Haiku produces a final text answer. Send via /send/bot.
  5. If Haiku declines or no slug fits → set needs_session=true, Telegram
     "needs session: …", leave row pending.

Strict invariants:
  - Haiku NEVER writes SQL. It only chooses a slug.
  - Param values are validated against param_schema BEFORE binding.
  - SQL is executed as homeai_readonly with app.current_entity = '3' (Personal).
"""
from __future__ import annotations
import os, json, base64, hashlib, re, asyncio, urllib.request, urllib.parse, urllib.error
from datetime import datetime, timezone

import asyncpg
import anthropic

PG_DSN_ADMIN = os.environ["PG_DSN"]        # postgres user — for whitelist + writes
VAULT_TOKEN  = os.environ["VAULT_TOKEN"]
# PG_DSN_RO resolved at runtime from vault if not pre-set

MODEL = os.environ.get("BOT_RESPONDER_MODEL", "claude-haiku-4-5-20251001")
# Bot-responder system + tools = ~4165 tokens. Empirically observed:
#   - Sonnet 4.6 caches reliably at this size (cw=3808, cr=3808 on hit).
#   - Haiku 4.5 does NOT cache below ~5000 tokens (threshold higher than
#     the documented 2048 — verified 2026-05-16). Caching is a no-op.
# To enable caching: override BOT_RESPONDER_MODEL with a Sonnet model id
# Trade: Sonnet is ~3x slower, ~5x base input cost — but at >50% cache
# hit (likely for stable system+tools) effective cost is comparable or
# cheaper than Haiku, and quality is meaningfully higher.
MAX_TOOL_ITERS = 6
RESPONDER_NAME = "bot-responder"


def vault_get(path):
    req = urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{path}",
        headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())["data"]["data"]


def tg_send(text):
    try:
        d = vault_get("telegram")
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{d['bot_token']}/sendMessage",
            data=urllib.parse.urlencode({"chat_id": d["chat_id"], "text": text}).encode())
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f"tg err: {e}")


def email_reply(*, to, subject, body_text, body_html=None):
    payload = {
        "to": to,
        "subject": subject,
        "reply_to": "jolyboxbot@gmail.com",
        "body_text": body_text,
        "body_html": body_html or f"<pre>{body_text}</pre>",
    }
    req = urllib.request.Request(
        "http://google-fetch:8011/send/bot",
        method="POST",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    r = urllib.request.urlopen(req, timeout=30)
    return json.loads(r.read()).get("message_id")


# ── Slug → Anthropic tool conversion ────────────────────────────────────

def slug_to_tool(row):
    """Turn a query_whitelist row into an Anthropic tool definition."""
    props, required = {}, []
    schema = row["param_schema"] or {}
    if isinstance(schema, str):
        schema = json.loads(schema)
    for name, spec in schema.items():
        t = spec.get("type", "string")
        jt = {"int": "integer", "float": "number", "bool": "boolean",
              "string": "string", "str": "string"}.get(t, "string")
        prop = {"type": jt, "description": spec.get("description") or f"{name} ({t})"}
        if "min" in spec: prop["minimum"] = spec["min"]
        if "max" in spec: prop["maximum"] = spec["max"]
        if "values" in spec: prop["enum"] = spec["values"]
        if "default" in spec: prop["default"] = spec["default"]
        props[name] = prop
        if spec.get("required"):
            required.append(name)
    return {
        "name": row["slug"],
        "description": (row["description"] or row["display_name"] or row["slug"])[:1000],
        "input_schema": {
            "type": "object",
            "properties": props,
            "required": required,
        },
    }


# ── Param validation ───────────────────────────────────────────────────

def validate_params(schema_raw, supplied):
    """Return (ok, bound_or_reason). On failure returns (False, ('reason','detail'))."""
    schema = schema_raw or {}
    if isinstance(schema, str):
        schema = json.loads(schema)
    bound = {}
    for name, spec in schema.items():
        if name in supplied:
            v = supplied[name]
        elif spec.get("required"):
            return False, ("param_missing", f"required param '{name}' missing")
        elif "default" in spec:
            v = spec["default"]
        else:
            continue

        t = spec.get("type", "string")
        try:
            if t == "int":   v = int(v)
            elif t == "float": v = float(v)
            elif t == "bool":  v = bool(v)
            elif t in ("string","str"):
                if not isinstance(v, str): v = str(v)
            elif t == "enum":
                if v not in spec.get("values", []):
                    return False, ("param_range", f"{name}={v!r} not in {spec.get('values')}")
        except (ValueError, TypeError) as e:
            return False, ("param_type", f"{name}={v!r}: {e}")

        if "min" in spec and v < spec["min"]:
            return False, ("param_range", f"{name}={v} < min {spec['min']}")
        if "max" in spec and v > spec["max"]:
            return False, ("param_range", f"{name}={v} > max {spec['max']}")
        bound[name] = v

    # Reject extra params Haiku tried to pass
    extras = set(supplied) - set(schema)
    if extras:
        return False, ("param_type", f"unknown params: {sorted(extras)}")
    return True, bound


# ── Slug execution ──────────────────────────────────────────────────────

NAMED_PARAM_RE = re.compile(r":([a-zA-Z_][a-zA-Z0-9_]*)")

async def run_slug(ro_conn, slug_row, bound, caller_realm):
    """Bind :param style placeholders to asyncpg's $1/$2 and execute."""
    sql = slug_row["sql_template"]
    seen = []
    def repl(m):
        n = m.group(1)
        if n not in seen:
            seen.append(n)
        return f"${seen.index(n) + 1}"
    sql_pg = NAMED_PARAM_RE.sub(repl, sql)
    args = [bound[n] for n in seen]
    # Read-only safety: wrap in a read-only transaction
    async with ro_conn.transaction(readonly=True):
        await ro_conn.execute("SET LOCAL app.current_entity = '3'")
        await ro_conn.execute("SELECT home_ai.set_realm($1)", caller_realm)
        rows = await ro_conn.fetch(sql_pg, *args)
    return [dict(r) for r in rows]


# ── Logging rejections ─────────────────────────────────────────────────

async def log_rejection(conn, *, asked_by, channel, raw_question,
                        classifier_slug=None, classifier_score=None,
                        bound_params=None, reason, detail=None):
    async with conn.transaction():
        await conn.execute("SET LOCAL app.current_entity = '3'")
        await conn.execute("""
          INSERT INTO query_rejections
            (asked_by, channel, raw_question, classifier_slug, classifier_score,
             bound_params, reason, detail)
          VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
        """, asked_by, channel, raw_question, classifier_slug, classifier_score,
             json.dumps(bound_params) if bound_params is not None else None,
             reason, detail)


# ── Main ───────────────────────────────────────────────────────────────

async def pick_one(conn):
    async with conn.transaction():
        await conn.execute("SET LOCAL app.current_entity = '3'")
        row = await conn.fetchrow("""
          UPDATE bot_instructions
             SET picked_up_at = now(), picked_up_by = $1
           WHERE id = (
             SELECT id FROM bot_instructions
              WHERE lane='query' AND status='pending' AND picked_up_at IS NULL
              ORDER BY received_at ASC
              LIMIT 1
              FOR UPDATE SKIP LOCKED
           )
        RETURNING id, source_id, sender_email, from_user, raw_subject, raw_text, received_at
        """, RESPONDER_NAME)
        return row


async def finalize(conn, bi_id, *, status, resolution, needs_session=False):
    async with conn.transaction():
        await conn.execute("SET LOCAL app.current_entity = '3'")
        await conn.execute("""
          UPDATE bot_instructions
             SET status=$2, resolution=$3, resolved_at=now(),
                 needs_session = COALESCE(needs_session, false) OR $4
           WHERE id=$1
        """, bi_id, status, resolution, needs_session)


async def main():
    conn = await asyncpg.connect(PG_DSN_ADMIN)
    try:
        row = await pick_one(conn)
        if not row:
            return
        bi_id      = row["id"]
        sender     = (row["sender_email"] or "").lower()
        question   = (row["raw_text"] or "").strip() or (row["raw_subject"] or "").strip()
        subject_in = row["raw_subject"] or ""

        # Whitelist gate — fetch caller's realm at the same time so the slug
        # filter (R2) and any downstream RLS-scoped reads can be realm-aware.
        async with conn.transaction():
            await conn.execute("SET LOCAL app.current_entity = '3'")
            sender_realm = await conn.fetchval(
                "SELECT realm FROM bot_sender_whitelist WHERE LOWER(email)=$1 AND active", sender)
        # U119 — short-circuit approve/reject for WA outbound queue.
        # Lets Jo flip wa_outbound_queue rows via Telegram or email without
        # round-tripping through Claude.
        import re
        m_app = re.match(r'^\s*(approve|reject)\s+(\d+|all)\s*(.*)$', question, re.I)
        if m_app and sender_realm == 'owner':
            action = m_app.group(1).lower()
            target = m_app.group(2).lower()
            note   = m_app.group(3).strip() or None
            new_status = 'approved' if action == 'approve' else 'cancelled'
            async with conn.transaction():
                await conn.execute("SET LOCAL app.current_entity = '3'")
                if target == 'all':
                    rows = await conn.fetch("""
                        UPDATE wa_outbound_queue
                           SET status = $1, approved_at = NOW(),
                               approved_by = $2
                         WHERE status = 'pending_approval'
                       RETURNING id, target_label, body
                    """, new_status, sender)
                else:
                    rows = await conn.fetch("""
                        UPDATE wa_outbound_queue
                           SET status = $1, approved_at = NOW(),
                               approved_by = $2
                         WHERE id = $3 AND status = 'pending_approval'
                       RETURNING id, target_label, body
                    """, new_status, sender, int(target))
            count = len(rows)
            verb = 'approved' if action == 'approve' else 'cancelled'
            resolution = (f"{verb} {count} WA outbound row(s): " +
                          ", ".join(f"#{r['id']} → {r['target_label']}" for r in rows))
            await finalize(conn, bi_id, status='done', resolution=resolution)
            print(resolution)
            return

        if sender_realm is None:
            await log_rejection(conn, asked_by=sender or "unknown", channel="email",
                                raw_question=question, reason="other",
                                detail="sender not whitelisted")
            await finalize(conn, bi_id, status="rejected",
                           resolution=f"sender '{sender}' not whitelisted — silent reject")
            print(f"rejected bi#{bi_id} (non-whitelisted: {sender})")
            return

        # Load whitelist slugs as tools — realm-gated. OWNER sees all; WORK
        # and FAMILY callers only see slugs in their realm or 'shared'.
        slugs = await conn.fetch("""
          SELECT id, slug, display_name, description, intent_examples,
                 sql_template, param_schema, result_format
            FROM query_whitelist
           WHERE active=true AND approved_at IS NOT NULL
             AND ($1 = 'owner' OR realm = $1 OR realm = 'shared')
           ORDER BY id
        """, sender_realm)
        slugs_by_name = {r["slug"]: r for r in slugs}
        tools = [slug_to_tool(r) for r in slugs]

        ro_dsn = os.environ.get("PG_DSN_RO")
        if not ro_dsn:
            ro_pw = vault_get("postgres-roles")["homeai_readonly"]
            ro_dsn = f"postgresql://homeai_readonly:{ro_pw}@homeai-postgres:5432/homeai"
        ro_conn = await asyncpg.connect(ro_dsn)

        # Anthropic call loop with tool use
        api_key = vault_get("anthropic")["api_key"]
        client = anthropic.Anthropic(api_key=api_key)

        # System prompt + tool list are the same every call → mark them as
        # ephemeral cache so Anthropic re-uses the prefix across queries.
        # Saves ~80% on input cost when there's a cache hit (5 min TTL).
        system_blocks = [{
            "type": "text",
            "text": (
                "You are jolyboxbot, the Home AI assistant. The user is Jo, who runs a pub, "
                "an ice-cream sandwich bar, and an accommodation business. You answer business "
                "questions by calling the provided read-only data tools. NEVER invent figures. "
                "If no tool fits, say so plainly so the user knows you need a human session. "
                "Be terse — 1-3 short paragraphs max. Format numbers as £x,xxx where money."
            ),
            "cache_control": {"type": "ephemeral"},
        }]
        # Add cache marker on last tool — Anthropic's API caches everything up
        # to the marked block, so this caches the entire tool list too.
        if tools:
            tools[-1] = {**tools[-1], "cache_control": {"type": "ephemeral"}}
        messages = [{"role": "user", "content": f"Subject: {subject_in}\n\n{question}"}]

        final_text = None
        last_slug = None
        last_score = None
        last_bound = None
        last_reason = None
        last_detail = None

        # Accumulate token usage across the tool-use loop
        usage_total = {"in": 0, "out": 0, "cache_w": 0, "cache_r": 0}

        for _ in range(MAX_TOOL_ITERS):
            resp = client.messages.create(
                model=MODEL,
                max_tokens=1024,
                system=system_blocks,
                tools=tools,
                messages=messages,
            )
            u = getattr(resp, "usage", None)
            if u is not None:
                usage_total["in"]      += getattr(u, "input_tokens", 0) or 0
                usage_total["out"]     += getattr(u, "output_tokens", 0) or 0
                usage_total["cache_w"] += getattr(u, "cache_creation_input_tokens", 0) or 0
                usage_total["cache_r"] += getattr(u, "cache_read_input_tokens", 0) or 0
            if resp.stop_reason == "end_turn":
                # Collect text
                parts = [b.text for b in resp.content if b.type == "text"]
                final_text = "\n\n".join(p for p in parts if p).strip()
                break
            if resp.stop_reason != "tool_use":
                final_text = "(no answer produced)"
                break

            # Append assistant message verbatim, then run each tool_use
            messages.append({"role": "assistant", "content": [b.model_dump() for b in resp.content]})

            tool_results = []
            for block in resp.content:
                if block.type != "tool_use":
                    continue
                tname = block.name
                tinput = block.input or {}
                last_slug = tname
                last_bound = tinput
                slug_row = slugs_by_name.get(tname)
                if slug_row is None:
                    last_reason, last_detail = "unknown_slug", f"Haiku invented slug '{tname}'"
                    tool_results.append({
                        "type": "tool_result", "tool_use_id": block.id,
                        "is_error": True,
                        "content": f"error: unknown slug '{tname}'",
                    })
                    continue
                ok, bound_or_reason = validate_params(slug_row["param_schema"], tinput)
                if not ok:
                    last_reason, last_detail = bound_or_reason
                    tool_results.append({
                        "type": "tool_result", "tool_use_id": block.id,
                        "is_error": True,
                        "content": f"error: {last_reason} — {last_detail}",
                    })
                    continue
                try:
                    rows = await run_slug(ro_conn, slug_row, bound_or_reason, sender_realm)
                except Exception as e:
                    last_reason, last_detail = "runtime_error", str(e)[:300]
                    tool_results.append({
                        "type": "tool_result", "tool_use_id": block.id,
                        "is_error": True,
                        "content": f"error: runtime_error — {e}",
                    })
                    continue
                if not rows:
                    # Possibly RLS-blocked or just no data — log but still return empty result
                    last_reason = "rls_block" if "RLS" in (last_detail or "") else None
                tool_results.append({
                    "type": "tool_result", "tool_use_id": block.id,
                    "content": json.dumps(rows, default=str)[:6000],
                })

            messages.append({"role": "user", "content": tool_results})
        else:
            # Hit MAX_TOOL_ITERS without end_turn
            final_text = "(iteration cap reached — escalating to human)"

        await ro_conn.close()

        # Log Anthropic token usage (including prompt-cache stats) to ai_usage
        try:
            await conn.execute("""
                INSERT INTO ai_usage
                  (trace_id, task_type, model_used, tier,
                   prompt_tokens, completion_tokens,
                   cache_creation_tokens, cache_read_tokens,
                   service, realm, provider, cached)
                VALUES ($1, 'bot.responder', $2, 'cloud',
                        $3, $4, $5, $6, 'bot-responder', $7, 'anthropic', $8)
            """,
                None,  # trace_id is UUID; bot-responder doesn't generate one
                MODEL,
                usage_total["in"], usage_total["out"],
                usage_total["cache_w"], usage_total["cache_r"],
                sender_realm,
                bool(usage_total["cache_r"]))
        except Exception as e:
            print(f"[usage-log] failed: {e}", flush=True)

        if not final_text or "need" in final_text.lower() and "session" in final_text.lower() or final_text.startswith("("):
            # Escalation path
            await log_rejection(conn, asked_by=sender, channel="email",
                                raw_question=question, classifier_slug=last_slug,
                                bound_params=last_bound,
                                reason=last_reason or "other",
                                detail=last_detail or final_text)
            await finalize(conn, bi_id, status="pending",
                           resolution=f"needs human — {final_text or last_detail}",
                           needs_session=True)
            tg_send(f"⚠️  needs session: {subject_in[:80]} (bi#{bi_id})")
            print(f"escalated bi#{bi_id}")
            return

        # Send reply
        try:
            mid = email_reply(
                to=sender,
                subject=f"Re: {subject_in}" if not subject_in.lower().startswith("re:") else subject_in,
                body_text=final_text,
            )
            await finalize(conn, bi_id, status="done",
                           resolution=f"replied via email_id={mid}; slug={last_slug or 'n/a'}")
            print(f"replied bi#{bi_id}")
        except Exception as e:
            await finalize(conn, bi_id, status="pending",
                           resolution=f"send failed: {e}", needs_session=True)
            tg_send(f"❌ bot-responder send failed bi#{bi_id}: {e}")
            print(f"send failed bi#{bi_id}: {e}")

    finally:
        await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
