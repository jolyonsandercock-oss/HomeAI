#!/usr/bin/env python3
"""
Dojo CSV → dojo_transactions importer (idempotent).

Usage:
    python3 dojo-import.py /path/to/Transactions_*.csv
    python3 dojo-import.py /path/to/Transactions_*.csv --dry-run

Behaviour:
    - Reads the CSV produced by Dojo's "Export transactions" button.
    - Maps Address/MID → site (pub | cafe). Unknown MIDs abort the run.
    - UPSERTs on transaction_id (Dojo's per-txn UUID). Re-runnable on
      overlapping windows; later columns win for the same id.
    - Writes one audit_log row summarising the import (file path,
      total rows in CSV, inserted, updated, skipped, date range).

Connects via PG_DSN (env). When run inside the postgres host:
    docker exec -e PG_DSN=postgresql://postgres@/homeai homeai-postgres \\
        python3 /home_ai/scripts/dojo-import.py /tmp/dojo.csv
"""
from __future__ import annotations

import argparse
import asyncio
import csv
import json
import os
import sys
from datetime import date as _date, time as _time
from decimal import Decimal, InvalidOperation
from pathlib import Path

import asyncpg


MID_SITE = {
    "476621462111863": "pub",
    "146184234181151": "cafe",
}

# CSV header → DB column.
COLUMN_MAP = {
    "Address":                    "address",
    "MID":                        "mid",
    "Location":                   "location",
    "Transaction ID":             "transaction_id",
    "Transaction date":           "transaction_date",
    "Transaction time":           "transaction_time",
    "Transaction type":           "transaction_type",
    "Transaction outcome":        "transaction_outcome",
    "Currency":                   "currency",
    "Transaction amount":         "transaction_amount",
    "Cashback amount":            "cashback_amount",
    "Donation amount":            "donation_amount",
    "Gratuity amount":            "gratuity_amount",
    "Authorisation code":         "authorisation_code",
    "Source":                     "source",
    "Merchant Order Number":      "merchant_order_number",
    "Payment Method":             "payment_method",
    "Card number":                "card_number_masked",
    "Card type":                  "card_type",
    "Card scheme":                "card_scheme",
    "Card Machine Serial No.":    "card_machine_serial",
    "Card Machine Name":          "card_machine_name",
    "Card Machine ID":            "card_machine_id",
    "Remote ID":                  "remote_id",
    "Total transaction charge":   "total_transaction_charge",
    "Card transaction charge":    "card_transaction_charge",
    "Secure Transaction Charge":  "secure_transaction_charge",
    "Authorisation fee":          "authorisation_fee",
    "Refund fee":                 "refund_fee",
    "Fee Vat":                    "fee_vat",
    "Refund Reason":              "refund_reason",
    "Notes":                      "notes",
    "Cardholder Currency":        "cardholder_currency",
    "Cardholder Amount":          "cardholder_amount",
    "Exchange Rate":              "exchange_rate",
    "Card Level":                 "card_level",
}

NUMERIC_COLS = {
    "transaction_amount", "cashback_amount", "donation_amount", "gratuity_amount",
    "cardholder_amount", "exchange_rate",
    "total_transaction_charge", "card_transaction_charge",
    "secure_transaction_charge", "authorisation_fee", "refund_fee", "fee_vat",
}


def _num(s: str | None):
    if s is None or s == "":
        return None
    try:
        return Decimal(s)
    except (InvalidOperation, ValueError):
        return None


def _txt(s: str | None):
    if s is None:
        return None
    s = s.strip()
    return s if s else None


def transform(row: dict, csv_path: str) -> dict:
    mid = row.get("MID", "").strip()
    site = MID_SITE.get(mid, "unknown")
    if site == "unknown":
        raise SystemExit(
            f"Unknown MID {mid!r} (address={row.get('Address')!r}). "
            f"Add to MID_SITE map before re-running."
        )
    out: dict = {}
    for csv_h, db_c in COLUMN_MAP.items():
        v = row.get(csv_h)
        if db_c in NUMERIC_COLS:
            out[db_c] = _num(v)
        else:
            out[db_c] = _txt(v)
    out["site"] = site
    out["entity_id"] = 1
    out["realm"] = "work"
    out["import_source"] = os.path.basename(csv_path)
    # Forensic store of the raw row (always TEXT-of-TEXT — Decimals coerced).
    out["raw_row"] = json.dumps({k: (v if v is not None else "") for k, v in row.items()})
    return out


COLUMN_ORDER = [
    "transaction_id", "mid", "site", "address", "location",
    "transaction_date", "transaction_time",
    "transaction_type", "transaction_outcome",
    "currency", "transaction_amount",
    "cashback_amount", "donation_amount", "gratuity_amount",
    "cardholder_currency", "cardholder_amount", "exchange_rate",
    "authorisation_code", "source", "merchant_order_number",
    "payment_method", "card_number_masked", "card_type", "card_scheme", "card_level",
    "card_machine_serial", "card_machine_name", "card_machine_id", "remote_id",
    "total_transaction_charge", "card_transaction_charge", "secure_transaction_charge",
    "authorisation_fee", "refund_fee", "fee_vat",
    "refund_reason", "notes",
    "raw_row", "entity_id", "realm", "import_source",
]

INSERT_SQL = f"""
INSERT INTO dojo_transactions ({", ".join(COLUMN_ORDER)})
VALUES ({", ".join(f"${i+1}" for i in range(len(COLUMN_ORDER)))})
ON CONFLICT (transaction_id) DO UPDATE SET
    site                      = EXCLUDED.site,
    transaction_outcome       = EXCLUDED.transaction_outcome,
    transaction_amount        = EXCLUDED.transaction_amount,
    gratuity_amount           = EXCLUDED.gratuity_amount,
    cashback_amount           = EXCLUDED.cashback_amount,
    total_transaction_charge  = EXCLUDED.total_transaction_charge,
    card_transaction_charge   = EXCLUDED.card_transaction_charge,
    secure_transaction_charge = EXCLUDED.secure_transaction_charge,
    authorisation_fee         = EXCLUDED.authorisation_fee,
    refund_fee                = EXCLUDED.refund_fee,
    fee_vat                   = EXCLUDED.fee_vat,
    refund_reason             = EXCLUDED.refund_reason,
    notes                     = EXCLUDED.notes,
    raw_row                   = EXCLUDED.raw_row,
    import_source             = EXCLUDED.import_source,
    imported_at               = now()
RETURNING (xmax = 0) AS inserted
"""


def _coerce(rec):
    # Date / time strings → date / time objects.
    if rec.get("transaction_date"):
        rec["transaction_date"] = _date.fromisoformat(rec["transaction_date"])
    if rec.get("transaction_time"):
        h, m, s = rec["transaction_time"].split(":")
        rec["transaction_time"] = _time(int(h), int(m), int(s))
    # raw_row already a JSON string; asyncpg accepts string for jsonb cast.
    return rec


async def run_async(records, csv_path):
    pg_dsn = os.environ.get("PG_DSN") or "postgresql://postgres@/homeai"
    conn = await asyncpg.connect(pg_dsn)
    inserted = updated = 0
    try:
        async with conn.transaction():
            await conn.execute("SET LOCAL app.current_entity = '1'")
            await conn.execute("SET LOCAL app.current_realm = 'work'")
            for rec in records:
                _coerce(rec)
                args = [rec[c] for c in COLUMN_ORDER]
                row = await conn.fetchrow(INSERT_SQL, *args)
                if row and row["inserted"]:
                    inserted += 1
                else:
                    updated += 1

            await conn.execute("SET LOCAL app.current_realm = 'owner'")
            dates = [r["transaction_date"] for r in records if r["transaction_date"]]
            by_site = {}
            for r in records:
                by_site[r["site"]] = by_site.get(r["site"], 0) + 1
            await conn.execute("""
              INSERT INTO audit_log (pipeline, action, record_type, record_id,
                                     ai_parsed, result, realm)
              VALUES ('dojo-import', 'csv_import', 'dojo_transactions', NULL,
                      $1::jsonb, 'success', 'owner')
            """, json.dumps({
                "file":        os.path.basename(csv_path),
                "rows_parsed": len(records),
                "inserted":    inserted,
                "updated":     updated,
                "date_min":    str(min(dates)),
                "date_max":    str(max(dates)),
                "by_site":     by_site,
            }))
    finally:
        await conn.close()
    return inserted, updated


def main():
    ap = argparse.ArgumentParser(description="Idempotent Dojo CSV importer")
    ap.add_argument("csv_path", type=Path)
    ap.add_argument("--dry-run", action="store_true",
                    help="Parse + validate; do not write to DB.")
    args = ap.parse_args()

    if not args.csv_path.exists():
        sys.exit(f"CSV not found: {args.csv_path}")

    with args.csv_path.open(newline="", encoding="utf-8") as f:
        records = [transform(row, str(args.csv_path)) for row in csv.DictReader(f)]
    if not records:
        sys.exit("CSV had no data rows")

    dates = [r["transaction_date"] for r in records if r["transaction_date"]]
    by_site = {}
    for r in records:
        by_site[r["site"]] = by_site.get(r["site"], 0) + 1
    print(f"parsed {len(records)} rows  {min(dates)} → {max(dates)}")
    print(f"by site: {by_site}")

    if args.dry_run:
        print("dry-run — no DB writes")
        return

    inserted, updated = asyncio.run(run_async(records, str(args.csv_path)))
    print(f"inserted={inserted}  updated={updated}")


if __name__ == "__main__":
    main()
