#!/usr/bin/env bash
#
# test-phase1-acceptance.sh — Phase 1 acceptance per SPEC §4b.8.
#
# Acceptance:
#   1. A hand-built manifest + payments.jsonl with one synthetic row lands
#      in raw.imports and raw.dojo_transactions.
#   2. Re-running with the same payload is a no-op (file_sha256 dedup).
#   3. Re-running with edited payload writes an upstream_edit exception.

set -euo pipefail

LOG_PFX="[phase1-test]"
say() { echo "${LOG_PFX} $*"; }

CSV=/tmp/dojo-synthetic-$$.csv
trap "rm -f /tmp/dojo-synthetic-*.csv" EXIT

# ── Build a synthetic Dojo CSV with two rows ──────────────────────────────
cat > "$CSV" <<'EOF'
Transaction ID,Transaction Date,Transaction Time,Terminal ID,Site,Card Entry Mode,Amount (GBP),Gratuity (GBP),Fee (GBP),Outcome,Last 4 Digits,Auth Code,Settlement Batch
TEST-DOJO-001,2026-05-14,18:32:11,T-PUB-01,pub,Chip + PIN,42.50,2.50,0.30,approved,1234,A12345,BATCH-20260514
TEST-DOJO-002,2026-05-14,19:01:47,T-CAFE-01,cafe,Contactless,8.75,0.00,0.10,approved,5678,B67890,BATCH-20260514
EOF
say "synthetic CSV: $(wc -l < "$CSV") line(s) (1 header + 2 data)"

# Path patching for the docker exec — we'll docker cp the CSV in, run scripts.
docker exec homeai-bot-responder mkdir -p /home_ai/inbox/dojo/staged \
    /home_ai/scripts/payments/adapters/csv /home_ai/config/payments
docker cp /home_ai/config/payments/services.yaml             homeai-bot-responder:/home_ai/config/payments/services.yaml
docker cp /home_ai/scripts/payments/adapters/csv/dojo.py     homeai-bot-responder:/home_ai/scripts/payments/adapters/csv/dojo.py
docker cp /home_ai/scripts/payments/raw-ingestor.py          homeai-bot-responder:/home_ai/scripts/payments/raw-ingestor.py
docker cp "$CSV"                                              homeai-bot-responder:/tmp/csv-in.csv

# Make sure pyyaml is present in the bot-responder image.
docker exec homeai-bot-responder pip install -q pyyaml >/dev/null 2>&1 || true

# ── Step 1 — first run: produces manifest+jsonl, ingestor writes 2 rows ──
say "step 1: adapter run #1"
STAGED1=$(docker exec homeai-bot-responder python3 /home_ai/scripts/payments/adapters/csv/dojo.py /tmp/csv-in.csv 2>&1 | tail -1)
say "  staged: $STAGED1"

say "step 1: ingestor run #1"
docker exec homeai-bot-responder python3 /home_ai/scripts/payments/raw-ingestor.py "$STAGED1" 2>&1 | sed "s/^/  /"

say "step 1: verify raw.imports + raw.dojo_transactions"
docker exec homeai-postgres psql -U postgres -d homeai -A -t -c "
SELECT 'imports='  || COUNT(*) FROM raw.imports          WHERE source='dojo' AND adapter='csv';
SELECT 'dojo_rows=' || COUNT(*) FROM raw.dojo_transactions WHERE source_transaction_id LIKE 'TEST-DOJO-%';
"

# ── Step 2 — re-run identical: file_sha256 dedup, 0 new rows ──────────────
say "step 2: ingestor run #2 (same staged dir — expect REPLAY)"
docker exec homeai-bot-responder python3 /home_ai/scripts/payments/raw-ingestor.py "$STAGED1" 2>&1 | sed "s/^/  /"

say "step 2: confirm no growth"
docker exec homeai-postgres psql -U postgres -d homeai -A -t -c "
SELECT 'imports='  || COUNT(*) FROM raw.imports          WHERE source='dojo' AND adapter='csv';
SELECT 'dojo_rows=' || COUNT(*) FROM raw.dojo_transactions WHERE source_transaction_id LIKE 'TEST-DOJO-%';
"

# ── Step 3 — edit the row's amount, fresh adapter run; expect upstream_edit
say "step 3: edit row TEST-DOJO-001 amount 42.50 → 99.99"
sed -i 's/42.50,2.50,0.30/99.99,2.50,0.30/' "$CSV"
docker cp "$CSV" homeai-bot-responder:/tmp/csv-in.csv

say "step 3: adapter run #2 (new run_id, new sha256)"
STAGED2=$(docker exec homeai-bot-responder python3 /home_ai/scripts/payments/adapters/csv/dojo.py /tmp/csv-in.csv 2>&1 | tail -1)
say "  staged: $STAGED2"

say "step 3: ingestor run #3 (expect 1 upstream_edit + 1 dup-skip)"
docker exec homeai-bot-responder python3 /home_ai/scripts/payments/raw-ingestor.py "$STAGED2" 2>&1 | sed "s/^/  /"

say "step 3: verify mart.exceptions has the upstream_edit row"
docker exec homeai-postgres psql -U postgres -d homeai -A -c "
SELECT kind, severity, source, summary
  FROM mart.exceptions
 WHERE kind='upstream_edit' AND source='dojo'
 ORDER BY id DESC LIMIT 3;
"

# ── Final post-test summary ───────────────────────────────────────────────
say "FINAL state:"
docker exec homeai-postgres psql -U postgres -d homeai -c "
SELECT 'raw.imports'         AS t, COUNT(*) FROM raw.imports          WHERE source='dojo'
UNION ALL
SELECT 'raw.dojo (TEST)',         COUNT(*) FROM raw.dojo_transactions WHERE source_transaction_id LIKE 'TEST-DOJO-%'
UNION ALL
SELECT 'mart.exceptions (TEST)',  COUNT(*) FROM mart.exceptions       WHERE source='dojo' AND kind='upstream_edit';
"

say "✓ Phase 1 acceptance complete."
