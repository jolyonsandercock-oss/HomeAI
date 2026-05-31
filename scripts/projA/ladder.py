#!/usr/bin/env python3
"""Project A — invoice extraction ladder.

Deterministic core (gate, derive_realm) + tiered extraction (local Ollama →
Haiku → Sonnet → human) + a bounded backfill. Runs inside homeai-bot-responder
(has anthropic, asyncpg, PG_DSN, VAULT_TOKEN, and network to ollama/google-fetch/
pdfplumber). Writes ONLY the new purchases/purchase_lines tables (shadow).

Usage (inside container, via the wrapper):
    python3 ladder.py --limit 25            # capped sample
    python3 ladder.py --limit 0             # all candidates (last 365d)
    python3 ladder.py --max-cloud-usd 5.0   # hard cloud-spend ceiling
"""
from __future__ import annotations
import os, sys, json, base64, urllib.request, urllib.error, asyncio, argparse, time
# asyncpg / anthropic imported lazily inside main() so the pure functions
# (gate, derive_realm) stay importable in a plain-stdlib test environment.

PG_DSN  = os.environ.get("PG_DSN", "")
GF      = "http://google-fetch:8011"
PDF_PL  = "http://homeai-pdfplumber:8003"
OLLAMA  = "http://homeai-ollama:11434"
LOCAL_MODEL  = "qwen2.5:7b"
HAIKU   = "claude-haiku-4-5-20251001"
SONNET  = "claude-sonnet-4-6"

def _load_schema():
    for p in ("/app/invoice_extract.schema.json",
              os.path.join(os.path.dirname(__file__), "..", "..", "ai_schemas", "invoice_extract.schema.json")):
        try:
            return json.load(open(p))["input_schema"]
        except Exception:
            continue
    return None
_SCHEMA = _load_schema()

TIER_THRESHOLD = {"local": 0.75, "haiku": 0.55, "sonnet": 0.50}
# Anthropic pricing $/MTok (in, out)
PRICE = {HAIKU: (1.0, 5.0), SONNET: (3.0, 15.0)}

_ACCOUNT_REALM = {"info": "work", "admin": "work", "jo": "personal", "pounana": "personal", "bot": "owner"}


def derive_realm(account, entity_id):
    # U233: entity is AUTHORITATIVE. An ARTL/entity-1 invoice is 'work' even if
    # it landed in a personal inbox (account='jo'). The receiving inbox must not
    # override the classified entity — that was tagging pub invoices 'personal'
    # purely because Jo received/forwarded them. Account is a fallback only when
    # entity is unknown.
    if entity_id == 1: return "work"
    if entity_id in (2, 3, 4): return "personal"
    if account and account.lower() in _ACCOUNT_REALM:
        return _ACCOUNT_REALM[account.lower()]
    return "owner"


def _num(v):
    try: return float(v) if v not in (None, "") else None
    except (TypeError, ValueError): return None


_REQUIRED = ("vendor_name", "invoice_date", "gross")
def gate(rec, tol=0.02):
    reasons = []
    if rec.get("is_invoice") is not True: reasons.append("not an invoice")
    for f in _REQUIRED:
        if rec.get(f) in (None, ""): reasons.append(f"missing {f}")
    net, vat, gross = _num(rec.get("net")), _num(rec.get("vat")), _num(rec.get("gross"))
    if None not in (net, vat, gross) and abs((net + vat) - gross) > tol:
        reasons.append("net+vat!=gross")
    lines = rec.get("lines") or []
    if lines and net is not None:
        s = sum((_num(l.get("line_net")) or 0) for l in lines)
        if abs(s - net) > max(tol, 0.01 * abs(net)): reasons.append("lines!=net")
    return (len(reasons) == 0, reasons)


# ─── OCR ────────────────────────────────────────────────────────
def fetch_pdf_bytes(acct, mid):
    """Raw bytes of the first PDF attachment, or None."""
    try:
        a = json.load(urllib.request.urlopen(f"{GF}/attachments/{acct}/{mid}", timeout=20))
    except Exception:
        return None
    pdf = next((x for x in a.get("attachments", [])
                if (x.get("mime_type") == "application/pdf" or (x.get("filename") or "").lower().endswith(".pdf"))), None)
    if not pdf: return None
    try:
        o = json.load(urllib.request.urlopen(f"{GF}/attachment/{acct}/{mid}/{pdf['attachment_id']}", timeout=45))
        return base64.urlsafe_b64decode(o["data_b64url"] + "=" * (-len(o["data_b64url"]) % 4))
    except Exception:
        return None


def _multipart(raw):
    b = "---b"
    body = (f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"x.pdf\"\r\n"
            f"Content-Type: application/pdf\r\n\r\n").encode() + raw + f"\r\n--{b}--\r\n".encode()
    return body, b


def pdf_to_text(raw):
    body, b = _multipart(raw)
    req = urllib.request.Request(f"{PDF_PL}/extract-pdf", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={b}"}, method="POST")
    try:
        return json.load(urllib.request.urlopen(req, timeout=60)).get("text") or ""
    except Exception:
        return ""


def pdf_to_png_b64(raw):
    """Render page 1 → PNG (pdfplumber service); base64 for Claude vision."""
    body, b = _multipart(raw)
    req = urllib.request.Request(f"{PDF_PL}/render-page1-png?width=1400", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={b}"}, method="POST")
    try:
        return base64.standard_b64encode(urllib.request.urlopen(req, timeout=60).read()).decode("ascii")
    except Exception:
        return None


# ─── Extractors ─────────────────────────────────────────────────
_SYS = ("Extract structured fields from the OCR text of a UK supplier invoice. "
        "Be conservative; null for anything not clearly present; never guess. "
        "is_invoice=false for statements/receipts/order-confirmations/payment-notifications.")


def extract_local(text):
    """Ollama structured output (format=json schema). Returns (dict|None, in_tok, out_tok, ms)."""
    payload = json.dumps({
        "model": LOCAL_MODEL, "stream": False, "format": _SCHEMA,
        "options": {"temperature": 0},
        "messages": [{"role": "system", "content": _SYS},
                     {"role": "user", "content": f"Invoice text:\n\n{text[:8000]}"}],
    }).encode()
    t0 = time.time()
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"{OLLAMA}/api/chat", data=payload, headers={"Content-Type": "application/json"}), timeout=120)
        resp = json.load(r)
        ms = int((time.time() - t0) * 1000)
        return json.loads(resp["message"]["content"]), resp.get("prompt_eval_count", 0), resp.get("eval_count", 0), ms
    except Exception as e:
        sys.stderr.write(f"local err: {str(e)[:120]}\n")
        return None, 0, 0, int((time.time() - t0) * 1000)


def extract_anthropic(client, text, model):
    """Anthropic tool-use. Returns (dict|None, in_tok, out_tok)."""
    tool = {"name": "extract_invoice", "description": "Record invoice fields.", "input_schema": _SCHEMA}
    try:
        resp = client.messages.create(
            model=model, max_tokens=1500, system=_SYS, tools=[tool],
            tool_choice={"type": "tool", "name": "extract_invoice"},
            messages=[{"role": "user", "content": f"Invoice text:\n\n{text[:12000]}"}])
        tu = [b for b in resp.content if b.type == "tool_use"]
        d = tu[0].input if tu else None
        return d, resp.usage.input_tokens, resp.usage.output_tokens
    except Exception as e:
        sys.stderr.write(f"{model} err: {str(e)[:120]}\n"); return None, 0, 0


def extract_vision(client, png_b64, model):
    """Anthropic tool-use on a page image (image-only PDFs). Returns (dict|None, in, out)."""
    tool = {"name": "extract_invoice", "description": "Record invoice fields.", "input_schema": _SCHEMA}
    try:
        resp = client.messages.create(
            model=model, max_tokens=1500, system=_SYS, tools=[tool],
            tool_choice={"type": "tool", "name": "extract_invoice"},
            messages=[{"role": "user", "content": [
                {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": png_b64}},
                {"type": "text", "text": "Extract the fields from this invoice image."}]}])
        tu = [b for b in resp.content if b.type == "tool_use"]
        return (tu[0].input if tu else None), resp.usage.input_tokens, resp.usage.output_tokens
    except Exception as e:
        sys.stderr.write(f"{model} vision err: {str(e)[:120]}\n"); return None, 0, 0


def _cost(model, itok, otok):
    pin, pout = PRICE.get(model, (0, 0))
    return itok * pin / 1e6 + otok * pout / 1e6


async def log_usage(conn, model, tier, in_tok, out_tok, ms, provider, cost, vision=False):
    """Write one ai_usage row per inference (local AND cloud) so the ledger is complete."""
    try:
        await conn.execute("""
          INSERT INTO ai_usage (task_type, model_used, tier, prompt_tokens, completion_tokens,
              latency_ms, cached, provider, realm, entity_id, cost_gbp, capability_tag, service)
          VALUES ($1,$2,$3,$4,$5,$6,false,$7,'owner',1,$8,'CAP_INVOICE_EXTRACT','invoice-ladder')
        """, 'invoice.extract_vision' if vision else 'invoice.extract', model, tier,
             int(in_tok or 0), int(out_tok or 0), ms, provider, round(float(cost), 6))
    except Exception as e:
        sys.stderr.write(f"ai_usage log err: {str(e)[:90]}\n")


# ─── Orchestration ──────────────────────────────────────────────
async def run_ladder(client, conn, row, state):
    acct, mid = row["account"], row["source_email_id"]
    key = f"purch:{acct}:{mid}"
    if await conn.fetchval("SELECT 1 FROM purchases WHERE idempotency_key=$1", key):
        state["skip"] += 1; return
    realm = derive_realm(acct, row.get("entity_id"))

    stored = row.get("pdf_text_extracted")
    text = stored if (stored and len(stored) >= 50) else None
    raw = None
    if text is None:
        raw = fetch_pdf_bytes(acct, mid)
        if raw:
            text = pdf_to_text(raw)

    use_vision = (not text or len(text) < 30)
    png_b64 = None
    if use_vision:
        if raw is None:
            raw = fetch_pdf_bytes(acct, mid)
        png_b64 = pdf_to_png_b64(raw) if raw else None
        if png_b64 is None:
            state["no_text"] += 1; return

    result, tier, conf, lastd = None, None, 0.0, None

    # Tier 0 — local (text only; qwen is not a vision model)
    if not use_vision:
        d, l_in, l_out, l_ms = extract_local(text)
        await log_usage(conn, LOCAL_MODEL, "local", l_in, l_out, l_ms, "ollama", 0.0)
        if d is not None:
            lastd = d; cf = float(d.get("confidence") or 0)
            if d.get("is_invoice") is False and cf >= TIER_THRESHOLD["local"]:
                await _write(conn, row, key, realm, d, "local", cf, False); state["not_invoice"] += 1; return
            ok, _ = gate(d)
            if ok and cf >= TIER_THRESHOLD["local"]:
                result, tier, conf = d, "local", cf

    # Cloud tiers — text or vision, respecting the spend ceiling
    for model, tname in ((HAIKU, "haiku"), (SONNET, "sonnet")):
        if result is not None: break
        if state["cloud_usd"] >= state["ceiling"]:
            state["ceiling_hit"] = True; break
        if use_vision:
            d, itok, otok = extract_vision(client, png_b64, model); label = tname + "_vision"
        else:
            d, itok, otok = extract_anthropic(client, text, model); label = tname
        state["cloud_usd"] += _cost(model, itok, otok)
        state["in_tok"] += itok; state["out_tok"] += otok
        state[f"calls_{tname}"] = state.get(f"calls_{tname}", 0) + 1
        await log_usage(conn, model, tname, itok, otok, None, "anthropic", _cost(model, itok, otok), vision=use_vision)
        if d is None: continue
        lastd = d; cf = float(d.get("confidence") or 0)
        if d.get("is_invoice") is False and cf >= TIER_THRESHOLD[tname]:
            await _write(conn, row, key, realm, d, label, cf, False); state["not_invoice"] += 1; return
        ok, _ = gate(d)
        if ok and cf >= TIER_THRESHOLD[tname]:
            result, tier, conf = d, label, cf

    if result is not None:
        await _write(conn, row, key, realm, result, tier, conf, True)
        state["accepted"] += 1
        state[f"acc_{tier}"] = state.get(f"acc_{tier}", 0) + 1
    else:
        await _write(conn, row, key, realm, lastd or {}, tier or ("vision" if use_vision else "local"), conf, False)
        state["to_verify"] += 1


async def _write(conn, row, key, realm, d, tier, conf, gate_passed):
    async with conn.transaction():
        await conn.execute("SELECT set_config('app.current_realm', $1, true)", realm)
        pid = await conn.fetchval("""
          INSERT INTO purchases (idempotency_key, source, source_ref, account, vendor_name,
            invoice_number, invoice_date, due_date, net_amount, vat_amount, gross_amount,
            currency, category, is_invoice, extraction_tier, confidence, gate_passed,
            verified, entity_id, realm)
          VALUES ($1,'email',$2,$3,$4,$5,$6::date,$7::date,$8,$9,$10,$11,$12,$13,$14,$15,$16,false,$17,$18)
          ON CONFLICT (idempotency_key) DO NOTHING RETURNING id
        """, key, row["source_email_id"], row["account"], d.get("vendor_name"),
             d.get("invoice_number"), _dt(d.get("invoice_date")), _dt(d.get("due_date")),
             _num(d.get("net")), _num(d.get("vat")), _num(d.get("gross")),
             d.get("currency") or "GBP", d.get("category"), d.get("is_invoice"),
             tier, round(conf, 3), gate_passed, row.get("entity_id"), realm)
        if pid:
            for i, ln in enumerate(d.get("lines") or []):
                await conn.execute("""
                  INSERT INTO purchase_lines (purchase_id, line_no, description, quantity, unit,
                    unit_price, line_net, vat_rate, category, realm)
                  VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
                """, pid, i + 1, ln.get("description"), _num(ln.get("quantity")), ln.get("unit"),
                     _num(ln.get("unit_price")), _num(ln.get("line_net")), _num(ln.get("vat_rate")),
                     ln.get("category"), realm)


def _dt(s):
    if not s or not isinstance(s, str): return None
    import re, datetime
    if re.match(r"^\d{4}-\d{2}-\d{2}$", s):
        try: return datetime.date.fromisoformat(s)
        except ValueError: return None
    return None


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=25)
    ap.add_argument("--max-cloud-usd", type=float, default=10.0)
    args = ap.parse_args()
    import asyncpg, anthropic
    def vault(p):
        req = urllib.request.Request(f"http://vault:8200/v1/secret/data/{p}",
                                      headers={"X-Vault-Token": os.environ["VAULT_TOKEN"]})
        return json.loads(urllib.request.urlopen(req, timeout=5).read())["data"]["data"]
    client = anthropic.Anthropic(api_key=vault("anthropic")["api_key"])
    conn = await asyncpg.connect(PG_DSN)
    lim = "" if args.limit == 0 else f"LIMIT {args.limit}"
    rows = await conn.fetch(f"""
      SELECT id, account, source_email_id, entity_id, pdf_text_extracted
        FROM vendor_invoice_inbox
       WHERE received_at >= CURRENT_DATE - 365 AND is_statement = false
         AND status NOT IN ('duplicate','ignored') AND source_email_id ~ '^[0-9a-f]+$'
       ORDER BY received_at DESC {lim}
    """)
    state = {k: 0 for k in ("skip","no_text","not_invoice","accepted","to_verify",
            "acc_local","acc_haiku","acc_sonnet","calls_haiku","calls_sonnet","in_tok","out_tok")}
    state["cloud_usd"] = 0.0; state["ceiling"] = args.max_cloud_usd; state["ceiling_hit"] = False
    t0 = time.time()
    print(f"candidates: {len(rows)}  ceiling: ${args.max_cloud_usd}")
    for i, r in enumerate(rows, 1):
        try:
            await run_ladder(client, conn, dict(r), state)
        except Exception as e:
            sys.stderr.write(f"row {r['id']} err: {str(e)[:150]}\n")
        if i % 25 == 0:
            print(f"  [{i}/{len(rows)}] accepted={state['accepted']} verify={state['to_verify']} "
                  f"not_inv={state['not_invoice']} cloud=${state['cloud_usd']:.3f}", flush=True)
    await conn.close()
    dur = int(time.time() - t0)
    print("\n== ladder run ==")
    for k in ("skip","no_text","not_invoice","accepted","acc_local","acc_haiku","acc_sonnet",
              "to_verify","calls_haiku","calls_sonnet"):
        print(f"  {k:14} {state[k]}")
    print(f"  cloud_usd      ${state['cloud_usd']:.4f}  (in={state['in_tok']} out={state['out_tok']})")
    print(f"  ceiling_hit    {state['ceiling_hit']}   runtime {dur}s")

if __name__ == "__main__":
    asyncio.run(main())
