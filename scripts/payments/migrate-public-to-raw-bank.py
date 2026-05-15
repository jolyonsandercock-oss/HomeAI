#!/usr/bin/env python3
"""
migrate-public-to-raw-bank.py — Phase 2 of PART 4b.

Lifts the legacy public.bank_transactions rows (NatWest debit + RBS Mastercard
credit-card) into the new raw.bank_lines + staging.bank_lines shape, preserving
all idempotency keys and entity / realm tags.

Strategy (idempotent — safe to re-run):
  1. Create one synthetic raw.imports row per (source_tag, account_ref) tuple
     stamped operator='u65-migration', adapter='csv', first_seen_via='csv'.
     The file_sha256 is sha256 over the migrated rows' idempotency_keys —
     deterministic so re-runs match.
  2. For every public.bank_transactions row:
       - INSERT raw.bank_lines with source mapped (natwest_csv_… → natwest,
         rbs_cc_csv_… → rbs_mastercard), source_transaction_id = legacy
         idempotency_key, row_hash from canonical column subset.
       - INSERT staging.bank_lines with the normalised shape (signed
         amount_minor, is_settlement_candidate stays FALSE for the legacy
         pass — Phase 8 will set it via processor-name regex).
  3. Per AGENTS.md: ON CONFLICT DO NOTHING on every INSERT — re-running
     yields zero inserts. Counts at end prove migration completeness.

Source mapping:
  bank_name='NatWest'         → source='natwest'
  bank_name='RBS Mastercard'  → source='rbs_mastercard'

account_ref:
  Debit:  '<sort_code>-<account_number>'   (matches services.yaml)
  Credit: 'CC-<last4>'                      (PAN-derived; full PAN never used)

Sign convention in staging.bank_lines.amount_minor — signed; negative = outflow
from the *account holder's* cash position. NatWest CSV is already negative-
for-outflow. RBS CC is positive-for-spend = outflow, so we FLIP the sign.

Usage:
    python3 scripts/payments/migrate-public-to-raw-bank.py [--dry-run]
"""
from __future__ import annotations
import argparse
import asyncio
import asyncpg
import hashlib
import json
import os
import sys
import urllib.request
from datetime import datetime, date
from pathlib import Path


def vault_pg_dsn() -> str:
    if dsn := os.environ.get("PG_DSN"):
        return dsn
    token = os.environ["VAULT_TOKEN"]
    req = urllib.request.Request(
        "http://vault:8200/v1/secret/data/postgres",
        headers={"X-Vault-Token": token})
    data = json.loads(urllib.request.urlopen(req, timeout=5).read())
    pw = data["data"]["data"]["password"]
    return f"postgresql://postgres:{pw}@homeai-postgres:5432/homeai"


def source_for(bank_name: str) -> str:
    if bank_name == "NatWest":
        return "natwest"
    if bank_name == "RBS Mastercard":
        return "rbs_mastercard"
    raise ValueError(f"unknown bank_name {bank_name!r}")


def account_ref_for(ba: dict) -> str:
    if ba["account_type"] == "credit_card":
        # 552085******8864 → CC-8864
        return "CC-" + ba["account_number"][-4:]
    return f"{ba['sort_code']}-{ba['account_number']}"


def row_hash_for(d: dict) -> str:
    # Must match raw-ingestor.py:_hash_row exactly — excludes `source` (and
    # the meta cols below) so the migration and the adapter+ingestor path
    # both produce the same hash for the same row content.
    canonical = {k: d[k] for k in sorted(d)
                 if k not in ("row_hash", "import_id", "first_seen_via", "raw_payload", "source")}
    return hashlib.sha256(json.dumps(canonical, sort_keys=True, default=str).encode()).hexdigest()


async def run(dry_run: bool) -> int:
    conn = await asyncpg.connect(vault_pg_dsn())
    await conn.fetchval("SELECT set_config('app.current_entity', 'all', false)")
    await conn.fetchval("SELECT set_config('app.current_realm', 'owner', false)")

    # Load bank_accounts → id → row dict
    ba_rows = await conn.fetch("""
      SELECT id, bank_name, account_name, sort_code, account_number,
             account_type, entity_id, realm
        FROM bank_accounts
    """)
    ba_by_id = {r["id"]: dict(r) for r in ba_rows}
    print(f"[migrate] {len(ba_by_id)} bank_accounts loaded.")

    # Group public.bank_transactions by (source, account_ref) for one
    # synthetic raw.imports row per group.
    tx_rows = await conn.fetch("""
      SELECT bt.id, bt.idempotency_key, bt.bank_account_id, bt.entity_id,
             bt.transaction_date, bt.description, bt.amount, bt.balance,
             bt.source AS legacy_source, bt.realm
        FROM bank_transactions bt
       ORDER BY bt.bank_account_id, bt.transaction_date, bt.id
    """)
    print(f"[migrate] {len(tx_rows)} legacy bank_transactions rows.")

    # Bucket by (source, account_ref)
    buckets: dict[tuple[str, str], list[dict]] = {}
    for row in tx_rows:
        ba = ba_by_id[row["bank_account_id"]]
        source = source_for(ba["bank_name"])
        account_ref = account_ref_for(ba)
        buckets.setdefault((source, account_ref), []).append({
            "row": row, "ba": ba, "source": source, "account_ref": account_ref})

    print(f"[migrate] {len(buckets)} (source, account_ref) bucket(s).")
    if dry_run:
        for (src, ref), items in sorted(buckets.items()):
            print(f"  WOULD  {src:<16} {ref:<22}  rows={len(items):>5}")
        await conn.close()
        return 0

    # For each bucket: synthesise a raw.imports row, then bulk-INSERT raw+staging.
    totals = {"imports_new": 0, "raw_new": 0, "raw_dup": 0,
              "stg_new": 0, "stg_dup": 0}

    for (source, account_ref), items in sorted(buckets.items()):
        # Deterministic sha256 over the sorted idempotency keys — stable across
        # re-runs so file_sha256 dedup works.
        keys = sorted(it["row"]["idempotency_key"] for it in items)
        file_sha256 = hashlib.sha256("\n".join(keys).encode()).hexdigest()

        captured_at = datetime.now()  # marker only; real source is the migration
        manifest = {
            "$schema": "https://homeai.local/schemas/payment-ingest-manifest-v1.json",
            "manifest_version": 1,
            "source": source,
            "adapter": "csv",
            "run_id": f"u65-migration-{source}-{account_ref}",
            "captured_at": captured_at.isoformat(),
            "scope": {"account_ref": account_ref},
            "credentials_path": "secret/payments/natwest/identity",
            "payload_filename": "(legacy public.bank_transactions migration)",
            "payload_row_count": len(items),
            "payload_sha256": file_sha256,
            "operator": "u65-migration",
            "notes": "Lifted from public.bank_transactions in-place; "
                     "no source CSV/API artifact exists.",
        }

        import_row = await conn.fetchrow("""
          INSERT INTO raw.imports
              (source, adapter, file_sha256, payload_path, manifest_json,
               captured_at, row_count, operator, realm)
          VALUES ($1, 'csv', $2, $3, $4::jsonb, $5, $6, $7, 'work')
          ON CONFLICT (source, file_sha256) DO NOTHING
          RETURNING id
        """, source, file_sha256,
             f"public.bank_transactions:{source}:{account_ref}",
             json.dumps(manifest), captured_at, len(items), "u65-migration")

        if import_row is None:
            # Already done in a previous run — pull the existing id.
            existing = await conn.fetchval(
                "SELECT id FROM raw.imports WHERE source=$1 AND file_sha256=$2",
                source, file_sha256)
            import_id = existing
            print(f"  REPLAY {source:<16} {account_ref:<22}  raw.imports.id={import_id} (existing)")
        else:
            import_id = import_row["id"]
            totals["imports_new"] += 1
            print(f"  NEW    {source:<16} {account_ref:<22}  raw.imports.id={import_id}  rows={len(items)}")

        for it in items:
            row, ba = it["row"], it["ba"]
            legacy_id = row["idempotency_key"]
            # Normalised amount to staging convention: negative = outflow.
            # NatWest is already that way; CC is opposite (positive=spend=outflow), flip.
            amount = float(row["amount"]) if row["amount"] is not None else 0.0
            if ba["account_type"] == "credit_card":
                amount = -amount  # flip sign for staging
            amount_minor = int(round(amount * 100))
            balance_minor = int(round(float(row["balance"]) * 100)) if row["balance"] is not None else None

            raw_payload = {
                "legacy_id": row["id"],
                "legacy_source": row["legacy_source"],
                "description": row["description"],
                "raw_amount": float(row["amount"]) if row["amount"] is not None else None,
            }
            mapped_raw = {
                "source": source,
                "source_transaction_id": legacy_id,
                "transaction_date": row["transaction_date"],
                "posted_at_utc": None,
                "account_ref": account_ref,
                "type_code": None,
                "description": row["description"] or "",
                "amount_minor": int(round(float(row["amount"]) * 100)) if row["amount"] is not None else 0,
                "balance_after_minor": balance_minor,
                "counterparty_name": None,
                "counterparty_ref": None,
                "entity_id": row["entity_id"],
                "raw_payload": raw_payload,
            }
            mapped_raw["row_hash"] = row_hash_for(mapped_raw)

            raw_result = await conn.fetchrow("""
              INSERT INTO raw.bank_lines (
                  source, source_transaction_id, row_hash, first_seen_via, import_id,
                  transaction_date, posted_at_utc, account_ref, type_code, description,
                  amount_minor, balance_after_minor, counterparty_name, counterparty_ref,
                  raw_payload, realm, entity_id)
              VALUES ($1, $2, $3, 'csv', $4, $5, NULL, $6, NULL, $7, $8, $9, NULL, NULL, $10::jsonb, $11, $12)
              ON CONFLICT (source, source_transaction_id, transaction_date) DO NOTHING
              RETURNING id
            """, source, legacy_id, mapped_raw["row_hash"], import_id,
                 row["transaction_date"], account_ref, row["description"] or "",
                 mapped_raw["amount_minor"], balance_minor,
                 json.dumps(raw_payload), row["realm"] or "work", row["entity_id"])

            raw_id = None
            if raw_result:
                raw_id = raw_result["id"]
                totals["raw_new"] += 1
            else:
                raw_id_row = await conn.fetchval(
                    "SELECT id FROM raw.bank_lines WHERE source=$1 AND source_transaction_id=$2 AND transaction_date=$3",
                    source, legacy_id, row["transaction_date"])
                raw_id = raw_id_row
                totals["raw_dup"] += 1

            # Staging row — normalised sign convention.
            stg_result = await conn.fetchrow("""
              INSERT INTO staging.bank_lines (
                  raw_id, source, source_transaction_id, transaction_date,
                  account_ref, entity_id, type_code, description, amount_minor,
                  counterparty_name, counterparty_ref,
                  is_settlement_candidate, is_fee, realm)
              VALUES ($1, $2, $3, $4, $5, $6, NULL, $7, $8, NULL, NULL, FALSE, FALSE, $9)
              ON CONFLICT (source, source_transaction_id, transaction_date) DO NOTHING
              RETURNING id
            """, raw_id, source, legacy_id, row["transaction_date"],
                 account_ref, row["entity_id"], row["description"] or "",
                 amount_minor, row["realm"] or "work")
            if stg_result:
                totals["stg_new"] += 1
            else:
                totals["stg_dup"] += 1

    print()
    print(f"[migrate] {'raw.imports new':<20}  {totals['imports_new']:>6}")
    print(f"[migrate] {'raw.bank_lines new':<20}  {totals['raw_new']:>6}  "
          f"dup-skipped {totals['raw_dup']:>5}")
    print(f"[migrate] {'staging.bank_lines new':<20}  {totals['stg_new']:>6}  "
          f"dup-skipped {totals['stg_dup']:>5}")

    # Acceptance: legacy count == staging count.
    legacy_n = await conn.fetchval("SELECT COUNT(*) FROM bank_transactions")
    staging_n = await conn.fetchval("SELECT COUNT(*) FROM staging.bank_lines")
    print()
    print(f"[migrate] ACCEPTANCE: legacy={legacy_n}  staging={staging_n}  delta={staging_n - legacy_n}")
    if legacy_n != staging_n:
        print(f"[migrate] WARN: counts do not match; investigate before declaring Phase 2 done.")

    await conn.close()
    return 0


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    # Run inside homeai-bot-responder (has asyncpg + vault access).
    if not Path("/.dockerenv").exists() and os.environ.get("PG_DSN") is None:
        sys.exit("ERROR: run inside homeai-bot-responder container "
                 "(no asyncpg + no PG_DSN env). "
                 "Use: docker exec -i homeai-bot-responder python /home_ai/scripts/payments/migrate-public-to-raw-bank.py")
    sys.exit(asyncio.run(run(args.dry_run)))
