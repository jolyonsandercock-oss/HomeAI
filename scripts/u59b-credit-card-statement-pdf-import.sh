#!/usr/bin/env bash
#
# u59b-credit-card-statement-pdf-import.sh — import RBS Mastercard
# StatementArchive_*.pdf into card_statements.
#
# Architecture: bot-responder (has asyncpg+httpx) is the orchestrator; it
# POSTs each PDF to homeai-pdfplumber:8003/extract-pdf for text extraction,
# then parses the page-1 summary box, then upserts card_statements.
#
# Page-1 fields parsed (regex-on-compacted-text):
#   * MasterCardNumber (full PAN → mapped to bank_account by last-4)
#   * Summary <DD Mon YYYY>           = statement_date
#   * TotalCreditLimit
#   * Balance brought forward         = opening_balance
#   * Payments to your account        = payments_credited
#   * Spending + adjustments          = spending_charged
#   * New Balance                     = closing_balance
#   * Minimum Payment                 = min_payment
#   * "debited ... payment of £X on DDMonYYYY"  = min_payment_due_date
#
# Period_start = previous statement_date for same card + 1 day. For the
# earliest historical statement, period_start = statement_date - 30 days.
#
# Interest + fees are derived from bank_transactions on the matching
# (bank_account, period) range, not the PDF.
#
# Idempotent: UNIQUE (bank_account_id, statement_date).

set -euo pipefail

PDF_DIR_HOST="${1:-/home_ai/data/credit-card-inbox/2026-05-14}"
DRY_RUN="${DRY_RUN:-0}"

VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PG_PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/postgres)
PG_DSN="postgresql://postgres:${PG_PW}@homeai-postgres:5432/homeai"
unset VT PG_PW

# Stage PDFs into bot-responder.
docker exec homeai-bot-responder mkdir -p /tmp/cc-pdfs
docker exec homeai-bot-responder sh -c 'rm -f /tmp/cc-pdfs/*.pdf 2>/dev/null || true'
for f in "${PDF_DIR_HOST}"/*.pdf; do
    docker cp "$f" "homeai-bot-responder:/tmp/cc-pdfs/"
done

docker exec -i -e PG_DSN="${PG_DSN}" -e DRY_RUN="${DRY_RUN}" \
    homeai-bot-responder python <<'PYEOF'
import asyncio, asyncpg, os, glob, hashlib, re
from datetime import date, timedelta
import httpx

PDF_DIR = "/tmp/cc-pdfs"
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"
PDFPLUMBER_URL = "http://homeai-pdfplumber:8003/extract-pdf"

RX = {
    "pan":   re.compile(r"MasterCardNumber\s*(\d{16})"),
    "stmt":  re.compile(r"Summary\s+(\d{1,2})\s*([A-Za-z]{3,9})\s*(\d{4})"),
    "limit": re.compile(r"TotalCreditLimit\s*£?([\d,]+(?:\.\d{2})?)"),
    "open":  re.compile(r"Balancebrought\s*forward.*?£?([\d,]+\.\d{2})", re.S | re.I),
    "pay":   re.compile(r"Paymentstoyouraccount\s*£?([\d,]+\.\d{2})\s*-", re.I),
    "spend": re.compile(r"Spending.*?\+£?([\d,]+\.\d{2})", re.S | re.I),
    "new":   re.compile(r"NewBalance\s*=\s*£?([\d,]+\.\d{2})", re.I),
    "min":   re.compile(r"MinimumPayment\s*£?([\d,]+\.\d{2})", re.I),
    "due":   re.compile(r"paymentof£?[\d,]+\.\d{2}\s*on\s*(\d{1,2})\s*([A-Za-z]{3,9})\s*(\d{4})"),
}

MONTHS = {m: i for i, m in enumerate(
    ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"], 1)}

def to_money(s):
    return float(s.replace(",", "").replace("£", "").strip()) if s else None

def to_date(d, mon, y):
    m = MONTHS.get(mon[:3].capitalize())
    return date(int(y), m, int(d)) if m else None

def parse_text(raw_text):
    # Compact whitespace — RBS PDFs come back with words run-together so we
    # join the lot and let RX do anchor-based extraction.
    t = re.sub(r"\s+", "", raw_text)
    out = {}
    m = RX["pan"].search(raw_text);   out["pan"] = m.group(1) if m else None
    m = RX["stmt"].search(raw_text);  out["statement_date"] = to_date(*m.groups()) if m else None
    m = RX["limit"].search(t);        out["credit_limit"] = to_money(m.group(1)) if m else None
    m = RX["open"].search(t);         out["opening_balance"] = to_money(m.group(1)) if m else None
    m = RX["pay"].search(t);          out["payments_credited"] = to_money(m.group(1)) if m else None
    m = RX["spend"].search(t);        out["spending_charged"] = to_money(m.group(1)) if m else None
    m = RX["new"].search(t);          out["closing_balance"] = to_money(m.group(1)) if m else None
    m = RX["min"].search(t);          out["min_payment"] = to_money(m.group(1)) if m else None
    m = RX["due"].search(t);          out["min_payment_due_date"] = to_date(*m.groups()) if m else None
    return out

def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

async def extract(path, client):
    with open(path, "rb") as f:
        r = await client.post(PDFPLUMBER_URL, files={"file": (os.path.basename(path), f, "application/pdf")})
    r.raise_for_status()
    return r.json()["text"]

async def main():
    conn = await asyncpg.connect(os.environ["PG_DSN"])
    await conn.fetchval("SELECT set_config('app.current_entity', 'all',   false)")
    await conn.fetchval("SELECT set_config('app.current_realm',  'owner', false)")

    rows = await conn.fetch("""
        SELECT id, account_number FROM bank_accounts
         WHERE account_type='credit_card' AND bank_name='RBS Mastercard'
    """)
    last4_to_id = {r["account_number"][-4:]: r["id"] for r in rows}
    print(f"Cards in DB: {last4_to_id}")

    pdfs = sorted(glob.glob(PDF_DIR + "/*.pdf"))
    print(f"\nParsing {len(pdfs)} PDF(s)…")

    parsed_by_card = {}
    parse_errors = []
    async with httpx.AsyncClient(timeout=60) as client:
        for path in pdfs:
            try:
                text = await extract(path, client)
                p = parse_text(text)
            except Exception as e:
                parse_errors.append((os.path.basename(path), str(e)[:100]))
                continue
            if not p.get("pan") or not p.get("statement_date"):
                parse_errors.append((os.path.basename(path),
                                     f"pan={p.get('pan')} date={p.get('statement_date')}"))
                continue
            p["source_pdf_path"] = path
            p["pdf_sha256"] = sha256_of(path)
            p["raw_text"] = text
            parsed_by_card.setdefault(p["pan"][-4:], []).append(p)

    if parse_errors:
        print(f"\nPARSE ERRORS ({len(parse_errors)}):")
        for n, err in parse_errors[:10]:
            print(f"  {n}: {err}")

    inserted = skipped_dup = skipped_unknown = 0
    for last4, statements in parsed_by_card.items():
        if last4 not in last4_to_id:
            print(f"  skipping unknown card ****{last4} ({len(statements)} statements)")
            skipped_unknown += len(statements)
            continue
        statements.sort(key=lambda s: s["statement_date"])
        for i, s in enumerate(statements):
            period_end = s["statement_date"]
            period_start = (statements[i-1]["statement_date"] + timedelta(days=1)
                            if i > 0 else period_end - timedelta(days=30))

            if DRY_RUN:
                inserted += 1
                continue

            confidence_keys = ("opening_balance","payments_credited","spending_charged",
                               "closing_balance","min_payment","min_payment_due_date","credit_limit")
            confidence = round(sum(1 for k in confidence_keys if s.get(k) is not None) / len(confidence_keys), 3)

            res = await conn.fetchrow("""
                INSERT INTO card_statements
                  (bank_account_id, entity_id, realm, statement_date,
                   period_start, period_end, opening_balance, payments_credited,
                   spending_charged, closing_balance, min_payment,
                   min_payment_due_date, credit_limit, source_pdf_path, pdf_sha256,
                   raw_text, extraction_confidence)
                VALUES ($1, 3, 'family', $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
                ON CONFLICT (bank_account_id, statement_date) DO NOTHING
                RETURNING id
            """, last4_to_id[last4], period_end, period_start, period_end,
                 s.get("opening_balance"), s.get("payments_credited"),
                 s.get("spending_charged"), s.get("closing_balance"),
                 s.get("min_payment"), s.get("min_payment_due_date"),
                 s.get("credit_limit"), s["source_pdf_path"], s["pdf_sha256"],
                 s["raw_text"][:8000], confidence)
            if res:
                inserted += 1
            else:
                skipped_dup += 1

    print(f"\nInserted          = {inserted}")
    print(f"Skipped (dup)     = {skipped_dup}")
    print(f"Skipped (unknown) = {skipped_unknown}")
    print(f"Parse errors      = {len(parse_errors)}")

    print("\nBackfilling interest_charged + fees_charged from bank_transactions…")
    upd = await conn.execute("""
        UPDATE card_statements cs
           SET interest_charged = COALESCE((
                   SELECT SUM(bt.amount) FROM bank_transactions bt
                    WHERE bt.bank_account_id = cs.bank_account_id
                      AND bt.transaction_date BETWEEN cs.period_start AND cs.period_end
                      AND bt.category = 'interest_charged'
               ), 0),
               fees_charged = COALESCE((
                   SELECT SUM(bt.amount) FROM bank_transactions bt
                    WHERE bt.bank_account_id = cs.bank_account_id
                      AND bt.transaction_date BETWEEN cs.period_start AND cs.period_end
                      AND bt.category = 'bank_fee'
               ), 0)
    """)
    print(f"  {upd}")

    print("\nSummary per card:")
    rows = await conn.fetch("""
        SELECT ba.account_name, COUNT(*) AS n,
               MIN(cs.statement_date) AS dfirst, MAX(cs.statement_date) AS dlast,
               SUM(cs.interest_charged)::numeric(12,2) AS sum_interest,
               SUM(cs.fees_charged)::numeric(12,2)     AS sum_fees,
               ROUND(AVG(cs.extraction_confidence)::numeric, 3) AS avg_conf
          FROM card_statements cs
          JOIN bank_accounts ba ON ba.id = cs.bank_account_id
         GROUP BY ba.account_name
         ORDER BY ba.account_name
    """)
    for r in rows:
        print(f"  {r['account_name']:55s} n={r['n']:>2}  "
              f"{r['dfirst']}..{r['dlast']}  "
              f"int={r['sum_interest']!s:>8}  fee={r['sum_fees']!s:>7}  conf={r['avg_conf']}")

    await conn.close()

asyncio.run(main())
PYEOF
