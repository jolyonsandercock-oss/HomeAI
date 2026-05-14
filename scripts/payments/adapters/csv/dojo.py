#!/usr/bin/env python3
"""adapters/csv/dojo.py — Dojo CSV adapter.

Reads a Dojo card-transactions CSV and emits manifest + payments.jsonl into
/home_ai/inbox/dojo/staged/{date}/{run_id}/ for raw-ingestor.py to consume.
"""
from __future__ import annotations
import argparse
import csv
import json
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

try:
    import yaml
except ImportError:
    sys.exit("ERROR: pyyaml required.")

SERVICES_YAML = Path("/home_ai/config/payments/services.yaml")
INBOX_ROOT    = Path("/home_ai/inbox/dojo/staged")
ADAPTER       = "csv"
SOURCE        = "dojo"
REALM         = "work"
SCHEMA_URL    = "https://homeai.local/schemas/payment-ingest-manifest-v1.json"


def load_terminal_map() -> dict[str, str]:
    doc = yaml.safe_load(SERVICES_YAML.read_text())
    return {t["id"]: t["site"] for t in doc["sources"]["dojo"]["config"]["terminals"]}


def normalise_entry_mode(raw: str) -> str | None:
    if not raw:
        return None
    r = raw.strip().lower()
    if "chip" in r:
        return "chip"
    if "contactless" in r or "tap" in r or "nfc" in r:
        return "contactless"
    if "key" in r or "manual" in r:
        return "keyed"
    if "virtual" in r or r == "vt":
        return "vt"
    if "swipe" in r or "magstripe" in r:
        return "swipe"
    return r


def to_minor(amount: str) -> int | None:
    if not amount or not amount.strip():
        return None
    return int(round(float(amount.strip()) * 100))


def parse_dojo_row(row: dict, terminal_map: dict[str, str]) -> dict:
    txid = (row.get("Transaction ID") or "").strip()
    if not txid:
        raise ValueError(f"row missing Transaction ID: {row}")

    if row.get("Transaction Date") and row.get("Transaction Time"):
        ts_raw = f"{row['Transaction Date']} {row['Transaction Time']}"
        try:
            ts = datetime.strptime(ts_raw, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
        except ValueError:
            ts = datetime.fromisoformat(ts_raw.replace("Z", "+00:00"))
    elif row.get("Timestamp"):
        ts = datetime.fromisoformat(row["Timestamp"].replace("Z", "+00:00"))
    elif row.get("Transaction Date"):
        ts = datetime.strptime(row["Transaction Date"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    else:
        raise ValueError(f"can't parse timestamp from row {txid}: {row}")

    terminal_id = (row.get("Terminal ID") or "").strip()
    site        = row.get("Site") or terminal_map.get(terminal_id) or "unknown"

    return {
        "source_transaction_id": txid,
        "transaction_date":      ts.date().isoformat(),
        "transaction_at_utc":    ts.astimezone(timezone.utc).isoformat(),
        "terminal_id":           terminal_id,
        "site":                  site,
        "entry_mode":            normalise_entry_mode(row.get("Card Entry Mode", "")),
        "amount_minor":          to_minor(row.get("Amount (GBP)") or row.get("Amount", "")),
        "gratuity_minor":        to_minor(row.get("Gratuity (GBP)", "")),
        "fee_minor":             to_minor(row.get("Fee (GBP)", "")),
        "outcome":               (row.get("Outcome") or "approved").strip().lower(),
        "last4_pan":             (row.get("Last 4 Digits") or row.get("Last4 PAN", "")).strip() or None,
        "auth_code":             (row.get("Auth Code") or "").strip() or None,
        "settlement_batch_id":   (row.get("Settlement Batch") or "").strip() or None,
        "refund_of":             (row.get("Refund Of") or "").strip() or None,
        "raw_payload":           {k: v for k, v in row.items() if v not in (None, "")},
    }


def transform(csv_path: Path) -> Iterable[dict]:
    terminal_map = load_terminal_map()
    with csv_path.open() as f:
        for row in csv.DictReader(f):
            yield parse_dojo_row(row, terminal_map)


def emit(csv_path: Path) -> Path:
    rows = list(transform(csv_path))
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

    manifest = {
        "$schema":           SCHEMA_URL,
        "manifest_version":  1,
        "source":            SOURCE,
        "adapter":           ADAPTER,
        "run_id":            run_id,
        "captured_at":       datetime.now(timezone.utc).isoformat(),
        "window": {
            "from": min(r["transaction_date"] for r in rows),
            "to":   max(r["transaction_date"] for r in rows),
        },
        "scope": {
            "merchant_id":  "MA****REDACTED",
            "terminal_ids": sorted({r["terminal_id"] for r in rows}),
            "account_ids":  None,
        },
        "credentials_path":  "secret/payments/dojo/api",
        "payload_filename":  "payments.jsonl",
        "payload_row_count": len(rows),
        "payload_sha256":    "<filled by raw-ingestor>",
        "transformations_applied": [
            "currency_to_gbp_minor_units",
            "entry_mode_normalised",
            "timestamp_to_utc",
        ],
        "operator":          "adapters/csv/dojo.py",
        "source_csv":        str(csv_path),
        "realm":             REALM,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2))

    print(f"[adapter:csv:dojo] {len(rows)} row(s) → {staged}")
    return staged


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("csv_path", type=Path)
    args = p.parse_args()
    out = emit(args.csv_path)
    print(out)
