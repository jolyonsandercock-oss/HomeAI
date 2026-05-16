#!/usr/bin/env bash
# u68-doc-classify.sh — Layer 3 classifier. Runs every 5 min.
#
# Picks documents that:
#   - have OCR text (ocr_chars > 50)
#   - have linked_table IS NULL
#   - have no documents_classification_queue row yet
# Sends OCR + title to Haiku 4.5 with a tool-use schema. The output captures
# doc_type, suggested_link_table, suggested_link_id_hint, confidence, summary.
#
#   - confidence ≥ 0.85 → auto-apply (UPDATE documents.linked_*)
#   - confidence 0.55-0.85 → status='needs_review'
#   - confidence < 0.55 → status='rejected' (still in queue for batch ping)
#
# Idempotent: UNIQUE(document_id) on the queue prevents re-classifying.

set -euo pipefail

LIMIT="${LIMIT:-20}"  # max docs per run

VAULT_TOKEN=$(docker inspect homeai-bot-responder --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PG_PW=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -field=password secret/postgres)
ANTH_KEY=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -field=api_key secret/anthropic)
PG_DSN="postgresql://postgres:${PG_PW}@homeai-postgres:5432/homeai"

docker exec -i -e PG_DSN="$PG_DSN" -e ANTHROPIC_API_KEY="$ANTH_KEY" -e LIMIT="$LIMIT" \
    homeai-bot-responder python /dev/stdin <<'PYEOF'
import os, json, asyncio, re
import asyncpg, httpx

PG_DSN  = os.environ["PG_DSN"]
KEY     = os.environ["ANTHROPIC_API_KEY"]
LIMIT   = int(os.environ.get("LIMIT", 20))
MODEL   = "claude-haiku-4-5-20251001"

SYSTEM = (
    "You classify scanned documents for Jo's home/business archive. "
    "Jo runs a pub (Atlantic Road Trading), a property company (Atlantic Road "
    "Estates) with rental properties, and has personal/family affairs. "
    "Given the OCR text of one document, output:\n"
    "  doc_type — one of: mot_certificate, vehicle_v5c, vehicle_insurance, "
    "    road_tax, mortgage_statement, bank_statement, credit_card_statement, "
    "    council_tax, water_bill, gas_bill, electric_bill, broadband_bill, "
    "    invoice, receipt, hmrc_letter, insurance_policy, school_letter, "
    "    medical, legal_contract, dvla_correspondence, other\n"
    "  suggested_link_table — one of: vehicles, properties, bank_accounts, "
    "    mortgage_accounts, entities, children, none\n"
    "  suggested_link_hint — the specific identifier to look up (plate, "
    "    postcode, sort+account#, lender+ref, UTR, name). Empty if uncertain.\n"
    "  confidence — your honest 0.0-1.0 confidence in BOTH doc_type AND "
    "    suggested_link_table being correct (the conjunction).\n"
    "  summary — one tight line describing the document (60 chars max)."
)

TOOL = {
    "name": "classify_document",
    "description": "Emit the classification for the given OCR text.",
    "input_schema": {
        "type": "object",
        "properties": {
            "doc_type":              {"type":"string"},
            "suggested_link_table":  {"type":"string"},
            "suggested_link_hint":   {"type":"string"},
            "confidence":            {"type":"number"},
            "summary":               {"type":"string"},
        },
        "required": ["doc_type","suggested_link_table","confidence","summary"],
    },
}

async def log_ai_usage(conn, model, usage, *, service, trace):
    if not usage:
        return
    try:
        await conn.execute("""
            INSERT INTO ai_usage
              (trace_id, task_type, model_used, tier,
               prompt_tokens, completion_tokens,
               cache_creation_tokens, cache_read_tokens,
               service, realm, provider, cached)
            VALUES ($1, 'doc.classify', $2, 'cloud',
                    $3, $4, $5, $6, $7, 'owner', 'anthropic', $8)
        """, trace, model,
             usage.get("input_tokens", 0) or 0,
             usage.get("output_tokens", 0) or 0,
             usage.get("cache_creation_input_tokens", 0) or 0,
             usage.get("cache_read_input_tokens", 0) or 0,
             service,
             bool(usage.get("cache_read_input_tokens")))
    except Exception as e:
        print(f"[usage-log] {service}: {e}")


async def classify_one(client, ocr_text, title):
    text = (ocr_text or "")[:6000]
    payload = {
        "model": MODEL, "max_tokens": 400,
        # cache stable system + tool — note Haiku 2048-token min may mean
        # this is a no-op today; harmless and ready for prompt growth.
        "system": [{"type": "text", "text": SYSTEM,
                    "cache_control": {"type": "ephemeral"}}],
        "tools": [{**TOOL, "cache_control": {"type": "ephemeral"}}],
        "tool_choice": {"type":"tool","name":"classify_document"},
        "messages": [{"role":"user","content":
            f"Title: {title}\n\nOCR text:\n{text}"}],
    }
    r = await client.post(
        "https://api.anthropic.com/v1/messages",
        headers={"x-api-key": KEY, "anthropic-version":"2023-06-01",
                 "content-type":"application/json"},
        json=payload, timeout=60)
    if r.status_code != 200:
        return None, f"HTTP {r.status_code}: {r.text[:200]}", None
    j = r.json()
    for b in j.get("content") or []:
        if b.get("type") == "tool_use":
            return b.get("input"), None, j.get("usage")
    return None, "no tool_use block", j.get("usage")

async def resolve_link_id(conn, table, hint):
    """Best-effort: convert the model's hint into a real foreign key id.
    Returns (link_id, entity_id) or (None, None)."""
    if not hint or not table or table == "none":
        return None, None
    h = hint.strip().upper()
    if table == "vehicles":
        # plate match, OCR-tolerant
        cleaned = re.sub(r"[^A-Z0-9]", "", h)
        for fixed in (cleaned, cleaned.replace("I","1").replace("O","0").replace("S","5").replace("B","8")):
            v = await conn.fetchrow(
                "SELECT id, entity_id FROM vehicles WHERE upper(replace(registration,' ','')) = $1",
                fixed)
            if v: return v["id"], v["entity_id"]
    elif table == "properties":
        pc = re.sub(r"[^A-Z0-9]", "", h)
        v = await conn.fetchrow(
            "SELECT id, entity_id FROM properties WHERE upper(replace(coalesce(postcode,''),' ','')) = $1",
            pc)
        if v: return v["id"], v["entity_id"]
    elif table == "bank_accounts":
        # try sort+account or last-4
        digits = re.sub(r"\D", "", h)
        if len(digits) >= 14:
            sc, acct = digits[:6], digits[6:14]
            v = await conn.fetchrow("""
                SELECT id, entity_id FROM bank_accounts
                 WHERE replace(coalesce(sort_code,''),'-','') = $1
                   AND replace(coalesce(account_number,''),' ','') = $2
            """, sc, acct)
            if v: return v["id"], v["entity_id"]
        if len(digits) >= 4:
            last4 = digits[-4:]
            v = await conn.fetchrow("""
                SELECT id, entity_id FROM bank_accounts
                 WHERE right(replace(coalesce(account_number,''),' ',''), 4) = $1
            """, last4)
            if v: return v["id"], v["entity_id"]
    elif table == "mortgage_accounts":
        ref = re.sub(r"\D", "", h)
        if ref:
            v = await conn.fetchrow("""
                SELECT id, borrower_entity_id AS entity_id FROM mortgage_accounts
                 WHERE replace(coalesce(account_ref,''),'-','') = $1
            """, ref)
            if v: return v["id"], v["entity_id"]
    elif table == "entities":
        v = await conn.fetchrow(
            "SELECT id FROM entities WHERE utr = $1 OR replace(coalesce(vat_number,''),' ','') LIKE $2",
            re.sub(r"\D","", h), f"%{re.sub(r'\\D','', h)}")
        if v: return v["id"], v["id"]
    elif table == "children":
        # case-insensitive name match
        v = await conn.fetchrow(
            "SELECT id FROM children WHERE name ILIKE $1 LIMIT 1",
            f"%{hint}%")
        if v: return v["id"], None
    return None, None

async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity = 'all'")
    await conn.execute("SET app.current_realm  = 'owner'")

    rows = await conn.fetch("""
        SELECT d.id, d.title, d.ocr_text
          FROM documents d
          LEFT JOIN documents_classification_queue q ON q.document_id = d.id
         WHERE d.linked_table IS NULL
           AND LENGTH(coalesce(d.ocr_text,'')) > 50
           AND q.id IS NULL
         ORDER BY d.created_at DESC
         LIMIT $1
    """, LIMIT)
    print(f"{len(rows)} candidate docs for Layer 3 classify")

    n_auto = n_review = n_reject = n_fail = 0
    async with httpx.AsyncClient() as client:
        for row in rows:
            doc_id = row["id"]
            inp, err, usage = await classify_one(client, row["ocr_text"], row["title"])
            if usage:
                await log_ai_usage(conn, MODEL, usage,
                                   service="u68-doc-classify", trace=f"doc#{doc_id}")
            if err:
                print(f"  doc#{doc_id} err: {err}")
                n_fail += 1
                continue

            doc_type   = (inp.get("doc_type") or "other").strip()
            link_table = (inp.get("suggested_link_table") or "none").strip()
            link_hint  = (inp.get("suggested_link_hint") or "").strip()
            confidence = float(inp.get("confidence") or 0)
            summary    = (inp.get("summary") or "")[:500]

            link_id, ent_id = await resolve_link_id(conn, link_table, link_hint) \
                              if link_table != "none" else (None, None)

            # Decide outcome
            auto_apply = (confidence >= 0.85 and link_id is not None)
            status = ("auto_applied" if auto_apply else
                      ("needs_review" if confidence >= 0.55 else "rejected"))

            async with conn.transaction():
                await conn.execute("SET LOCAL app.current_entity = 'all'")
                await conn.execute("SELECT home_ai.set_realm('owner')")
                # Insert queue row
                await conn.execute("""
                    INSERT INTO documents_classification_queue
                        (document_id, status, suggested_doc_type,
                         suggested_link_table, suggested_link_id,
                         suggested_link_hint, confidence, summary,
                         model_used, classified_at)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, NOW())
                    ON CONFLICT (document_id) DO UPDATE
                       SET status=EXCLUDED.status,
                           suggested_doc_type=EXCLUDED.suggested_doc_type,
                           suggested_link_table=EXCLUDED.suggested_link_table,
                           suggested_link_id=EXCLUDED.suggested_link_id,
                           suggested_link_hint=EXCLUDED.suggested_link_hint,
                           confidence=EXCLUDED.confidence,
                           summary=EXCLUDED.summary,
                           model_used=EXCLUDED.model_used,
                           classified_at=NOW()
                """, doc_id, status, doc_type, link_table, link_id, link_hint,
                     confidence, summary, "haiku-4-5")

                if auto_apply:
                    await conn.execute("""
                        UPDATE documents
                           SET linked_table=$2, linked_id=$3,
                               linked_by=$4,
                               category=COALESCE(NULLIF(category,''), $5),
                               entity_id=COALESCE(entity_id, $6)
                         WHERE id=$1 AND linked_table IS NULL
                    """, doc_id, link_table, link_id,
                         f"ai:haiku:{doc_type}", doc_type, ent_id)
                    n_auto += 1
                elif status == "needs_review":
                    n_review += 1
                else:
                    n_reject += 1
            print(f"  doc#{doc_id:>3} → {doc_type:25} → {link_table}#{link_id} "
                  f"conf={confidence:.2f} status={status}")

    print(f"\nSummary: auto_applied={n_auto} needs_review={n_review} "
          f"rejected={n_reject} failed={n_fail}")
    await conn.close()

asyncio.run(main())
PYEOF
