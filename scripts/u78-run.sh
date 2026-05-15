#!/usr/bin/env bash
# u78-run.sh — apply V96 migration, seed account_property_map with the
# Castle Rd water account, then ingest docs 23 (Clover) and 24 (water bill).
# Idempotent.
set -euo pipefail

MIGRATION=/home_ai/postgres/migrations/V96__clover_batches_and_account_map.sql
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

psql() { docker exec -i homeai-postgres psql -U postgres -d homeai -v ON_ERROR_STOP=1 "$@"; }

echo "== Step 1/4 — apply V96 migration =="
if psql -tA -c "SELECT 1 FROM information_schema.tables WHERE table_name='clover_batches';" | grep -q 1; then
    echo "  • already applied (clover_batches exists)"
else
    psql < "$MIGRATION"
    echo "  ✓ V96 applied"
fi

echo
echo "== Step 2/4 — seed account_property_map (Castle Rd / South West Water) =="
# Property #3 = '1 Castle Road', entity 3 (Personal). Account 2972 3187 02.
psql <<'SQL'
SET app.current_entity = '3';
INSERT INTO account_property_map (
    vendor_domain, vendor_name, account_number, account_display,
    entity_id, property_id, site, category_canonical, realm, created_by, notes
) VALUES (
    'source4b.co.uk',
    'Source for Business (South West Water)',
    '2972318702',
    '2972 3187 02',
    3, 3, 'castle-rd', 'utility_water', 'owner',
    'u78-bootstrap',
    'Water + sewerage for Shop & Flat 1 Castle Rd Tintagel'
) ON CONFLICT (vendor_domain, account_number) DO NOTHING;
SELECT 'seeded' AS status, COUNT(*) AS rows_in_map FROM account_property_map;
SQL

echo
echo "== Step 3/4 — ingest Clover statement (doc 23 → clover_batches) =="
python3 "$SCRIPT_DIR/u78-ingest-clover.py" 23 --entity-id 1 --site accom

echo
echo "== Step 4/4 — ingest water bill (doc 24 → vendor_invoice_inbox) =="
python3 "$SCRIPT_DIR/u78-ingest-utility.py" 24 --default-entity-id 3

echo
echo "== Verification =="
psql -c "SELECT COUNT(*) AS batches, SUM(gross_amount) AS gross_total FROM clover_batches;"
psql -c "SELECT date, batch_count, gross_sales, visa_total, mastercard_total FROM v_clover_daily ORDER BY date;"
psql -c "
SELECT id, entity_id, vendor_name, account, amount_seen, invoice_date, due_date, status
  FROM vendor_invoice_inbox
 WHERE source_email_id LIKE 'scan:%'
 ORDER BY id DESC LIMIT 5;"
psql -c "SELECT id, raw_subject, status FROM bot_instructions WHERE source='scan-ingest' AND status='pending';"
echo
echo "Done."
