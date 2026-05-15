#!/usr/bin/env bash
#
# u59-credit-card-csv-import.sh — import RBS Mastercard CSV exports into
# bank_accounts + bank_transactions. Mirrors u58-natwest-statement-import.sh
# but for credit-card data shape.
#
# CSV columns: Date,Type,Description,Value,Balance,Account Name,Account Number
#   - Type ∈ {PURCHASE, PAYMENT, FEES} (blank on balance-marker rows)
#   - Value sign convention (credit-card side):
#       positive  = charge to card  (you owe more)
#       negative  = payment / refund / write-off (you owe less)
#   - "Balance as at YYYY-MM-DD" rows are summary lines — skipped on import.
#
# Idempotent — idempotency_key = sha256(account_number|date|value|balance|desc).
#
# Maps the 3 cards (entity=3 Personal, realm=family per Jo 2026-05-14):
#   552085******8864 — dormant card, mostly interest/write-off
#   552085******2621 — Jo personal mastercard #1
#   552085******3092 — Jo personal mastercard #2 (most active)

set -euo pipefail

CSV_DIR_HOST="${1:-/home_ai/data/credit-card-inbox/2026-05-14}"
CSV_DIR_CTR="/tmp/cc-csv"
DRY_RUN="${DRY_RUN:-0}"

VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PG_PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/postgres)
PG_DSN="postgresql://postgres:${PG_PW}@homeai-postgres:5432/homeai"
unset VT PG_PW

docker exec homeai-bot-responder mkdir -p "${CSV_DIR_CTR}"
docker exec homeai-bot-responder rm -f "${CSV_DIR_CTR}"/*.csv 2>/dev/null || true
# Copy ONLY the CSVs (the dir also has 71 PDFs which are handled by u59b).
for f in "${CSV_DIR_HOST}"/*.csv; do
    docker cp "$f" "homeai-bot-responder:${CSV_DIR_CTR}/"
done

docker exec -i -e PG_DSN="${PG_DSN}" -e DRY_RUN="${DRY_RUN}" -e CSV_DIR="${CSV_DIR_CTR}" \
    homeai-bot-responder python <<'PYEOF'
import asyncio, asyncpg, os, csv, glob, hashlib
from datetime import datetime

CSV_DIR = os.environ["CSV_DIR"]
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"

# Masked account number → (entity_id, realm, account_name, account_type)
# Drop the bank-side asterisks for our storage; the bank itself never gave
# us the full PAN in the CSV, so we keep the masked form verbatim.
ACCOUNTS = {
    "552085******8864": (3, "family",
                         "RBS Mastercard ****8864 (Jo personal, dormant)",
                         "credit_card"),
    "552085******2621": (3, "family",
                         "RBS Mastercard ****2621 (Jo personal #1)",
                         "credit_card"),
    "552085******3092": (3, "family",
                         "RBS Mastercard ****3092 (Jo personal #2, active)",
                         "credit_card"),
}

# RBS issues 16-digit Mastercards, BIN 552085. No sort code — we record the
# 6-digit BIN as the sort_code-equivalent for table-shape symmetry with NatWest.
BIN_AS_SORT = "552085"
SOURCE_TAG = "rbs_cc_csv_2026_05_14"
BALANCE_MARKER = "Balance as at"

def parse_date(d):
    return datetime.strptime(d.strip(), "%d %b %Y").date()

def idem_key(acc_num, date, value, balance, desc):
    raw = f"{acc_num}|{date.isoformat()}|{value}|{balance}|{desc}".encode()
    return hashlib.sha256(raw).hexdigest()[:32]

async def main():
    conn = await asyncpg.connect(os.environ["PG_DSN"])
    await conn.fetchval("SELECT set_config('app.current_entity', 'all',   false)")
    await conn.fetchval("SELECT set_config('app.current_realm',  'owner', false)")

    print(f"RBS credit-card CSV import — {'DRY RUN' if DRY_RUN else 'WRITING'}")
    print(f"  source dir = {CSV_DIR}")

    # 1. Upsert bank_accounts (3 cards). The "account_number" we store is the
    #    masked form because that's all the CSV gives us — re-imports keep
    #    keying on the same string so idempotency holds.
    print(f"\n[1/3] bank_accounts ({len(ACCOUNTS)} rows)")
    acct_id_by_num = {}
    for masked, (entity, realm, name, atype) in ACCOUNTS.items():
        existing = await conn.fetchrow(
            "SELECT id FROM bank_accounts WHERE account_number=$1 AND bank_name='RBS Mastercard'",
            masked)
        if existing:
            acct_id_by_num[masked] = existing["id"]
            print(f"  EXISTS  {masked}  id={existing['id']:3}  {name}")
            continue
        if DRY_RUN:
            acct_id_by_num[masked] = -1
            print(f"  WOULD   {masked}            entity={entity} realm={realm}  {name}")
            continue
        row = await conn.fetchrow("""
            INSERT INTO bank_accounts
                (entity_id, bank_name, account_name, account_number, sort_code, account_type, realm)
            VALUES ($1, 'RBS Mastercard', $2, $3, $4, $5, $6) RETURNING id
        """, entity, name, masked, BIN_AS_SORT, atype, realm)
        acct_id_by_num[masked] = row["id"]
        print(f"  CREATED {masked}  id={row['id']:3}  entity={entity} realm={realm}  {name}")

    # 2. Walk CSVs.
    csvs = sorted(glob.glob(CSV_DIR + "/*.csv"))
    print(f"\n[2/3] bank_transactions across {len(csvs)} CSV(s)")
    counts = {"inserted": 0, "skipped_dup": 0, "skipped_unknown_acct": 0,
              "skipped_balance_marker": 0, "by_acct": {}}

    for path in csvs:
        with open(path) as f:
            for row in csv.DictReader(f):
                acct_full = row["Account Number"].strip()
                if acct_full not in ACCOUNTS:
                    counts["skipped_unknown_acct"] += 1
                    continue
                if (row.get("Type") or "").strip() == "" \
                        and BALANCE_MARKER in (row.get("Description") or ""):
                    counts["skipped_balance_marker"] += 1
                    continue

                entity, realm, _, _ = ACCOUNTS[acct_full]
                tx_date = parse_date(row["Date"])
                value   = float(row["Value"]) if row["Value"].strip() else 0.0
                balance = float(row["Balance"]) if row["Balance"].strip() else None
                desc    = (row.get("Description") or "").strip()
                key     = idem_key(acct_full, tx_date, value, balance, desc)

                counts["by_acct"].setdefault(acct_full, 0)

                if DRY_RUN:
                    counts["inserted"] += 1
                    counts["by_acct"][acct_full] += 1
                    continue

                result = await conn.fetchrow("""
                    INSERT INTO bank_transactions
                        (idempotency_key, bank_account_id, entity_id, transaction_date,
                         description, amount, balance, source, realm)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
                    ON CONFLICT (idempotency_key) DO NOTHING
                    RETURNING id
                """, key, acct_id_by_num[acct_full], entity, tx_date, desc,
                     value, balance, SOURCE_TAG, realm)
                if result:
                    counts["inserted"] += 1
                    counts["by_acct"][acct_full] += 1
                else:
                    counts["skipped_dup"] += 1

    print(f"  inserted                = {counts['inserted']:>6}")
    print(f"  skipped (duplicate key) = {counts['skipped_dup']:>6}")
    print(f"  skipped (unknown acct)  = {counts['skipped_unknown_acct']:>6}")
    print(f"  skipped (balance line)  = {counts['skipped_balance_marker']:>6}")
    print()
    print("  Per-account counts:")
    for acct_full, n in sorted(counts["by_acct"].items()):
        ent, rlm, name, _ = ACCOUNTS[acct_full]
        print(f"    {acct_full}  entity={ent} realm={rlm:6}  +{n:>4}  {name}")

    # 3. Post-import totals.
    print(f"\n[3/3] post-import totals (credit_card accounts)")
    rows = await conn.fetch("""
      SELECT ba.account_name, ba.entity_id, ba.realm,
             COUNT(bt.id) AS n,
             MIN(bt.transaction_date) AS dfirst,
             MAX(bt.transaction_date) AS dlast,
             SUM(bt.amount)::numeric(12,2) AS net_period_value
        FROM bank_accounts ba
   LEFT JOIN bank_transactions bt ON bt.bank_account_id = ba.id
       WHERE ba.account_type = 'credit_card'
    GROUP BY ba.id, ba.account_name, ba.entity_id, ba.realm
    ORDER BY ba.id
    """)
    for r in rows:
        print(f"  ent={r['entity_id']} realm={r['realm']:6} n={r['n']:>4}  "
              f"{r['dfirst']}..{r['dlast']}  net={r['net_period_value']!s:>10}  "
              f"{r['account_name']}")

    await conn.close()

asyncio.run(main())
PYEOF
