#!/bin/bash
# /home_ai/scripts/u36-reconciliation-explainer.sh
#
# Picks open reconciliation_flags rows without a Sonnet-generated description,
# pulls the linked bank_transaction + nearby invoice candidates, and asks
# Sonnet to write: hypothesis, suggested action, confidence. Writes back to
# `description`. NEVER auto-posts to Xero.
#
# Cron candidate: 0 20 * * *  (20:00 daily — runs before u29-daily-digest at 21:00
# so the digest can include freshly-explained flags).
#
# Cost-cap: LIMIT rows/run (default 20).
# Idempotent: skips rows where description IS NOT NULL.
#
# DORMANT until Pipeline 3 (Xero sync) unblocks and reconciliation_flags
# starts being populated. Script is safe to run with 0 candidates.

set -uo pipefail
LIMIT="${1:-20}"
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e LIMIT="$LIMIT" homeai-bot-responder python << 'PYEOF'
import os, json, urllib.request, asyncio, asyncpg
import anthropic

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN      = os.environ["PG_DSN"]
LIMIT       = int(os.environ.get("LIMIT", "20"))
MODEL       = "claude-sonnet-4-6"
MAX_MONTHLY_GBP = 5.0


def vault_get(p):
    r = urllib.request.Request(f"http://vault:8200/v1/secret/data/{p}",
                                headers={"X-Vault-Token": VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(r, timeout=5).read())["data"]["data"]


# U38: schema-constrained tool use.
SYSTEM_BLOCKS = [{
    "type": "text",
    "text": (
        "You are a UK small-business bookkeeping assistant. For each reconciliation flag, you "
        "see (a) the bank transaction details, and (b) nearby vendor invoices from the same week "
        "with similar amounts. Write a short hypothesis, a one-line suggested action, a confidence "
        "0-1, and (if obvious) the matching invoice id. Be specific. Never invent figures. "
        "Call the record_hypothesis tool — never produce free text."
    ),
    "cache_control": {"type": "ephemeral"},
}]

HYPOTHESIS_TOOL = {
    "name": "record_hypothesis",
    "description": "Record a structured reconciliation hypothesis for an open flag.",
    "input_schema": {
        "type": "object",
        "properties": {
            "hypothesis":         {"type": "string", "maxLength": 600},
            "suggested_action":   {"type": "string", "maxLength": 300},
            "confidence":         {"type": "number", "minimum": 0, "maximum": 1},
            "candidate_match_id": {"type": ["integer", "null"]}
        },
        "required": ["hypothesis", "suggested_action", "confidence"]
    }
}
SCHEMA_VERSION = "reconciliation-explainer.schema.json@U38"


async def main():
    api_key = vault_get("anthropic")["api_key"]
    client  = anthropic.Anthropic(api_key=api_key)
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity='all'")
    # R6: reconciliation flags can be cross-realm — explainer runs as OWNER.
    await conn.execute("SET app.current_realm = 'owner'")

    # Cost guard
    spent_this_month = await conn.fetchval("""
      SELECT COALESCE(SUM((prompt_tokens * 3.0 + completion_tokens * 15.0) / 1000000.0), 0)
        FROM ai_usage
       WHERE task_type = 'reconciliation_explainer'
         AND timestamp >= date_trunc('month', now())
    """)
    if spent_this_month and float(spent_this_month) > MAX_MONTHLY_GBP:
        print(f"monthly cap ${MAX_MONTHLY_GBP} hit; spent_this_month=${float(spent_this_month):.2f} — skipping")
        await conn.close()
        return

    rows = await conn.fetch("""
      SELECT f.id, f.flag_type, f.bank_transaction_id, f.xero_transaction_id, f.entity_id,
             b.transaction_date, b.amount, b.description AS bank_desc, b.reference
        FROM reconciliation_flags f
        LEFT JOIN bank_transactions b ON b.id = f.bank_transaction_id
       WHERE f.status = 'open'
         AND f.description IS NULL
       ORDER BY f.created_at DESC
       LIMIT $1
    """, LIMIT)
    print(f"candidates: {len(rows)}")
    if not rows:
        print("(no open un-explained flags — likely P3 Xero still parked)")
        await conn.close()
        return

    explained = 0
    total_in = total_out = total_cache = 0
    for f in rows:
        # Nearby vendor invoices: same entity, same week, within ±10% amount
        candidates = await conn.fetch("""
          SELECT id, vendor_domain, subject, gross_amount, invoice_date, delivery_date
            FROM vendor_invoice_inbox
           WHERE entity_id = $1
             AND is_statement = false
             AND ABS(COALESCE(gross_amount, 0) - $2) <= GREATEST(0.10 * ABS($2), 1.00)
             AND (delivery_date BETWEEN $3 - 7 AND $3 + 7
                  OR invoice_date BETWEEN $3 - 7 AND $3 + 7)
           ORDER BY ABS(COALESCE(gross_amount, 0) - $2) ASC
           LIMIT 5
        """, f["entity_id"] or 1, float(f["amount"] or 0), f["transaction_date"])

        payload = {
            "flag_type":     f["flag_type"],
            "bank":          {"date": str(f["transaction_date"]) if f["transaction_date"] else None,
                              "amount": float(f["amount"]) if f["amount"] is not None else None,
                              "description": f["bank_desc"], "reference": f["reference"]},
            "candidates":    [dict(c) for c in candidates],
        }
        def to_json(v):
            if hasattr(v, "isoformat"): return v.isoformat()
            if hasattr(v, "to_eng_string"): return str(v)
            return v
        payload_str = json.dumps(payload, default=to_json)

        try:
            resp = client.messages.create(
                model=MODEL, max_tokens=400, system=SYSTEM_BLOCKS,
                tools=[HYPOTHESIS_TOOL],
                tool_choice={"type": "tool", "name": "record_hypothesis"},
                messages=[{"role": "user", "content": payload_str}],
            )
        except Exception as e:
            print(f"  flag #{f['id']} api err: {str(e)[:120]}")
            continue
        total_in    += resp.usage.input_tokens
        total_out   += resp.usage.output_tokens
        total_cache += getattr(resp.usage, "cache_read_input_tokens", 0) or 0

        tool_uses = [b for b in resp.content if b.type == "tool_use"]
        if not tool_uses:
            continue
        d = tool_uses[0].input
        desc = f"{d.get('hypothesis','')}\n\nSuggested action: {d.get('suggested_action','')}\n(confidence {d.get('confidence', 0):.2f})"
        if d.get("candidate_match_id"):
            desc += f"\nCandidate vendor invoice id: {d['candidate_match_id']}"
        await conn.execute("UPDATE reconciliation_flags SET description=$2 WHERE id=$1",
                           f["id"], desc[:2000])
        explained += 1

    try:
        await conn.execute("""
          INSERT INTO ai_usage (task_type, model_used, tier, prompt_tokens, completion_tokens, cached, provider)
          VALUES ('reconciliation_explainer', $1, 'cloud', $2, $3, $4, 'anthropic')
        """, MODEL, total_in, total_out, total_cache > 0)
    except Exception: pass

    print(f"explained={explained}  in_tok={total_in} (cached={total_cache})  out_tok={total_out}")
    await conn.close()

asyncio.run(main())
PYEOF
