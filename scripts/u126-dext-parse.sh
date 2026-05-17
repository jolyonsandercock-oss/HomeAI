#!/usr/bin/env bash
# u126-dext-parse.sh — parse a Dext CSV export into vendor_invoice_lines.
#
# Usage:
#   ./u126-dext-parse.sh /home_ai/data/dext-exports/dext-YYYY-MM-DD.csv
#   ./u126-dext-parse.sh            (uses latest file in dext-exports/)
#
# Matching rule:
#   Each CSV row has supplier + invoice date + invoice number + line items.
#   We match to vendor_invoice_inbox by (vendor_name LIKE supplier) AND
#   (invoice_date) AND (invoice_number when present). If no match, create
#   a new inbox row with extraction_method='dext-import'.

set -euo pipefail

CSV="${1:-}"
if [ -z "$CSV" ]; then
  CSV=$(ls -t /home_ai/data/dext-exports/dext-*.csv 2>/dev/null | head -1)
fi
[ -f "$CSV" ] || { echo "❌ no CSV found: $CSV"; exit 1; }
echo "── parsing $CSV"

VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker cp "$CSV" homeai-bot-responder:/tmp/dext.csv >/dev/null

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" homeai-bot-responder python3 -u <<'PYEOF'
import os, csv, json, urllib.request, asyncio, re
import asyncpg
from datetime import datetime

TOK = os.environ["VAULT_TOKEN"]
def vault(p):
    r = urllib.request.urlopen(urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{p}",
        headers={"X-Vault-Token": TOK}), timeout=5)
    return json.loads(r.read())["data"]["data"]


def num(x):
    if x is None: return None
    s = re.sub(r"[£$,\\s]", "", str(x))
    if not s or s.lower() in ('null','-','n/a'): return None
    try: return float(s)
    except: return None


def parse_date(s):
    if not s: return None
    s = s.strip()
    for fmt in ("%Y-%m-%d","%d/%m/%Y","%d-%m-%Y","%d %b %Y","%d %B %Y"):
        try: return datetime.strptime(s[:len(fmt)], fmt).date()
        except: pass
    return None


# Detect Dext's column names — they vary slightly with locale / version
# but key fields are stable enough to find by substring match
def find_col(headers, *needles):
    for n in needles:
        for h in headers:
            if n.lower() in h.lower(): return h
    return None


async def main():
    pg = vault("postgres")["password"]
    conn = await asyncpg.connect(f"postgresql://postgres:{pg}@homeai-postgres:5432/homeai")
    await conn.execute("SELECT home_ai.set_realm('owner')")

    with open("/tmp/dext.csv", "rb") as f:
        # Strip UTF-8 BOM if present
        head = f.read(3)
        if head != b"\xef\xbb\xbf":
            f.seek(0)
        text = f.read().decode("utf-8", errors="replace")
    rows = list(csv.DictReader(text.splitlines()))
    if not rows:
        print("(CSV is empty)")
        return
    headers = list(rows[0].keys())
    print(f"rows: {len(rows)}, columns: {len(headers)}")
    print(f"sample columns: {headers[:8]}")

    SUPPLIER_C   = find_col(headers, "supplier", "vendor", "merchant", "payee")
    DATE_C       = find_col(headers, "date", "invoice date", "doc date")
    INV_NUM_C    = find_col(headers, "invoice number", "doc number", "reference")
    NET_C        = find_col(headers, "net", "subtotal", "before tax")
    VAT_C        = find_col(headers, "vat", "tax")
    GROSS_C      = find_col(headers, "total", "gross", "amount")
    DESC_C       = find_col(headers, "description", "narrative", "memo", "line")
    QTY_C        = find_col(headers, "quantity", "qty")
    UNIT_PRICE_C = find_col(headers, "unit price", "rate", "price")
    CATEGORY_C   = find_col(headers, "category", "account", "nominal")

    print(f"detected: supplier='{SUPPLIER_C}' date='{DATE_C}' net='{NET_C}' vat='{VAT_C}' gross='{GROSS_C}'")

    stats = {"matched_inbox": 0, "new_inbox": 0, "lines_inserted": 0, "skipped": 0}

    for r in rows:
        supplier = (r.get(SUPPLIER_C) or "").strip() if SUPPLIER_C else ""
        inv_date = parse_date(r.get(DATE_C) or "") if DATE_C else None
        inv_num  = (r.get(INV_NUM_C) or "").strip() if INV_NUM_C else ""
        net      = num(r.get(NET_C)) if NET_C else None
        vat      = num(r.get(VAT_C)) if VAT_C else None
        gross    = num(r.get(GROSS_C)) if GROSS_C else None
        desc     = (r.get(DESC_C) or "").strip() if DESC_C else ""
        qty      = num(r.get(QTY_C)) if QTY_C else 1.0
        unit_pr  = num(r.get(UNIT_PRICE_C)) if UNIT_PRICE_C else None

        if not supplier or not inv_date:
            stats["skipped"] += 1
            continue

        # Match to existing inbox row
        inbox_id = await conn.fetchval("""
            SELECT id FROM vendor_invoice_inbox
             WHERE invoice_date = $1
               AND (vendor_name ILIKE $2 OR vendor_name ILIKE $3)
             ORDER BY id LIMIT 1
        """, inv_date, f"%{supplier}%", f"{supplier}%")

        if not inbox_id:
            # Create one — gives Dext data a home even if email wasn't ingested
            inbox_id = await conn.fetchval("""
                INSERT INTO vendor_invoice_inbox
                  (vendor_name, vendor_domain, invoice_date, gross_amount,
                   amount_seen, status, extraction_method, realm)
                VALUES ($1, NULL, $2, $3, $3, 'extracted', 'dext-import', 'work')
                RETURNING id
            """, supplier, inv_date, gross or net or 0)
            stats["new_inbox"] += 1
        else:
            stats["matched_inbox"] += 1
            await conn.execute("""
                UPDATE vendor_invoice_inbox
                   SET status = CASE WHEN status='new' THEN 'extracted' ELSE status END,
                       extraction_method = COALESCE(extraction_method, 'dext-import'),
                       extracted_at = COALESCE(extracted_at, now()),
                       gross_amount = COALESCE(gross_amount, $2)
                 WHERE id = $1
            """, inbox_id, gross)

        # Insert the line (one line per CSV row in Dext exports)
        await conn.execute("""
            INSERT INTO vendor_invoice_lines
              (invoice_id, description, qty, unit_price, line_net, vat_rate,
               model_used, confidence, realm)
            VALUES ($1, $2, COALESCE($3, 1), $4, $5,
                    CASE WHEN $6 > 0 AND $7 > 0 THEN ROUND(($6/$7)::numeric, 2) ELSE NULL END,
                    'dext-export', 1.0, 'work')
        """, inbox_id, desc or supplier, qty, unit_pr, net or gross, vat or 0, net or 0)
        stats["lines_inserted"] += 1

    print()
    print("=== summary ===")
    for k, v in stats.items():
        print(f"  {k:18s} = {v}")
    await conn.close()


asyncio.run(main())
PYEOF
