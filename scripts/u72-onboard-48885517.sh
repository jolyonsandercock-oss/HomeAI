#!/usr/bin/env bash
# u72-onboard-48885517.sh — onboard a NatWest CSV for the ATR Trading
# second current account (48885517), where Dojo deposits land.
#
# Usage:
#   ./u72-onboard-48885517.sh /path/to/natwest-export.csv
#
# Idempotent: re-running with the same CSV is safe — raw.bank_lines uses a
# 3-layer dedup key (file_sha256, source_transaction_id, row_hash), so any
# rows already ingested are skipped.

set -euo pipefail

CSV="${1:-}"
if [[ -z "$CSV" ]]; then
    echo "Usage: $0 <natwest-export.csv>" >&2
    exit 1
fi
if [[ ! -f "$CSV" ]]; then
    echo "ERROR: CSV not found: $CSV" >&2
    exit 1
fi

echo "→ Onboarding $CSV via natwest adapter"

# 1. Verify bank_accounts has the row (idempotent guard — V92 inserted it,
#    but this lets the script stand alone).
docker exec -i homeai-postgres psql -U postgres -d homeai >/dev/null <<'SQL'
SELECT set_config('app.current_entity','1',false);
SELECT home_ai.set_realm('work');
INSERT INTO bank_accounts (entity_id, bank_name, account_name, account_number, sort_code, account_type, realm)
SELECT 1, 'NatWest',
       'ATLANTIC ROAD TRADING — current #2 (Dojo settlement)',
       '48885517', '521047', 'current', 'work'
 WHERE NOT EXISTS (SELECT 1 FROM bank_accounts WHERE account_number='48885517');
SQL

# 2. Stage via adapter (writes /home_ai/inbox/natwest/staged/<date>/<run_id>/).
STAGED=$(python3 /home_ai/scripts/payments/adapters/csv/natwest.py "$CSV" 2>&1 | tee /dev/stderr \
         | awk -F'→ ' '/\[adapter:csv:natwest\]/ {print $2}' | tail -1)

if [[ -z "$STAGED" ]]; then
    echo "ERROR: adapter did not emit a staged directory" >&2
    exit 1
fi
echo "→ Staged at: $STAGED"

# 3. Ingest via raw-ingestor (handles 3-layer dedup + raw.bank_lines).
python3 /home_ai/scripts/payments/raw-ingestor.py "$STAGED"

# 4. Migrate raw → public.bank_transactions via the existing path.
python3 /home_ai/scripts/payments/migrate-public-to-raw-bank.py 2>&1 | tail -5 || true

# 5. Report what landed for 48885517 specifically.
docker exec -i homeai-postgres psql -U postgres -d homeai -c "
SELECT count(*) AS rows_for_48885517,
       min(transaction_date) AS earliest,
       max(transaction_date) AS latest
  FROM bank_transactions bt
  JOIN bank_accounts ba ON ba.id = bt.bank_account_id
 WHERE ba.account_number = '48885517';
"
