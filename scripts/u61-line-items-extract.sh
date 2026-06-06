#!/usr/bin/env bash
#
# u61-line-items-extract.sh — backfill vendor_invoice_lines for every
# vendor_invoice_inbox row with has_pdf=true.
#
# Pipeline per invoice:
#   1. Pull PDF text via pdfplumber service.
#   2. Call Haiku 4.5 with tool-use schema (see U61 T0 bench).
#   3. Validate: sum(line_net) within £0.05 or 1% of (invoice_total / 1.2 for
#      VAT-rated rows, else invoice_total). On fail, retry once with Sonnet 4.6.
#   4. Insert into vendor_invoice_lines. Try trigram match to product_canonical
#      via product_alias; set canonical_id if confidence > 0.6.
#   5. Mark row in vendor_invoice_inbox.lines_extracted_at.
#
# Idempotent: skips invoices with rows already in vendor_invoice_lines.
# Run with INVOICE_IDS="142 152" to test on a subset.

set -euo pipefail

VT=$(docker inspect homeai-bot-responder --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PG_PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/postgres)
ANTH_KEY=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=api_key secret/anthropic)
PG_DSN="postgresql://postgres:${PG_PW}@homeai-postgres:5432/homeai"
unset VT PG_PW

INVOICE_IDS="${INVOICE_IDS:-}"
DRY_RUN="${DRY_RUN:-0}"

docker exec -i -e PG_DSN="$PG_DSN" -e ANTHROPIC_API_KEY="$ANTH_KEY" \
    -e INVOICE_IDS="$INVOICE_IDS" -e DRY_RUN="$DRY_RUN" \
    homeai-bot-responder python -u <<'PYEOF'
import os, json, asyncio, hashlib, re
from pathlib import Path
import asyncpg, httpx, claude_call

PG_DSN     = os.environ["PG_DSN"]
ANTH_KEY   = os.environ["ANTHROPIC_API_KEY"]
INVOICE_IDS = os.environ.get("INVOICE_IDS", "").strip()
DRY_RUN    = os.environ.get("DRY_RUN", "0") == "1"

MODEL_HAIKU  = "claude-haiku-4-5-20251001"
MODEL_SONNET = "claude-sonnet-4-6"
PDF_SVC      = "http://homeai-pdfplumber:8003/extract-pdf"

SYSTEM = (
    "You are an invoice line-item extractor for a UK pub/restaurant business. "
    "Given the raw OCR/pdfplumber text of a single invoice, extract every "
    "PURCHASED LINE ITEM. Do NOT include header rows, totals, VAT summary "
    "rows, payment-instruction text, or signature blocks. For each line "
    "return: description (clean text — keep product name + size/units), "
    "qty (numeric), unit_price (numeric, GBP, the per-unit net price), "
    "line_net (numeric, GBP, the line subtotal before VAT), and vat_rate "
    "(0.0 / 0.05 / 0.20)."
)

TOOL_SCHEMA = {
    "type": "object",
    "properties": {
        "lines": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "description": {"type": "string"},
                    "qty":         {"type": "number"},
                    "unit_price":  {"type": "number"},
                    "line_net":    {"type": "number"},
                    "vat_rate":    {"type": "number"}
                },
                "required": ["description", "qty", "line_net"]
            }
        }
    },
    "required": ["lines"]
}

async def log_ai_usage(conn, model, usage, *, service, trace):
    """Write Anthropic usage (including prompt-cache stats) to ai_usage.
    Silent on failure — observability shouldn't block extraction.
    trace_id is UUID — passing arbitrary strings was spamming the log."""
    if not usage:
        return
    try:
        await conn.execute("""
            INSERT INTO ai_usage
              (trace_id, task_type, model_used, tier,
               prompt_tokens, completion_tokens,
               cache_creation_tokens, cache_read_tokens,
               service, realm, provider, cached)
            VALUES (NULL, 'invoice.line_items', $1, 'cloud',
                    $2, $3, $4, $5, $6, 'work', 'anthropic', $7)
        """, model,
             usage.get("input_tokens", 0) or 0,
             usage.get("output_tokens", 0) or 0,
             usage.get("cache_creation_input_tokens", 0) or 0,
             usage.get("cache_read_input_tokens", 0) or 0,
             service,
             bool(usage.get("cache_read_input_tokens")))
    except Exception as e:
        print(f"[usage-log] {service}: {e}")


async def call_model(client, model, text):
    payload = {
        "model": model,
        "max_tokens": 2048,
        # System + tool are stable across all invoices → cache. Below the
        # 2048-token Haiku minimum on its own, but the marker is harmless
        # and kicks in for Sonnet escalations and any future prompt growth.
        "system": [{"type": "text", "text": SYSTEM,
                    "cache_control": {"type": "ephemeral"}}],
        "tools": [{
            "name": "record_line_items",
            "description": "Record every line item extracted from the invoice.",
            "input_schema": TOOL_SCHEMA,
            "cache_control": {"type": "ephemeral"},
        }],
        "tool_choice": {"type": "tool", "name": "record_line_items"},
        "messages": [{"role": "user", "content": f"Invoice text:\n\n{text}"}],
    }
    # U245: retry/cooldown on 529/overloaded via shared helper (baked into
    # bot-responder image as /app/claude_call.py). client is still used for the
    # pdfplumber call in extract_pdf_text; the Anthropic call goes via the helper.
    try:
        j = await claude_call.claude_messages_async(payload, api_key=ANTH_KEY)
    except Exception as e:
        return None, f"claude error: {str(e)[:200]}", None
    for b in j.get("content") or []:
        if b.get("type") == "tool_use":
            return b["input"], None, j.get("usage")
    return None, "no tool_use block", j.get("usage")

async def extract_pdf_text(client, pdf_path):
    with open(pdf_path, "rb") as f:
        r = await client.post(PDF_SVC,
                              files={"file": (os.path.basename(pdf_path), f, "application/pdf")},
                              timeout=60)
    r.raise_for_status()
    return r.json()["text"]

def validate(extracted, invoice_total_inc_vat):
    """Return (ok, sum_net, expected_net). Tolerance: 1% or £0.05, whichever larger."""
    if not extracted or not isinstance(extracted, dict):
        return False, 0.0, 0.0
    lines = extracted.get("lines")
    if not isinstance(lines, list) or not lines:
        return False, 0.0, 0.0
    sum_net = 0.0
    sum_gross_proxy = 0.0
    for ln in lines:
        if not isinstance(ln, dict):
            return False, 0.0, 0.0
        try:
            net = float(ln.get("line_net", 0) or 0)
            v   = float(ln.get("vat_rate", 0) or 0)
        except (TypeError, ValueError):
            return False, 0.0, 0.0
        sum_net += net
        sum_gross_proxy += net * (1 + v)
    if invoice_total_inc_vat is None:
        return True, sum_net, sum_net  # no anchor → accept
    inv = float(invoice_total_inc_vat)
    tol = max(0.05, inv * 0.01)
    return abs(sum_gross_proxy - inv) <= tol, sum_net, sum_gross_proxy

async def insert_lines(conn, invoice_id, realm, lines, model_used, confidence):
    if DRY_RUN:
        return len(lines)
    inserted = 0
    for i, ln in enumerate(lines, start=1):
        if not isinstance(ln, dict):
            continue
        try:
            qty   = float(ln.get("qty", 0))
            up    = ln.get("unit_price")
            net   = float(ln.get("line_net", 0))
            vat_r = float(ln.get("vat_rate", 0))
            line_vat   = round(net * vat_r, 2)
            line_gross = round(net + line_vat, 2)
            desc = (ln.get("description") or "").strip()[:500]

            # Trigram match to canonical
            canonical_id = await conn.fetchval("""
                SELECT pc.id FROM product_canonical pc
                 WHERE similarity(pc.name, $1) > 0.45
                 ORDER BY similarity(pc.name, $1) DESC LIMIT 1
            """, desc)

            await conn.execute("""
                INSERT INTO vendor_invoice_lines
                    (invoice_id, line_no, description, qty, unit_price,
                     line_net, line_vat, line_gross, raw_payload,
                     canonical_id, extracted_by, extraction_confidence, realm)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10, $11, $12, $13)
                ON CONFLICT (invoice_id, line_no) DO NOTHING
            """,
                invoice_id, i, desc, qty, up, net, line_vat, line_gross,
                json.dumps(ln), canonical_id, model_used, confidence, realm)
            inserted += 1
        except Exception as e:
            print(f"    line {i} insert failed: {e}")
    return inserted

async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.fetchval("SELECT set_config('app.current_entity', 'all',   false)")
    await conn.fetchval("SELECT set_config('app.current_realm',  'owner', false)")

    # Pick targets. has_pdf=true alone is too loose — u95 harvested 8k+ rows
    # tagged has_pdf=true but only the ~1.8k where u49 has actually downloaded
    # the attachment have a file on disk. Restrict to rows with pdf_local_path
    # set; the 404 storm in earlier runs was wasting cycles on rows where
    # the PDF was never fetched.
    # Skip rows we've already marked duplicate (V115 content dedupe) or
    # ignored (V112 noise-sender filter). Without these, u61 wastes Haiku
    # calls on rows that won't contribute to any downstream calculation.
    where = ("WHERE vii.has_pdf=true AND vii.pdf_local_path IS NOT NULL "
             "AND vii.status NOT IN ('duplicate', 'ignored')")
    args = []
    if INVOICE_IDS:
        ids = [int(x) for x in re.split(r"[\s,]+", INVOICE_IDS) if x]
        where += " AND vii.id = ANY($1::int[])"
        args = [ids]

    targets = await conn.fetch(f"""
        SELECT vii.id, vii.realm, vii.amount_seen
          FROM vendor_invoice_inbox vii
          LEFT JOIN (SELECT invoice_id, COUNT(*) AS n FROM vendor_invoice_lines GROUP BY 1) c
                 ON c.invoice_id = vii.id
         {where}
           AND (c.n IS NULL OR c.n = 0)
         ORDER BY vii.invoice_date NULLS LAST
    """, *args)

    print(f"Targets: {len(targets)} invoice(s) need line-item extraction.")
    if not targets:
        await conn.close()
        return

    stats = {"haiku_ok": 0, "sonnet_rescue": 0, "fail": 0, "total_lines": 0,
             "haiku_in_tok": 0, "haiku_out_tok": 0,
             "sonnet_in_tok": 0, "sonnet_out_tok": 0}

    async with httpx.AsyncClient(timeout=120) as client:
        for row in targets:
            inv_id = row["id"]
            realm  = row["realm"]
            inv_total = row["amount_seen"]
            pdf_path = f"/home_ai/data/invoice-pdfs/{inv_id}.pdf"
            # bot-responder doesn't have /home_ai bind-mounted; we use the
            # pdfplumber service which we send the file to from a copy.
            host_pdf = f"/tmp/u61-extract-{inv_id}.pdf"
            # Copy via docker cp host-side would be cleaner; here we trust the
            # pdfplumber svc has its own copy via the shared volume on the host.
            try:
                # Try fetching directly: pdfplumber has the file via volume?
                # If not, we'd need a docker cp dance. For now skip if missing.
                text = None
                # The pdfplumber service is fed via uploads — we don't have a
                # filesystem path inside this container that maps to the host
                # invoice-pdfs dir. Use the dashboard's /api/invoice/{id}/pdf
                # endpoint which streams the file from disk.
                r = await client.get(
                    f"http://homeai-build-dashboard:8090/api/invoice/{inv_id}/pdf",
                    headers={"X-Realm": "owner"}, timeout=20)
                if r.status_code != 200:
                    print(f"  #{inv_id}: cannot fetch PDF ({r.status_code})")
                    stats["fail"] += 1
                    continue
                # Push to pdfplumber for text extraction.
                up = await client.post(PDF_SVC,
                    files={"file": (f"{inv_id}.pdf", r.content, "application/pdf")},
                    timeout=60)
                up.raise_for_status()
                text = up.json()["text"]

                # U84 V108: cache the OCR text on the invoice row so the
                # body-aware site classifier (MAL125 → cafe / TOM106 → pub)
                # can fire on the trigger. Without this, every new u61 run
                # leaves pdf_text_extracted NULL and new invoices never get
                # auto-classified beyond what email body + vendor rules can do.
                # Truncate to 100KB to be safe against giant statements.
                try:
                    await conn.execute("""
                        UPDATE vendor_invoice_inbox
                           SET pdf_text_extracted = $1,
                               pdf_text_extracted_at = now()
                         WHERE id = $2
                           AND (pdf_text_extracted IS NULL
                                OR pdf_text_extracted_at < now() - INTERVAL '30 days')
                    """, (text or "")[:100_000], inv_id)
                except Exception as _e:
                    # Cache failure must not break extraction.
                    print(f"  #{inv_id}: pdf_text cache write failed: {_e}")
            except Exception as e:
                print(f"  #{inv_id}: text fetch failed: {e}")
                stats["fail"] += 1
                continue

            # Haiku pass.
            extracted, err, usage = await call_model(client, MODEL_HAIKU, text)
            if usage:
                stats["haiku_in_tok"]  += usage.get("input_tokens", 0)
                stats["haiku_out_tok"] += usage.get("output_tokens", 0)
                await log_ai_usage(conn, MODEL_HAIKU, usage,
                                   service="u61-line-items", trace=f"inv#{inv_id}")
            model_used = "haiku-4-5"
            confidence = 1.0
            ok, _, _ = validate(extracted, inv_total)
            if not ok:
                # Sonnet fallback.
                extracted_s, err_s, usage_s = await call_model(client, MODEL_SONNET, text)
                if usage_s:
                    stats["sonnet_in_tok"]  += usage_s.get("input_tokens", 0)
                    stats["sonnet_out_tok"] += usage_s.get("output_tokens", 0)
                    await log_ai_usage(conn, MODEL_SONNET, usage_s,
                                       service="u61-line-items", trace=f"inv#{inv_id}")
                ok_s, _, _ = validate(extracted_s, inv_total)
                if ok_s:
                    extracted = extracted_s
                    model_used = "sonnet-4-6-rescue"
                    confidence = 0.85
                    stats["sonnet_rescue"] += 1
                else:
                    # Both failed — store Haiku attempt with low confidence,
                    # mark for review.
                    if extracted is not None:
                        confidence = 0.55
                        model_used = "haiku-4-5-low-conf"
                    else:
                        stats["fail"] += 1
                        print(f"  #{inv_id}: both models failed: haiku={err} sonnet={err_s}")
                        continue
            else:
                stats["haiku_ok"] += 1

            # Defensive: extracted may be None (e.g. Haiku returned a malformed
            # JSON envelope) or lack a 'lines' key when both passes failed
            # validation but we still want to record a 0-line attempt rather
            # than crash. Use .get with a fallback.
            lines_arr = (extracted or {}).get("lines") or []
            if not lines_arr:
                print(f"  #{inv_id}: skipping insert — no lines in extracted payload (model={model_used})")
                stats["fail"] += 1
                continue
            n = await insert_lines(conn, inv_id, realm, lines_arr,
                                   model_used, confidence)
            stats["total_lines"] += n
            tot = float(inv_total) if inv_total else 0.0
            print(f"  #{inv_id:>3} → {n} lines  [{model_used}]  conf={confidence}  inv_total=£{tot:.2f}")

    print()
    print("=== Summary ===")
    for k, v in stats.items():
        print(f"  {k:18s} = {v}")
    # Crude cost estimate
    haiku_cost  = (stats['haiku_in_tok']  / 1e6) * 1.00 + (stats['haiku_out_tok']  / 1e6) * 5.00
    sonnet_cost = (stats['sonnet_in_tok'] / 1e6) * 3.00 + (stats['sonnet_out_tok'] / 1e6) * 15.00
    print(f"  cost estimate     ~ £{haiku_cost + sonnet_cost:.2f}  "
          f"(haiku £{haiku_cost:.2f} + sonnet £{sonnet_cost:.2f})")

    await conn.close()

asyncio.run(main())
PYEOF
