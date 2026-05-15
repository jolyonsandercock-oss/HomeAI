#!/usr/bin/env python3
"""
migrate-public-to-staging-payments.py — lift public.dojo_transactions into
staging.payments via raw.dojo_transactions. U67 wrap of PART 4b Phase 5.

Mirrors the U65 bank-migration pattern: one synthetic raw.imports row per
(source, site) bucket; idempotent ON CONFLICT DO NOTHING; legacy count
matches staging count when done.
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
from datetime import datetime, date as _date


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


def row_hash(d: dict) -> str:
    canonical = {k: d[k] for k in sorted(d)
                 if k not in ("row_hash", "import_id", "first_seen_via",
                              "raw_payload", "source")}
    return hashlib.sha256(
        json.dumps(canonical, sort_keys=True, default=str).encode()
    ).hexdigest()


def normalise_entry_mode(t: str | None) -> str | None:
    if not t:
        return None
    t = t.lower()
    if "chip" in t:        return "chip"
    if "contactless" in t: return "contactless"
    if "key" in t:         return "keyed"
    if "virtual" in t or t == "vt": return "vt"
    return t


def outcome_for(dojo_outcome: str, dojo_type: str) -> str:
    """Map Dojo's outcome+type into staging.payments.outcome semantics."""
    if dojo_outcome.lower() == "declined":
        return "declined"
    if dojo_type.lower() == "refund":
        return "refund"
    return "approved"


async def run(dry_run: bool) -> int:
    conn = await asyncpg.connect(vault_pg_dsn())
    await conn.fetchval("SELECT set_config('app.current_entity','all',false)")
    await conn.fetchval("SELECT set_config('app.current_realm','owner',false)")

    # Bucket by (source='dojo', site) for one synthetic raw.imports row each.
    rows = await conn.fetch("""
        SELECT id, transaction_id, mid, site, transaction_date, transaction_at,
               transaction_type, transaction_outcome, transaction_amount,
               cashback_amount, gratuity_amount, authorisation_code, realm
          FROM public.dojo_transactions
         ORDER BY site, transaction_date, id
    """)
    print(f"[migrate-dojo] {len(rows)} legacy public.dojo_transactions rows")

    buckets: dict[str, list] = {}
    for r in rows:
        buckets.setdefault(r["site"], []).append(r)

    print(f"[migrate-dojo] {len(buckets)} site bucket(s): {sorted(buckets.keys())}")
    if dry_run:
        for site, items in sorted(buckets.items()):
            print(f"  WOULD  dojo/{site:<8}  rows={len(items)}")
        await conn.close()
        return 0

    totals = {"imports_new": 0, "raw_new": 0, "raw_dup": 0,
              "stg_new": 0,     "stg_dup": 0,  "raw_part_missing": 0}

    for site, items in sorted(buckets.items()):
        keys = sorted(it["transaction_id"] for it in items)
        file_sha256 = hashlib.sha256("\n".join(keys).encode()).hexdigest()

        captured_at = datetime.now()
        manifest = {
            "$schema": "https://homeai.local/schemas/payment-ingest-manifest-v1.json",
            "manifest_version": 1,
            "source": "dojo",
            "adapter": "csv",
            "run_id": f"u67-migration-dojo-{site}",
            "captured_at": captured_at.isoformat(),
            "scope": {"site": site},
            "credentials_path": "secret/payments/dojo/api",
            "payload_filename": "(legacy public.dojo_transactions migration)",
            "payload_row_count": len(items),
            "payload_sha256": file_sha256,
            "operator": "u67-migration",
            "notes": "Lifted from public.dojo_transactions in-place.",
        }

        import_row = await conn.fetchrow("""
            INSERT INTO raw.imports
                (source, adapter, file_sha256, payload_path, manifest_json,
                 captured_at, row_count, operator, realm)
            VALUES ('dojo', 'csv', $1, $2, $3::jsonb, $4, $5, 'u67-migration', 'work')
            ON CONFLICT (source, file_sha256) DO NOTHING
            RETURNING id
        """, file_sha256, f"public.dojo_transactions:dojo:{site}",
             json.dumps(manifest), captured_at, len(items))

        if import_row is None:
            existing = await conn.fetchval(
                "SELECT id FROM raw.imports WHERE source='dojo' AND file_sha256=$1",
                file_sha256)
            import_id = existing
            print(f"  REPLAY dojo/{site:<8}  raw.imports.id={import_id}")
        else:
            import_id = import_row["id"]
            totals["imports_new"] += 1
            print(f"  NEW    dojo/{site:<8}  raw.imports.id={import_id}  rows={len(items)}")

        for r in items:
            tx_date = r["transaction_date"]
            tx_utc  = r["transaction_at"]  # already TIMESTAMPTZ
            amount_minor = int(round(float(r["transaction_amount"] or 0) * 100))
            gratuity_minor = int(round(float(r["gratuity_amount"] or 0) * 100)) if r["gratuity_amount"] else None

            mapped = {
                "source_transaction_id": r["transaction_id"],
                "transaction_date":      tx_date,
                "transaction_at_utc":    tx_utc,
                "terminal_id":           r["mid"] or "unknown",
                "site":                  r["site"],
                "entry_mode":            None,  # public.dojo doesn't carry entry_mode
                "amount_minor":          amount_minor,
                "gratuity_minor":        gratuity_minor,
                "fee_minor":             None,
                "refund_of":             None,
                "outcome":               outcome_for(r["transaction_outcome"], r["transaction_type"]),
                "last4_pan":             None,
                "auth_code":             r["authorisation_code"],
                "settlement_batch_id":   None,
                "raw_payload": {
                    "legacy_id": r["id"], "type": r["transaction_type"],
                    "outcome": r["transaction_outcome"],
                },
            }
            mapped["row_hash"] = row_hash(mapped)

            # Ensure month partition exists before insert.
            month_start = _date(tx_date.year, tx_date.month, 1)
            next_month = _date(tx_date.year + (1 if tx_date.month == 12 else 0),
                               1 if tx_date.month == 12 else tx_date.month + 1, 1)
            tag = month_start.strftime("%Y_%m")
            for parent in ("raw.dojo_transactions", "staging.payments"):
                sch, tbl = parent.split(".")
                part = f"{tbl}_{tag}"
                exists = await conn.fetchval(
                    "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname=$2",
                    sch, part)
                if not exists:
                    # DDL — can't parameterise; inline ISO dates.
                    await conn.execute(
                        f"CREATE TABLE {sch}.{part} PARTITION OF {parent} "
                        f"FOR VALUES FROM ('{month_start.isoformat()}') TO ('{next_month.isoformat()}')")
                    totals["raw_part_missing"] += 1

            raw_result = await conn.fetchrow("""
                INSERT INTO raw.dojo_transactions
                    (source, source_transaction_id, row_hash, first_seen_via, import_id,
                     transaction_date, transaction_at_utc, terminal_id, site, entry_mode,
                     amount_minor, gratuity_minor, fee_minor, refund_of, outcome,
                     last4_pan, auth_code, settlement_batch_id, raw_payload, realm)
                VALUES ('dojo', $1, $2, 'csv', $3, $4, $5, $6, $7, $8,
                        $9, $10, NULL, NULL, $11, NULL, $12, NULL, $13::jsonb, 'work')
                ON CONFLICT (source, source_transaction_id, transaction_date) DO NOTHING
                RETURNING id
            """, mapped["source_transaction_id"], mapped["row_hash"], import_id,
                 tx_date, tx_utc, mapped["terminal_id"], r["site"],
                 mapped["entry_mode"], amount_minor, gratuity_minor,
                 mapped["outcome"], mapped["auth_code"],
                 json.dumps(mapped["raw_payload"]))
            raw_id = raw_result["id"] if raw_result else \
                await conn.fetchval(
                    "SELECT id FROM raw.dojo_transactions WHERE source='dojo' AND source_transaction_id=$1 AND transaction_date=$2",
                    mapped["source_transaction_id"], tx_date)
            if raw_result:
                totals["raw_new"] += 1
            else:
                totals["raw_dup"] += 1

            # Compute net = gross - fee. fee unknown → net = gross.
            is_elev = mapped["entry_mode"] in ("keyed", "vt")

            stg_result = await conn.fetchrow("""
                INSERT INTO staging.payments
                    (raw_table, raw_id, source, source_transaction_id,
                     transaction_date, transaction_at_utc, site, terminal_id, entry_mode,
                     amount_gross_minor, fee_minor, amount_net_minor, outcome, refund_of,
                     last4_pan, settlement_batch_id, is_elevated_risk, realm)
                VALUES ('raw.dojo_transactions', $1, 'dojo', $2, $3, $4, $5, $6, $7,
                        $8, NULL, $8, $9, NULL, NULL, NULL, $10, 'work')
                ON CONFLICT (source, source_transaction_id, transaction_date) DO NOTHING
                RETURNING id
            """, raw_id, mapped["source_transaction_id"], tx_date, tx_utc,
                 r["site"], mapped["terminal_id"], mapped["entry_mode"],
                 amount_minor, mapped["outcome"], is_elev)
            if stg_result:
                totals["stg_new"] += 1
            else:
                totals["stg_dup"] += 1

    print()
    for k, v in totals.items():
        print(f"  {k:<22} {v}")

    legacy_n = await conn.fetchval("SELECT COUNT(*) FROM public.dojo_transactions")
    staging_n = await conn.fetchval("SELECT COUNT(*) FROM staging.payments WHERE source='dojo'")
    print(f"\n[migrate-dojo] ACCEPTANCE  legacy={legacy_n}  staging.payments(dojo)={staging_n}  delta={staging_n - legacy_n}")
    await conn.close()
    return 0


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()
    sys.exit(asyncio.run(run(args.dry_run)))
