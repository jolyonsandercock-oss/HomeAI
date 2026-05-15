#!/usr/bin/env python3
"""u78-ingest-clover.py — parse a Clover Merchant Card Processing Statement
   OCR-text out of `documents.ocr_text` and insert daily settlement batches
   into `clover_batches`. Idempotent (UNIQUE on mid+batch_date+batch_number).

   Usage: u78-ingest-clover.py <document_id> [--entity-id N] [--site accom]
"""
import argparse
import re
import subprocess
import sys
from datetime import datetime


# --- shell out to psql inside the homeai-postgres container -----------------
def psql(sql: str, set_local: dict | None = None) -> str:
    # Scripts run as the `postgres` superuser, which bypasses RLS — so we
    # don't need to set app.current_entity here. The set_local arg is kept
    # for callers that wrap their statement in BEGIN/COMMIT explicitly.
    full = ""
    if set_local:
        full += "BEGIN;\n"
        for k, v in set_local.items():
            full += f"SET LOCAL {k} = '{v}';\n"
        full += sql + "\nCOMMIT;\n"
    else:
        full += sql
    out = subprocess.run(
        ["docker", "exec", "-i", "homeai-postgres",
         "psql", "-U", "postgres", "-d", "homeai",
         "-tAq", "-v", "ON_ERROR_STOP=1"],
        input=full, text=True, capture_output=True, check=True,
    )
    return "\n".join(
        ln for ln in out.stdout.splitlines()
        if ln.strip() and ln.strip() not in ("SET", "BEGIN", "COMMIT")
    ).strip()


# --- header extraction ------------------------------------------------------
RE_MID = re.compile(r"Merchant\s+Number\s+(\d{10,})", re.IGNORECASE)
RE_PERIOD = re.compile(
    r"StatementPeriod\s+(\d{1,2}\s+\w+\s+\d{4})\s*-\s*(\d{1,2}\s+\w+\s+\d{4})",
    re.IGNORECASE,
)
# A batch row: DD/MM/YY, batch#, 6 numbers (5 amounts + total). Allow commas.
# E.g. "02/03/26 305007800 0.00 0.00 193.50 0.00 0.00 193.50"
RE_BATCH = re.compile(
    r"^(\d{2}/\d{2}/\d{2})\s+(\d{7,})\s+"
    r"([\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s+"
    r"([\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s*$"
)


def _money(s: str) -> float:
    return float(s.replace(",", ""))


def _date(dmy: str) -> str:
    return datetime.strptime(dmy, "%d/%m/%y").date().isoformat()


def _period(text: str) -> tuple[str | None, str | None]:
    m = RE_PERIOD.search(text)
    if not m:
        return None, None
    s = datetime.strptime(m.group(1), "%d %b %Y").date().isoformat()
    e = datetime.strptime(m.group(2), "%d %b %Y").date().isoformat()
    return s, e


def parse(ocr: str) -> dict:
    mid_m = RE_MID.search(ocr)
    if not mid_m:
        raise SystemExit("Could not find 'Merchant Number' in OCR text")
    mid = mid_m.group(1)
    period_start, period_end = _period(ocr)

    batches = []
    for line in ocr.splitlines():
        m = RE_BATCH.match(line.strip())
        if not m:
            continue
        batches.append({
            "batch_date":  _date(m.group(1)),
            "batch_number": m.group(2),
            "visa":        _money(m.group(3)),
            "visa_debit":  _money(m.group(4)),
            "mc_consumer": _money(m.group(5)),
            "mc_purch":    _money(m.group(6)),
            "mc_debit":    _money(m.group(7)),
            "gross":       _money(m.group(8)),
        })
    if not batches:
        raise SystemExit("No batch rows matched — OCR may have garbled the table")
    return {"mid": mid, "period_start": period_start,
            "period_end": period_end, "batches": batches}


# --- main -------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("document_id", type=int)
    ap.add_argument("--entity-id", type=int, default=1,
                    help="entity_id (default 1 = ARTL / Malthouse)")
    ap.add_argument("--site", default="accom",
                    help="site label (default 'accom')")
    args = ap.parse_args()

    ocr = psql(f"SELECT ocr_text FROM documents WHERE id = {args.document_id};")
    if not ocr:
        print(f"document_id={args.document_id} has no ocr_text", file=sys.stderr)
        return 1

    data = parse(ocr)
    print(f"Parsed mid={data['mid']} period={data['period_start']}→{data['period_end']} "
          f"batches={len(data['batches'])}", file=sys.stderr)

    # Insert with RLS context. Idempotent via UNIQUE(mid, batch_date, batch_number).
    inserted = 0
    skipped = 0
    for b in data["batches"]:
        idk = f"clover:{data['mid']}:{b['batch_date']}:{b['batch_number']}"
        sql = f"""
        INSERT INTO clover_batches (
            entity_id, realm, mid, site, batch_date, batch_number,
            visa_amount, visa_debit_amount, mc_consumer_amount,
            mc_purchasing_amount, mc_debit_amount, gross_amount,
            statement_period_start, statement_period_end,
            source_document_id, idempotency_key
        ) VALUES (
            {args.entity_id}, 'work', '{data["mid"]}', '{args.site}',
            '{b["batch_date"]}', '{b["batch_number"]}',
            {b["visa"]}, {b["visa_debit"]}, {b["mc_consumer"]},
            {b["mc_purch"]}, {b["mc_debit"]}, {b["gross"]},
            {"'%s'" % data["period_start"] if data["period_start"] else 'NULL'},
            {"'%s'" % data["period_end"]   if data["period_end"]   else 'NULL'},
            {args.document_id}, '{idk}'
        )
        ON CONFLICT (mid, batch_date, batch_number) DO NOTHING
        RETURNING id;
        """
        result = psql(sql, set_local={
            "app.current_entity": str(args.entity_id),
            "app.current_realm":  "work",
        })
        if result:
            inserted += 1
        else:
            skipped += 1

    print(f"clover_batches: inserted={inserted} skipped(duplicate)={skipped}",
          file=sys.stderr)

    # Tag the document with the canonical category so future polls know it.
    psql(f"""
        SET LOCAL app.current_entity = '{args.entity_id}';
        UPDATE documents
           SET category = 'clover_statement',
               entity_id = {args.entity_id}
         WHERE id = {args.document_id};
    """)
    return 0


if __name__ == "__main__":
    sys.exit(main())
