#!/usr/bin/env bash
# u128-xero-parse.sh — parse a Xero "Bills" CSV export into xero_bills + xero_bill_lines.
#
# Usage:
#   u128-xero-parse.sh <file.csv>             # parse one file
#   u128-xero-parse.sh --dir <dir>            # parse every CSV in dir
#   u128-xero-parse.sh                        # default dir = /home_ai/data/xero-inbox
#
# Runs inside homeai-playwright (has asyncpg + the data mount).
# After upsert, links matching rows in vendor_invoice_inbox by
# canonical(vendor_name) + invoice_date + amount-within-tolerance.

set -euo pipefail

INBOX_DIR="${INBOX_DIR:-/home_ai/data/xero-inbox}"
ARCHIVE_DIR="$INBOX_DIR/.processed"
mkdir -p "$INBOX_DIR" "$ARCHIVE_DIR"

# Decide what to process (paths must be valid inside the playwright container,
# which mounts /home_ai/data → /home_ai/data, so host paths work directly).
FILES=()
if [[ $# -eq 0 ]]; then
  shopt -s nullglob
  FILES=("$INBOX_DIR"/Bills_*.csv "$INBOX_DIR"/*.csv)
elif [[ "$1" == "--dir" ]]; then
  shopt -s nullglob
  FILES=("$2"/Bills_*.csv "$2"/*.csv)
else
  FILES=("$@")
fi

mapfile -t FILES < <(printf '%s\n' "${FILES[@]}" | awk '!seen[$0]++' | xargs -I{} sh -c 'test -f "$1" && echo "$1"' _ {})

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "no CSVs to parse"; exit 0
fi

echo "== Parsing ${#FILES[@]} CSV(s):"
printf '  %s\n' "${FILES[@]}"

# JSON-encode the list of paths to safely pass through the heredoc.
PATHS_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${FILES[@]}")

docker exec -i -e PATHS_JSON="$PATHS_JSON" homeai-playwright python3 <<'PYEOF'
import asyncio, asyncpg, csv, json, os, sys
from datetime import datetime
from decimal import Decimal, InvalidOperation

DSN  = os.environ['PG_DSN']
PATHS = json.loads(os.environ['PATHS_JSON'])

def parse_date(s):
    s = (s or '').strip()
    if not s: return None
    for fmt in ('%d/%m/%Y','%Y-%m-%d','%d-%m-%Y','%m/%d/%Y'):
        try: return datetime.strptime(s, fmt).date()
        except ValueError: pass
    return None

def parse_dec(s):
    s = (s or '').strip().replace(',','')
    if not s: return None
    try: return Decimal(s)
    except InvalidOperation: return None

async def main():
    conn = await asyncpg.connect(DSN)
    await conn.execute("SELECT home_ai.set_realm('owner')")
    await conn.execute("SET app.current_entity='all'")

    t_ins = t_upd = t_lines = 0
    bill_ids = set()

    for path in PATHS:
        if not os.path.isfile(path):
            print(f"  ! missing: {path}"); continue
        src = os.path.basename(path)
        print(f"-- {src}")
        bills = {}
        with open(path, encoding='utf-8-sig') as f:
            for r in csv.DictReader(f):
                inv_date = parse_date(r.get('InvoiceDate'))
                inv_no   = (r.get('InvoiceNumber') or '').strip()
                contact  = (r.get('ContactName') or '').strip()
                if not (contact and inv_no and inv_date): continue
                key = (contact, inv_no, inv_date)
                if key not in bills:
                    bills[key] = {
                        'h': {
                            'contact_name': contact, 'invoice_number': inv_no,
                            'reference':    (r.get('Reference') or '').strip() or None,
                            'invoice_date': inv_date,
                            'due_date':     parse_date(r.get('DueDate')),
                            'planned_date': parse_date(r.get('PlannedDate')),
                            'total':        parse_dec(r.get('Total')),
                            'tax_total':    parse_dec(r.get('TaxTotal')),
                            'amount_paid':  parse_dec(r.get('InvoiceAmountPaid')),
                            'amount_due':   parse_dec(r.get('InvoiceAmountDue')),
                            'currency':     (r.get('Currency') or '').strip() or None,
                            'type':         (r.get('Type') or '').strip() or None,
                            'sent':         (r.get('Sent') or '').strip() or None,
                            'status':       (r.get('Status') or '').strip() or None,
                        },
                        'lines': [],
                    }
                bills[key]['lines'].append({
                    'inventory_code':    (r.get('InventoryItemCode') or '').strip() or None,
                    'description':       (r.get('Description') or '').strip() or None,
                    'quantity':          parse_dec(r.get('Quantity')),
                    'unit_amount':       parse_dec(r.get('UnitAmount')),
                    'discount':          parse_dec(r.get('Discount')),
                    'line_amount':       parse_dec(r.get('LineAmount')),
                    'account_code':      (r.get('AccountCode') or '').strip() or None,
                    'tax_type':          (r.get('TaxType') or '').strip() or None,
                    'tax_amount':        parse_dec(r.get('TaxAmount')),
                    'tracking_name_1':   (r.get('TrackingName1') or '').strip() or None,
                    'tracking_option_1': (r.get('TrackingOption1') or '').strip() or None,
                    'tracking_name_2':   (r.get('TrackingName2') or '').strip() or None,
                    'tracking_option_2': (r.get('TrackingOption2') or '').strip() or None,
                })

        print(f"   {len(bills)} bills, {sum(len(b['lines']) for b in bills.values())} lines")

        async with conn.transaction():
            for key, payload in bills.items():
                h = payload['h']
                raw = {**h,
                       'invoice_date': h['invoice_date'].isoformat(),
                       'due_date':     h['due_date'].isoformat() if h['due_date'] else None,
                       'planned_date': h['planned_date'].isoformat() if h['planned_date'] else None}
                for k in ('total','tax_total','amount_paid','amount_due'):
                    if isinstance(raw[k], Decimal): raw[k] = float(raw[k])

                row = await conn.fetchrow("""
                  INSERT INTO xero_bills
                    (contact_name, invoice_number, reference, invoice_date, due_date, planned_date,
                     total, tax_total, amount_paid, amount_due, currency, type, sent, status,
                     source_csv, raw_payload)
                  VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16::jsonb)
                  ON CONFLICT (contact_name, invoice_number, invoice_date) DO UPDATE SET
                    reference=EXCLUDED.reference, due_date=EXCLUDED.due_date,
                    planned_date=EXCLUDED.planned_date,
                    total=EXCLUDED.total, tax_total=EXCLUDED.tax_total,
                    amount_paid=EXCLUDED.amount_paid, amount_due=EXCLUDED.amount_due,
                    currency=EXCLUDED.currency, type=EXCLUDED.type, sent=EXCLUDED.sent,
                    status=EXCLUDED.status, source_csv=EXCLUDED.source_csv,
                    raw_payload=EXCLUDED.raw_payload, ingested_at=now()
                  RETURNING id, (xmax = 0) AS inserted
                """, h['contact_name'], h['invoice_number'], h['reference'],
                     h['invoice_date'], h['due_date'], h['planned_date'],
                     h['total'], h['tax_total'], h['amount_paid'], h['amount_due'],
                     h['currency'], h['type'], h['sent'], h['status'],
                     src, json.dumps(raw, default=str))
                bill_id, inserted = row['id'], row['inserted']
                bill_ids.add(bill_id)
                if inserted: t_ins += 1
                else:        t_upd += 1

                await conn.execute("DELETE FROM xero_bill_lines WHERE xero_bill_id=$1", bill_id)
                for i, ln in enumerate(payload['lines'], 1):
                    await conn.execute("""
                      INSERT INTO xero_bill_lines
                        (xero_bill_id, line_no, inventory_code, description, quantity,
                         unit_amount, discount, line_amount, account_code, tax_type,
                         tax_amount, tracking_name_1, tracking_option_1,
                         tracking_name_2, tracking_option_2)
                      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
                    """, bill_id, i, ln['inventory_code'], ln['description'],
                         ln['quantity'], ln['unit_amount'], ln['discount'],
                         ln['line_amount'], ln['account_code'], ln['tax_type'],
                         ln['tax_amount'], ln['tracking_name_1'],
                         ln['tracking_option_1'], ln['tracking_name_2'],
                         ln['tracking_option_2'])
                    t_lines += 1

    if bill_ids:
        # Two-pass linking:
        #   1. STRICT  — vendor canonical equal, exact date, amount ±£1
        #   2. FUZZY   — date ±1 day, amount ±£1, unique 1:1 (one inbox row + one bill).
        # The inbox vendor_name is the email "From" header (e.g. 'Adam <adam@forestproduce.com>')
        # while xero contact is clean ('Forest Produce'), so string match almost never fires —
        # the fuzzy pass is the real workhorse.
        print(f"-- linking inbox rows to {len(bill_ids)} Xero bills")
        strict = await conn.fetch("""
          WITH cands AS (
            SELECT id, contact_name, invoice_date, total FROM xero_bills WHERE id = ANY($1::bigint[])
          ),
          m AS (
            SELECT i.id AS inbox_id, c.id AS bill_id
              FROM vendor_invoice_inbox i
              JOIN cands c
                ON LOWER(REGEXP_REPLACE(c.contact_name, '[^a-z0-9]', '', 'g')) =
                   LOWER(REGEXP_REPLACE(COALESCE(i.vendor_name,''), '[^a-z0-9]', '', 'g'))
               AND i.invoice_date = c.invoice_date
               AND ABS(COALESCE(i.gross_amount, i.amount_seen, 0) - COALESCE(c.total,0)) < 1.00
             WHERE i.xero_bill_id IS NULL
          )
          UPDATE vendor_invoice_inbox v SET xero_bill_id = m.bill_id
            FROM m WHERE v.id = m.inbox_id RETURNING v.id
        """, list(bill_ids))
        print(f"   strict: {len(strict)} linked")

        fuzzy = await conn.fetch("""
          WITH cands AS (
            SELECT id, invoice_date, total FROM xero_bills
             WHERE id = ANY($1::bigint[]) AND total IS NOT NULL AND total > 0
          ),
          pairs AS (
            SELECT i.id AS inbox_id, c.id AS bill_id,
                   ROW_NUMBER() OVER (PARTITION BY i.id ORDER BY ABS(c.invoice_date - i.invoice_date), c.id) AS i_rank,
                   ROW_NUMBER() OVER (PARTITION BY c.id ORDER BY ABS(c.invoice_date - i.invoice_date), i.id) AS b_rank
              FROM vendor_invoice_inbox i
              JOIN cands c
                ON i.invoice_date BETWEEN c.invoice_date - INTERVAL '1 day' AND c.invoice_date + INTERVAL '1 day'
               AND ABS(COALESCE(i.gross_amount, i.amount_seen, 0) - c.total) < 1.00
               AND COALESCE(i.gross_amount, i.amount_seen) > 0
             WHERE i.xero_bill_id IS NULL
          ),
          unique_pairs AS (
            SELECT inbox_id, bill_id FROM pairs WHERE i_rank = 1 AND b_rank = 1
          )
          UPDATE vendor_invoice_inbox v SET xero_bill_id = up.bill_id
            FROM unique_pairs up WHERE v.id = up.inbox_id RETURNING v.id
        """, list(bill_ids))
        print(f"   fuzzy:  {len(fuzzy)} linked")

    print(f"\n== Summary:")
    print(f"  bills inserted: {t_ins}")
    print(f"  bills updated:  {t_upd}")
    print(f"  line items:     {t_lines}")
    await conn.close()

asyncio.run(main())
PYEOF

EXIT=$?

if [[ $EXIT -eq 0 ]]; then
  for f in "${FILES[@]}"; do
    if [[ "$f" == "$INBOX_DIR"/* ]]; then
      mv "$f" "$ARCHIVE_DIR/" 2>/dev/null && echo "  archived: $(basename "$f")"
    fi
  done
fi

exit $EXIT
