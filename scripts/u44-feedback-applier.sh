#!/bin/bash
# /home_ai/scripts/u44-feedback-applier.sh
#
# Reads invoice_feedback rows where applied_at IS NULL AND rejected_at IS NULL,
# classifies each via Sonnet tool-use into one of 5 action types, writes the
# structured proposal back. Never auto-applies — Jo approves via Action Queue.
#
# Cron: 30 21 * * *  (daily 21:30, before u29-daily-digest at 21:00... actually
# after it — keep at 21:30 so the next digest picks up the proposals.)

set -uo pipefail
LIMIT="${1:-20}"
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e LIMIT="$LIMIT" homeai-bot-responder python <<'PYEOF'
import os, json, urllib.request, asyncio, asyncpg
import anthropic

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN      = os.environ["PG_DSN"]
LIMIT       = int(os.environ.get("LIMIT", "20"))
MODEL       = "claude-sonnet-4-6"


def vault_get(p):
    r = urllib.request.Request(f"http://vault:8200/v1/secret/data/{p}",
                                headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(r, timeout=5).read())["data"]["data"]


SYSTEM_BLOCKS = [{
    "type": "text",
    "text": (
        "You classify Jo's plain-text feedback about a vendor invoice into ONE structured action. "
        "Jo is teaching the system how this invoice (and similar ones from this vendor) should be "
        "handled going forward.\n\n"
        "Action types:\n"
        "  - flag_as_statement: this is a statement of account, not an invoice. Exclude from cost totals.\n"
        "  - flag_as_ignored:   ignore this row entirely (notification email, duplicate, refund, etc).\n"
        "  - recategorise:      change this invoice's vendor_category (also potentially apply to future invoices from same vendor).\n"
        "  - add_vendor_rule:   forward-looking — add a new domain pattern → category rule for the vendor.\n"
        "  - unclear:           feedback is ambiguous; flag for human review.\n"
        "\n"
        "Use add_vendor_rule when Jo says something like 'all invoices from <X> are <category>'. "
        "Use recategorise when it's specific to this one invoice. "
        "Use unclear if the feedback doesn't fit a structured action.\n"
        "\n"
        "Categories available: wet_purchase, dry_purchase, cafe_stock, repairs_maintenance, utilities, software, other.\n"
        "\n"
        "Call the record_action tool — never produce free text."
    ),
    "cache_control": {"type": "ephemeral"},
}]

ACTION_TOOL = {
    "name": "record_action",
    "description": "Record the structured action interpretation of Jo's feedback.",
    "input_schema": {
        "type": "object",
        "properties": {
            "action_type": {
                "type": "string",
                "enum": ["flag_as_statement", "flag_as_ignored", "recategorise", "add_vendor_rule", "unclear"]
            },
            "target_category": {
                "type": ["string", "null"],
                "enum": ["wet_purchase","dry_purchase","cafe_stock","repairs_maintenance","utilities","software","other",None]
            },
            "vendor_pattern": {
                "type": ["string", "null"],
                "description": "Regex domain pattern when action_type=add_vendor_rule (e.g. 'experience.?wine')."
            },
            "vendor_display": {
                "type": ["string", "null"],
                "description": "Human-readable vendor name for vendor_category_rules row."
            },
            "rationale": {
                "type": "string",
                "maxLength": 400,
                "description": "Short explanation of why this action."
            },
            "confidence": {
                "type": "number", "minimum": 0, "maximum": 1
            }
        },
        "required": ["action_type", "rationale", "confidence"]
    }
}


async def main():
    api_key = vault_get("anthropic")["api_key"]
    client  = anthropic.Anthropic(api_key=api_key)
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity='1'")

    rows = await conn.fetch("""
      SELECT f.id AS feedback_id, f.invoice_id, f.feedback_text,
             v.vendor_domain, v.vendor_name, v.subject, v.vendor_category, v.is_statement
        FROM invoice_feedback f
        LEFT JOIN vendor_invoice_inbox v ON v.id = f.invoice_id
       WHERE f.applied_at IS NULL AND f.rejected_at IS NULL AND f.ai_proposal IS NULL
       ORDER BY f.created_at
       LIMIT $1
    """, LIMIT)

    print(f"pending feedback rows: {len(rows)}")
    if not rows:
        await conn.close()
        return

    processed = 0
    for r in rows:
        user_msg = (
            f"Invoice id={r['invoice_id']}\n"
            f"Vendor: {r['vendor_name'] or r['vendor_domain']}\n"
            f"Current category: {r['vendor_category']} (is_statement={r['is_statement']})\n"
            f"Subject: {r['subject']}\n\n"
            f"Jo's feedback: {r['feedback_text']}"
        )
        try:
            resp = client.messages.create(
                model=MODEL, max_tokens=400, system=SYSTEM_BLOCKS,
                tools=[ACTION_TOOL],
                tool_choice={"type": "tool", "name": "record_action"},
                messages=[{"role": "user", "content": user_msg}],
            )
        except Exception as e:
            print(f"  feedback {r['feedback_id']} api err: {str(e)[:120]}")
            continue
        tool_uses = [b for b in resp.content if b.type == "tool_use"]
        if not tool_uses:
            continue
        proposal = tool_uses[0].input
        await conn.execute("""
          UPDATE invoice_feedback SET ai_proposal=$2 WHERE id=$1
        """, r["feedback_id"], json.dumps(proposal))

        # ai_usage
        try:
            await conn.execute("""
              INSERT INTO ai_usage (task_type, model_used, tier, prompt_tokens, completion_tokens, cached, provider)
              VALUES ('invoice_feedback_applier', $1, 'cloud', $2, $3, $4, 'anthropic')
            """, MODEL, resp.usage.input_tokens, resp.usage.output_tokens,
                 (getattr(resp.usage, "cache_read_input_tokens", 0) or 0) > 0)
        except Exception: pass
        processed += 1
        print(f"  ✓ feedback {r['feedback_id']} → {proposal.get('action_type')} (conf {proposal.get('confidence')})")

    await conn.close()
    print(f"\ndone. processed={processed}")

asyncio.run(main())
PYEOF
