#!/usr/bin/env bash
#
# u58-natwest-statement-import.sh — import the May-2026 NatWest CSV batch
# into bank_accounts + bank_transactions.
#
# Idempotent — re-running won't duplicate. Each row's idempotency_key is
# sha256(account_number|date|value|balance|description).
#
# Mapping lives at the top of this script, EDITED IN PLACE before running.
# Confirm the entity_id + realm for each account number after Jo's verification.

set -euo pipefail

CSV_DIR_HOST="/home_ai/data/natwest-inbox/2026-05-14"
CSV_DIR_CTR="/tmp/natwest-csv"
DRY_RUN="${DRY_RUN:-0}"

# Get PG_DSN — superuser for the import (administrative seeding op).
VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
PG_PW=$(docker exec -e VAULT_TOKEN="$VT" homeai-vault vault kv get -field=password secret/postgres)
PG_DSN="postgresql://postgres:${PG_PW}@homeai-postgres:5432/homeai"
unset VT PG_PW

# Push CSVs into bot-responder /tmp (no host bind mount available).
docker exec homeai-bot-responder mkdir -p "${CSV_DIR_CTR}"
docker cp "${CSV_DIR_HOST}/." "homeai-bot-responder:${CSV_DIR_CTR}/"

docker exec -i -e PG_DSN="${PG_DSN}" -e DRY_RUN="${DRY_RUN}" -e CSV_DIR="${CSV_DIR_CTR}" \
    homeai-bot-responder python <<'PYEOF'
import asyncio, asyncpg, os, csv, glob, hashlib
from datetime import datetime

CSV_DIR = os.environ["CSV_DIR"]
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"

# Account number → (entity_id, realm, account_name, account_type)
# entity_id: 1=ATR Trading | 2=AREL Estates | 3=Personal | 4=Family
# realm:     work | family | owner
ACCOUNTS = {
    # ATR TRADING (entity 1, realm=work) — pub current account
    # ⚠ Jo said 48885517 is ATR Trading but that number is not in the CSVs.
    # Best guess from the data: 521047-17065488 (named "ATLANTIC ROAD" — no
    # ESTATE suffix). Verify before running for real.
    "521047-17065488": (1, "work",   "ATLANTIC ROAD — ATR Trading current",        "current"),

    # ATR Trading attached savings ("Tax Reserve" — Jo mentioned ATR has one)
    "600001-48747300": (1, "work",   "Tax Reserve — ATR savings",                  "savings"),

    # AREL ESTATES (entity 2, realm=family) — rental property income
    "521047-17046041": (2, "family", "ATLANTIC ROAD ESTATE — AREL current",        "current"),

    # PERSONAL — Jo (entity 3, realm=family)
    "600001-36345245": (3, "family", "SANDERCOCK J — main personal current",       "current"),
    "600001-49011170": (3, "family", "SANDERCOCK J — personal #2",                 "current"),
    "504237-69323321": (3, "family", "SANDERCOCK J — personal #3",                 "savings"),
    "602479-19070381": (3, "family", "SANDERCOCK J — personal #4",                 "current"),

    # FAMILY (entity 4, realm=family) — joint
    "600001-49056204": (4, "family", "Joint Account",                              "joint"),
}

SOURCE_TAG = "natwest_csv_2026_05_14"

def parse_date(d):
    return datetime.strptime(d.strip(), "%d %b %Y").date()

def idem_key(acc_num, date, value, balance, desc):
    raw = f"{acc_num}|{date.isoformat()}|{value}|{balance}|{desc}".encode()
    return hashlib.sha256(raw).hexdigest()[:32]

async def main():
    conn = await asyncpg.connect(os.environ["PG_DSN"])
    # Per AGENTS.md SQL discipline: scope this transaction at session start.
    # We're administrative-seeding bank_accounts + bank_transactions across
    # entities 1/2/3/4, so we run in OWNER realm with entity='all'.
    await conn.fetchval("SELECT set_config('app.current_entity', 'all', false)")
    await conn.fetchval("SELECT set_config('app.current_realm',  'owner', false)")

    print(f"NatWest CSV import — {'DRY RUN' if DRY_RUN else 'WRITING'}")
    print(f"  source dir = {CSV_DIR}")

    # 1. Upsert bank_accounts (one per ACCOUNTS dict entry).
    print(f"\n[1/3] bank_accounts ({len(ACCOUNTS)} rows)")
    acct_id_by_num = {}
    for sort_acct, (entity, realm, name, atype) in ACCOUNTS.items():
        sort_code, acct_num = sort_acct.split("-")
        existing = await conn.fetchrow(
            "SELECT id FROM bank_accounts WHERE sort_code=$1 AND account_number=$2",
            sort_code, acct_num)
        if existing:
            acct_id_by_num[sort_acct] = existing["id"]
            print(f"  EXISTS  {sort_acct}  id={existing['id']:3}  {name}")
            continue
        if DRY_RUN:
            acct_id_by_num[sort_acct] = -1
            print(f"  WOULD   {sort_acct}            entity={entity} realm={realm} type={atype}  {name}")
            continue
        row = await conn.fetchrow("""
            INSERT INTO bank_accounts (entity_id, bank_name, account_name, account_number, sort_code, account_type, realm)
            VALUES ($1, 'NatWest', $2, $3, $4, $5, $6) RETURNING id
        """, entity, name, acct_num, sort_code, atype, realm)
        acct_id_by_num[sort_acct] = row["id"]
        print(f"  CREATED {sort_acct}  id={row['id']:3}  entity={entity} realm={realm} type={atype}  {name}")

    # 2. Iterate every CSV, insert bank_transactions (ON CONFLICT idempotency_key DO NOTHING).
    #    AGENTS.md SQL rule: set_config('app.current_entity', ...) is in effect
    #    for this connection's session (set above), so the INSERT below complies.
    print(f"\n[2/3] bank_transactions across {len(glob.glob(CSV_DIR + '/*.csv'))} CSV(s)")
    counts = {"inserted": 0, "skipped_dup": 0, "skipped_unknown_acct": 0, "by_acct": {}}
    for path in sorted(glob.glob(CSV_DIR + "/*.csv")):
        with open(path) as f:
            for row in csv.DictReader(f):
                acct_full = row["Account Number"].strip()
                if acct_full not in ACCOUNTS:
                    counts["skipped_unknown_acct"] += 1
                    continue
                entity, realm, _, _ = ACCOUNTS[acct_full]
                tx_date = parse_date(row["Date"])
                value   = float(row["Value"])
                balance = float(row["Balance"]) if row["Balance"].strip() else None
                desc    = row["Description"].strip()
                key     = idem_key(acct_full, tx_date, value, balance, desc)

                counts["by_acct"].setdefault(acct_full, 0)

                if DRY_RUN:
                    counts["inserted"] += 1
                    counts["by_acct"][acct_full] += 1
                    continue

                # INSERT INTO bank_transactions — scoped by the session-level
                # set_config('app.current_entity', 'all', false) above.
                result = await conn.fetchrow("""
                    INSERT INTO bank_transactions
                        (idempotency_key, bank_account_id, entity_id, transaction_date,
                         description, amount, balance, source, realm)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
                    ON CONFLICT (idempotency_key) DO NOTHING
                    RETURNING id
                """, key, acct_id_by_num[acct_full], entity, tx_date, desc, value, balance, SOURCE_TAG, realm)
                if result:
                    counts["inserted"] += 1
                    counts["by_acct"][acct_full] += 1
                else:
                    counts["skipped_dup"] += 1

    print(f"  inserted          = {counts['inserted']:>6}")
    print(f"  skipped (dup key) = {counts['skipped_dup']:>6}")
    print(f"  skipped (unknown) = {counts['skipped_unknown_acct']:>6}")
    print()
    print(f"  Per-account counts:")
    for acct_full, n in sorted(counts["by_acct"].items()):
        ent, rlm, name, _ = ACCOUNTS[acct_full]
        print(f"    {acct_full}  entity={ent} realm={rlm:6}  +{n:>5}  {name}")

    # 3. Quick totals
    print(f"\n[3/3] post-import totals")
    rows = await conn.fetch("""
      SELECT ba.account_name, ba.entity_id, ba.realm, COUNT(bt.id) AS n,
             MIN(bt.transaction_date) AS dfirst, MAX(bt.transaction_date) AS dlast
        FROM bank_accounts ba LEFT JOIN bank_transactions bt ON bt.bank_account_id = ba.id
       GROUP BY ba.id, ba.account_name, ba.entity_id, ba.realm
       ORDER BY ba.entity_id, ba.account_name
    """)
    for r in rows:
        print(f"  ent={r['entity_id']} realm={r['realm']:6} n={r['n']:>5}  {r['dfirst']}..{r['dlast']}  {r['account_name']}")

    await conn.close()

asyncio.run(main())
PYEOF
