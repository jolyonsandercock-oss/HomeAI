#!/usr/bin/env python3
"""adapters/csv/natwest.py — NatWest CSV adapter.

Reads a NatWest current-account / savings-account CSV export and emits the
manifest + payments.jsonl artifact pair into
/home_ai/inbox/natwest/staged/{date}/{run_id}/ for raw-ingestor.py to
consume.

NatWest CSV format (validated from the 2026-05-14 batch):
    Date,Type,Description,Value,Balance,Account Name,Account Number
    20 Jan 2025,BAC,ATLANTIC ROAD ESTA,76.43,-4548.59,ATLANTIC ROAD,521047-17065488

Sign convention: negative=outflow (NatWest's native convention).
source_transaction_id is the sha256-prefix idempotency key over the row's
content — same shape as the U58 importer used so re-runs across both paths
deduplicate via raw.bank_lines UNIQUE(source, source_transaction_id, date).
"""
from __future__ import annotations
import argparse
import csv
import hashlib
import json
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

INBOX_ROOT = Path("/home_ai/inbox/natwest/staged")
ADAPTER    = "csv"
SOURCE     = "natwest"
REALM      = "work"
SCHEMA_URL = "https://homeai.local/schemas/payment-ingest-manifest-v1.json"

# Account → entity_id, mirroring services.yaml. Hard-coded here so the adapter
# doesn't require pyyaml inside the producing container.
ACCOUNT_ENTITY = {
    "521047-17065488": 1,
    "600001-48747300": 1,
    "521047-48885517": 1,  # U72 T4 — ATR Trading second current (Dojo settlement landing)
    "521047-17046041": 2,
    "600001-36345245": 3,
    "600001-49011170": 3,
    "504237-69323321": 3,
    "602479-19070381": 3,
    "600001-49056204": 4,
}


def idem_key(acct_full: str, tx_date: str, value: str, balance: str, desc: str) -> str:
    raw = f"{acct_full}|{tx_date}|{value}|{balance}|{desc}".encode()
    return hashlib.sha256(raw).hexdigest()[:32]


def parse_row(row: dict) -> dict:
    acct_full = row["Account Number"].strip()  # e.g. "521047-17065488"
    tx_date_raw = row["Date"].strip()
    tx_date = datetime.strptime(tx_date_raw, "%d %b %Y").date()

    value_str   = row["Value"].strip()
    balance_str = (row.get("Balance") or "").strip()
    desc    = row["Description"].strip()
    type_code = row.get("Type", "").strip() or None

    # Mirror U58 importer's exact key format: float-or-None, NOT raw strings.
    # Otherwise empty-balance rows produce different hashes from migration.
    value_f   = float(value_str)
    balance_f = float(balance_str) if balance_str else None

    amount_minor = int(round(value_f * 100))
    balance_minor = int(round(balance_f * 100)) if balance_f is not None else None

    return {
        "source_transaction_id": idem_key(acct_full, tx_date.isoformat(), value_f, balance_f, desc),
        "transaction_date":      tx_date.isoformat(),
        "posted_at_utc":         None,
        "account_ref":           acct_full,
        "type_code":             type_code,
        "description":           desc,
        "amount_minor":          amount_minor,
        "balance_after_minor":   balance_minor,
        "counterparty_name":     None,
        "counterparty_ref":      None,
        "entity_id":             ACCOUNT_ENTITY.get(acct_full),
        "raw_payload": {
            "Date":       row.get("Date"),
            "Type":       type_code,
            "Description": desc,
            "Value":       value_str,
            "Balance":     balance_str or None,
            "Account Name": row.get("Account Name"),
            "Account Number": acct_full,
        },
    }


def emit(csv_path: Path) -> Path:
    rows = []
    with csv_path.open() as f:
        for row in csv.DictReader(f):
            if not row.get("Account Number"):
                continue
            rows.append(parse_row(row))
    if not rows:
        sys.exit(f"ERROR: no rows parsed from {csv_path}")

    today  = datetime.now(timezone.utc).date().isoformat()
    run_id = uuid.uuid4().hex[:12]
    staged = INBOX_ROOT / today / run_id
    staged.mkdir(parents=True, exist_ok=True)

    jsonl_path    = staged / "payments.jsonl"
    manifest_path = staged / "manifest.json"

    with jsonl_path.open("w") as f:
        for r in rows:
            f.write(json.dumps(r, separators=(",", ":"), default=str) + "\n")

    accounts = sorted({r["account_ref"] for r in rows})
    manifest = {
        "$schema":          SCHEMA_URL,
        "manifest_version": 1,
        "source":           SOURCE,
        "adapter":          ADAPTER,
        "run_id":           run_id,
        "captured_at":      datetime.now(timezone.utc).isoformat(),
        "window": {
            "from": min(r["transaction_date"] for r in rows),
            "to":   max(r["transaction_date"] for r in rows),
        },
        "scope": {
            "merchant_id":  None,
            "terminal_ids": None,
            "account_ids":  accounts,
        },
        "credentials_path":  "secret/payments/natwest/identity",
        "payload_filename":  "payments.jsonl",
        "payload_row_count": len(rows),
        "payload_sha256":    "<filled by raw-ingestor>",
        "transformations_applied": [
            "amount_to_minor_units",
            "date_to_iso",
        ],
        "operator":          "adapters/csv/natwest.py",
        "source_csv":        str(csv_path),
        "realm":             REALM,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2))

    print(f"[adapter:csv:natwest] {len(rows)} row(s) across {len(accounts)} account(s) → {staged}")
    return staged


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("csv_path", type=Path)
    args = p.parse_args()
    print(emit(args.csv_path))
