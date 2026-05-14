#!/usr/bin/env python3
"""
raw-ingestor.py — consumer side of the three-adapter ingestion pipeline.

This is the Python implementation of the RAW-INGEST-001 n8n workflow described
in SPEC §4b.1. Adapters (API/scrape/CSV) all produce the same artifact pair:

    /home_ai/inbox/{source}/staged/{date}/{run_id}/
        manifest.json
        payments.jsonl

This script:
  1. Reads manifest.json.
  2. Hashes the payments.jsonl bytes.
  3. INSERT raw.imports (source, file_sha256, ...) ON CONFLICT DO NOTHING.
       → file-level idempotency (Layer 1).
  4. Streams each jsonl row into the source-specific raw.* table with
     INSERT ... ON CONFLICT (source, source_transaction_id, <part_key>).
       → natural-key idempotency (Layer 2).
  5. Detects row_hash mismatches (same natural key, different content):
     writes a mart.exceptions row of kind 'upstream_edit' instead of
     overwriting.
       → content-hash audit (Layer 3).

Usage:
    python3 scripts/payments/raw-ingestor.py /home_ai/inbox/dojo/staged/2026-05-14/01H7.../
    python3 scripts/payments/raw-ingestor.py --dry-run /path/

Idempotent. Exit 0 = success (including no-op replay).
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import sys
import urllib.request
from datetime import datetime, date as _date
from pathlib import Path


def _parse_dt(v):
    """Parse a string into datetime / date for asyncpg binding. Pass-through for None and existing dt."""
    if v is None or isinstance(v, (datetime, _date)):
        return v
    if isinstance(v, str):
        if "T" in v or " " in v:
            return datetime.fromisoformat(v.replace("Z", "+00:00"))
        # date-only
        return _date.fromisoformat(v)
    return v

try:
    import asyncpg
    import asyncio
except ImportError:
    sys.exit("ERROR: asyncpg / asyncio not available — run inside homeai-bot-responder.")

# Source → (raw table FQN, partition-key column, jsonl→row mapper)
# The mapper takes a parsed JSON object and returns a dict of column-values for
# the INSERT. Mapper is responsible for:
#   - computing row_hash from a canonical subset of fields
#   - filling in defaults (e.g. realm='work')
#   - leaving source/source_transaction_id/import_id/first_seen_via to caller


def _hash_row(d: dict) -> str:
    """Stable sha256 over the canonical JSON of the row's non-meta fields."""
    canonical = {k: d[k] for k in sorted(d) if k not in ("row_hash", "import_id", "first_seen_via", "raw_payload")}
    return hashlib.sha256(json.dumps(canonical, sort_keys=True, default=str).encode()).hexdigest()


def _map_dojo(row: dict) -> dict:
    """Map a normalised Dojo jsonl row → raw.dojo_transactions columns."""
    mapped = {
        "source_transaction_id": row["source_transaction_id"],
        "transaction_date":      _parse_dt(row["transaction_date"]),
        "transaction_at_utc":    _parse_dt(row["transaction_at_utc"]),
        "terminal_id":           row["terminal_id"],
        "site":                  row["site"],
        "entry_mode":            row.get("entry_mode"),
        "amount_minor":          row["amount_minor"],
        "gratuity_minor":        row.get("gratuity_minor"),
        "fee_minor":             row.get("fee_minor"),
        "refund_of":             row.get("refund_of"),
        "outcome":               row["outcome"],
        "last4_pan":             row.get("last4_pan"),
        "auth_code":             row.get("auth_code"),
        "settlement_batch_id":   row.get("settlement_batch_id"),
        "raw_payload":           json.dumps(row.get("raw_payload", row)),
    }
    mapped["row_hash"] = _hash_row(mapped)
    return mapped


def _map_bank(row: dict) -> dict:
    mapped = {
        "source_transaction_id": row["source_transaction_id"],
        "transaction_date":      _parse_dt(row["transaction_date"]),
        "posted_at_utc":         _parse_dt(row.get("posted_at_utc")),
        "account_ref":           row["account_ref"],
        "type_code":             row.get("type_code"),
        "description":           row["description"],
        "amount_minor":          row["amount_minor"],
        "balance_after_minor":   row.get("balance_after_minor"),
        "counterparty_name":     row.get("counterparty_name"),
        "counterparty_ref":      row.get("counterparty_ref"),
        "entity_id":             row.get("entity_id"),
        "raw_payload":           json.dumps(row.get("raw_payload", row)),
    }
    mapped["row_hash"] = _hash_row(mapped)
    return mapped


SOURCE_CONFIG: dict[str, dict] = {
    "dojo": {
        "raw_table": "raw.dojo_transactions",
        "part_key":  "transaction_date",
        "mapper":    _map_dojo,
        "columns": [
            "source", "source_transaction_id", "row_hash", "first_seen_via", "import_id",
            "transaction_date", "transaction_at_utc", "terminal_id", "site", "entry_mode",
            "amount_minor", "gratuity_minor", "fee_minor", "refund_of", "outcome",
            "last4_pan", "auth_code", "settlement_batch_id", "raw_payload",
        ],
    },
    "natwest": {
        "raw_table": "raw.bank_lines",
        "part_key":  "transaction_date",
        "mapper":    _map_bank,
        "columns": [
            "source", "source_transaction_id", "row_hash", "first_seen_via", "import_id",
            "transaction_date", "posted_at_utc", "account_ref", "type_code", "description",
            "amount_minor", "balance_after_minor", "counterparty_name", "counterparty_ref",
            "entity_id", "raw_payload",
        ],
    },
    "amex": {
        "raw_table": "raw.bank_lines",
        "part_key":  "transaction_date",
        "mapper":    _map_bank,
        "columns": [
            "source", "source_transaction_id", "row_hash", "first_seen_via", "import_id",
            "transaction_date", "posted_at_utc", "account_ref", "type_code", "description",
            "amount_minor", "balance_after_minor", "counterparty_name", "counterparty_ref",
            "entity_id", "raw_payload",
        ],
    },
}


def vault_pg_dsn() -> str:
    """Pull the postgres password from Vault via the homeai-vault container."""
    if dsn := os.environ.get("PG_DSN"):
        return dsn
    # Construct from Vault. Token is in this container's env (bot-responder
    # has VAULT_TOKEN populated by start.sh).
    vault_token = os.environ["VAULT_TOKEN"]
    req = urllib.request.Request(
        "http://vault:8200/v1/secret/data/postgres",
        headers={"X-Vault-Token": vault_token})
    data = json.loads(urllib.request.urlopen(req, timeout=5).read())
    pw = data["data"]["data"]["password"]
    return f"postgresql://postgres:{pw}@homeai-postgres:5432/homeai"


async def ingest(staged_dir: Path, *, dry_run: bool = False, operator: str = "raw-ingestor.py") -> int:
    manifest_path = staged_dir / "manifest.json"
    payload_path  = staged_dir / "payments.jsonl"

    if not manifest_path.exists():
        sys.exit(f"ERROR: manifest.json not found at {manifest_path}")
    if not payload_path.exists():
        sys.exit(f"ERROR: payments.jsonl not found at {payload_path}")

    manifest = json.loads(manifest_path.read_text())
    source   = manifest["source"]
    adapter  = manifest["adapter"]
    realm    = manifest.get("realm", "work")

    if source not in SOURCE_CONFIG:
        sys.exit(f"ERROR: source {source!r} not registered in SOURCE_CONFIG")
    cfg = SOURCE_CONFIG[source]

    payload_bytes = payload_path.read_bytes()
    file_sha256   = hashlib.sha256(payload_bytes).hexdigest()

    # If the manifest already has a sha256 different from ours, refuse —
    # an honest adapter leaves this blank for the ingestor to fill.
    if manifest.get("payload_sha256") not in (None, "", "<filled by raw-ingestor>"):
        if manifest["payload_sha256"] != file_sha256:
            sys.exit(
                f"ERROR: manifest payload_sha256 ({manifest['payload_sha256'][:16]}…) "
                f"≠ computed ({file_sha256[:16]}…). Adapter has misbehaved.")

    print(f"[raw-ingestor] source={source} adapter={adapter} sha256={file_sha256[:16]}…")
    print(f"[raw-ingestor] payload rows declared={manifest.get('payload_row_count', '?')}")

    if dry_run:
        print("[raw-ingestor] --dry-run set; skipping DB writes")
        return 0

    conn = await asyncpg.connect(vault_pg_dsn())
    # Per AGENTS.md SQL discipline:
    await conn.fetchval("SELECT set_config('app.current_entity', 'all', false)")
    await conn.fetchval("SELECT set_config('app.current_realm', 'owner', false)")

    # Layer 1 — file-level idempotency. ON CONFLICT DO NOTHING + RETURNING tells
    # us whether this is a fresh import or a replay.
    import_row = await conn.fetchrow("""
        INSERT INTO raw.imports
            (source, adapter, file_sha256, payload_path, manifest_json,
             captured_at, row_count, operator, realm)
        VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7, $8, $9)
        ON CONFLICT (source, file_sha256) DO NOTHING
        RETURNING id
    """, source, adapter, file_sha256, str(payload_path),
         json.dumps(manifest), _parse_dt(manifest["captured_at"]),
         manifest.get("payload_row_count", 0), operator, realm)

    if import_row is None:
        existing = await conn.fetchval(
            "SELECT id FROM raw.imports WHERE source=$1 AND file_sha256=$2", source, file_sha256)
        print(f"[raw-ingestor] REPLAY — file already imported as raw.imports.id={existing}; no-op.")
        await conn.close()
        return 0

    import_id = import_row["id"]
    print(f"[raw-ingestor] raw.imports.id={import_id} (new)")

    # Layer 2 + 3 — stream each row.
    inserted = 0
    skipped_dup = 0
    upstream_edits = 0

    column_list = ", ".join(cfg["columns"])
    placeholder_list = ", ".join(f"${i+1}" for i in range(len(cfg["columns"])))
    conflict_cols = f"(source, source_transaction_id, {cfg['part_key']})"

    insert_sql = f"""
        INSERT INTO {cfg['raw_table']} ({column_list})
        VALUES ({placeholder_list})
        ON CONFLICT {conflict_cols} DO NOTHING
        RETURNING id
    """

    for line_no, raw_line in enumerate(payload_bytes.decode("utf-8").splitlines(), start=1):
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            row = json.loads(raw_line)
        except json.JSONDecodeError as e:
            print(f"[raw-ingestor] line {line_no}: JSON parse error: {e}", file=sys.stderr)
            continue

        mapped = cfg["mapper"](row)

        # Layer 3 — check for upstream_edit before INSERT.
        part_val = mapped[cfg["part_key"]]
        existing = await conn.fetchrow(f"""
            SELECT id, row_hash FROM {cfg['raw_table']}
             WHERE source = $1 AND source_transaction_id = $2 AND {cfg['part_key']} = $3
        """, source, mapped["source_transaction_id"], part_val)

        if existing:
            if existing["row_hash"] == mapped["row_hash"]:
                skipped_dup += 1
                continue
            # Upstream edit — write to mart.exceptions and DO NOT overwrite.
            await conn.execute("""
                INSERT INTO mart.exceptions
                    (severity, kind, source, transaction_date, summary, detail, realm)
                VALUES ('medium', 'upstream_edit', $1, $2, $3, $4::jsonb, $5)
            """, source, part_val,
                 f"{source} {mapped['source_transaction_id']}: row_hash mismatch on re-import",
                 json.dumps({
                     "existing_id": existing["id"],
                     "existing_row_hash": existing["row_hash"],
                     "proposed_row_hash": mapped["row_hash"],
                     "proposed_row": row,
                     "import_id": import_id,
                 }, default=str),
                 realm)
            upstream_edits += 1
            continue

        # New row. Build the value tuple in the order of cfg["columns"].
        values = []
        for col in cfg["columns"]:
            if col == "source":
                values.append(source)
            elif col == "first_seen_via":
                values.append(adapter)
            elif col == "import_id":
                values.append(import_id)
            else:
                values.append(mapped.get(col))
        result = await conn.fetchrow(insert_sql, *values)
        if result:
            inserted += 1
        else:
            skipped_dup += 1

    await conn.close()

    print(f"[raw-ingestor] inserted={inserted} skipped_dup={skipped_dup} upstream_edits={upstream_edits}")
    return 0


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("staged_dir", type=Path,
                   help="Path to /home_ai/inbox/<source>/staged/<date>/<run_id>/")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--operator", default="raw-ingestor.py")
    args = p.parse_args()
    sys.exit(asyncio.run(ingest(args.staged_dir, dry_run=args.dry_run, operator=args.operator)))
