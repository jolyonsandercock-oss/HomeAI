#!/usr/bin/env python3
"""u78-ingest-utility.py — parse a utility bill OCR-text into
   `vendor_invoice_inbox` and consult `account_property_map` to auto-route
   by account-number → entity/property. Unmapped accounts open a
   `bot_instructions` row asking Jo to confirm the mapping.

   Today this handles South West Water / Source for Business (Pennon).
   Extending it to another utility is just a new VENDOR_PROFILES entry.
"""
import re
import subprocess
import sys
from argparse import ArgumentParser
from datetime import datetime


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
        input=full, text=True, capture_output=True,
    )
    if out.returncode != 0:
        sys.stderr.write("--- psql failed ---\n")
        sys.stderr.write(full + "\n")
        sys.stderr.write("--- stderr ---\n")
        sys.stderr.write(out.stderr + "\n")
        raise SystemExit(out.returncode)
    # Strip any stray "SET"/"BEGIN"/"COMMIT" lines that psql prints to stdout.
    return "\n".join(
        ln for ln in out.stdout.splitlines()
        if ln.strip() and ln.strip() not in ("SET", "BEGIN", "COMMIT")
    ).strip()


def sql_escape(s: str | None) -> str:
    if s is None:
        return "NULL"
    return "'" + s.replace("'", "''") + "'"


# --- vendor fingerprints ----------------------------------------------------
#
# Each profile knows how to spot one vendor in OCR text, then how to extract
# (account_number, gross_amount, invoice_date, due_date, period, address).
# Add new vendors by appending another entry. Regexes are intentionally
# fault-tolerant of OCR mangling (e.g. £ ↔ €, "I" ↔ "1").

def _money(s: str) -> float:
    return float(re.sub(r"[^\d.]", "", s))


def _parse_uk_date(s: str) -> str:
    return datetime.strptime(s.strip(), "%d %B %Y").date().isoformat()


def _normalise_account(s: str) -> str:
    return re.sub(r"\D", "", s)


def parse_source_for_business(ocr: str) -> dict | None:
    """South West Water / Source for Business (Pennon)."""
    if "source4b.co.uk" not in ocr.lower() and "Source\nfor Business" not in ocr:
        return None
    out = {
        "vendor_domain": "source4b.co.uk",
        "vendor_name":   "Source for Business (South West Water)",
        "vendor_category": "Utilities",
        "category_canonical": "utility_water",
        "currency": "GBP",
    }

    m = re.search(r"Customer number\s*\n?\s*([\d ]{8,})", ocr)
    if not m:
        m = re.search(r"customer number.*?(\d[\d ]{6,}\d)", ocr,
                      re.IGNORECASE | re.DOTALL)
    if m:
        out["account_display"] = m.group(1).strip()
        out["account_number"]  = _normalise_account(m.group(1))

    m = re.search(r"Bill date\s+(\d{1,2}\s+\w+\s+\d{4})", ocr)
    if m:
        out["invoice_date"] = _parse_uk_date(m.group(1))

    m = re.search(r"£\s*([\d,]+\.\d{2})\s*on\s+(\d{1,2}\s+\w+\s+\d{4})", ocr)
    if m:
        out["gross_amount"] = _money(m.group(1))
        out["due_date"]     = _parse_uk_date(m.group(2))

    if "gross_amount" not in out:
        m = re.search(r"Bill total[^£]*£\s*([\d,]+\.\d{2})", ocr)
        if m:
            out["gross_amount"] = _money(m.group(1))

    m = re.search(r"For services at\s+(.+?)(?:\n|$)", ocr)
    if m:
        out["service_address"] = m.group(1).strip()

    m = re.search(r"(\d{1,2}\s+\w+\s+\d{4})\s+to\s+(\d{1,2}\s+\w+\s+\d{4})", ocr)
    if m:
        out["period_start"] = _parse_uk_date(m.group(1))
        out["period_end"]   = _parse_uk_date(m.group(2))

    return out


VENDOR_PROFILES = [parse_source_for_business]


def classify(ocr: str) -> dict | None:
    for prof in VENDOR_PROFILES:
        result = prof(ocr)
        if result:
            return result
    return None


# --- account_property_map lookup -------------------------------------------
def lookup_mapping(account_number: str | None,
                   vendor_domain: str | None) -> dict | None:
    if not account_number:
        return None
    sql = f"""
    SELECT entity_id, property_id, site, realm
      FROM account_property_map
     WHERE account_number = {sql_escape(account_number)}
       AND ({sql_escape(vendor_domain)} IS NULL
            OR vendor_domain IS NULL
            OR vendor_domain = {sql_escape(vendor_domain)})
     LIMIT 1;
    """
    result = psql(sql, set_local={"app.current_entity": "all"})
    if not result:
        return None
    parts = result.split("|")
    return {
        "entity_id":   int(parts[0]),
        "property_id": int(parts[1]) if parts[1] else None,
        "site":        parts[2] or None,
        "realm":       parts[3] or "work",
    }


# --- main -------------------------------------------------------------------
def main() -> int:
    ap = ArgumentParser()
    ap.add_argument("document_id", type=int)
    ap.add_argument("--default-entity-id", type=int, default=3,
                    help="entity to use when no mapping found (default 3=Personal)")
    args = ap.parse_args()

    ocr = psql(f"SELECT ocr_text FROM documents WHERE id = {args.document_id};")
    if not ocr:
        print(f"document_id={args.document_id} has no ocr_text", file=sys.stderr)
        return 1

    file_path = psql(f"SELECT COALESCE(file_path,'') FROM documents WHERE id={args.document_id};")
    bill = classify(ocr)
    if not bill:
        print("No vendor profile matched — leaving document for manual review", file=sys.stderr)
        return 2

    print(f"Recognised vendor: {bill['vendor_name']}", file=sys.stderr)
    for k in ("account_display", "gross_amount", "invoice_date", "due_date",
              "service_address", "period_start", "period_end"):
        if k in bill:
            print(f"  {k}: {bill[k]}", file=sys.stderr)

    mapping = lookup_mapping(bill.get("account_number"), bill["vendor_domain"])
    if mapping:
        entity_id  = mapping["entity_id"]
        realm      = mapping["realm"]
        print(f"Mapped → entity {entity_id} / property {mapping['property_id']} "
              f"/ site {mapping['site']}", file=sys.stderr)
    else:
        entity_id = args.default_entity_id
        realm     = "work" if entity_id in (1, 2) else "owner"
        print(f"⚠ no account_property_map entry for "
              f"{bill['vendor_domain']}/{bill.get('account_number')} — "
              f"defaulting to entity {entity_id}", file=sys.stderr)

    # Insert into vendor_invoice_inbox. source_email_id is NOT NULL on the
    # table but it accepts any text; we synthesise scan:<doc_id>.
    subject = f"{bill['vendor_name']} — {bill.get('service_address', '?')}"
    idk     = f"scan:{args.document_id}:{bill.get('account_number','x')}"
    sql = f"""
    INSERT INTO vendor_invoice_inbox (
        idempotency_key, source_email_id, account, entity_id, realm,
        vendor_domain, vendor_name, vendor_category,
        subject, received_at, invoice_date, due_date,
        amount_seen, gross_amount, net_amount,
        currency, attachment_count, first_attachment_path, has_pdf, status
    ) VALUES (
        {sql_escape(idk)},
        {sql_escape(f"scan:{args.document_id}")},
        {sql_escape(bill.get('account_display', bill.get('account_number','')))},
        {entity_id}, {sql_escape(realm)},
        {sql_escape(bill['vendor_domain'])},
        {sql_escape(bill['vendor_name'])},
        {sql_escape(bill['vendor_category'])},
        {sql_escape(subject)},
        NOW(),
        {sql_escape(bill.get('invoice_date'))}::date,
        {sql_escape(bill.get('due_date'))}::date,
        {bill.get('gross_amount', 'NULL')},
        {bill.get('gross_amount', 'NULL')},
        {bill.get('gross_amount', 'NULL')},
        {sql_escape(bill.get('currency','GBP'))},
        1,
        {sql_escape(file_path or None)},
        true,
        {sql_escape('new' if mapping else 'needs_mapping')}
    )
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING id;
    """
    inserted = psql(sql, set_local={
        "app.current_entity": str(entity_id),
        "app.current_realm":  realm,
    })
    if inserted:
        print(f"vendor_invoice_inbox id={inserted} (entity {entity_id}, "
              f"status={'new' if mapping else 'needs_mapping'})", file=sys.stderr)
    else:
        print("(already ingested — idempotency_key collision, no-op)", file=sys.stderr)

    psql(f"""
        SET LOCAL app.current_entity = '{entity_id}';
        UPDATE documents
           SET category = 'utility_bill',
               entity_id = {entity_id}
         WHERE id = {args.document_id};
    """)

    # If we couldn't map the account, drop a bot_instructions row so Jo gets
    # prompted to seed the registry next time he checks the queue.
    if not mapping and bill.get("account_number"):
        subj = (f"Map account {bill['account_display']} ({bill['vendor_name']}) "
                f"to a property")
        body = (
            f"New utility bill from {bill['vendor_name']} with account "
            f"{bill['account_display']} for '{bill.get('service_address','?')}'. "
            f"Add to account_property_map:\n"
            f"  INSERT INTO account_property_map (vendor_domain, vendor_name, "
            f"account_number, account_display, entity_id, property_id, site, "
            f"category_canonical) VALUES ("
            f"'{bill['vendor_domain']}', '{bill['vendor_name']}', "
            f"'{bill['account_number']}', '{bill['account_display']}', "
            f"<entity_id>, <property_id>, '<site>', "
            f"'{bill.get('category_canonical','utility')}');"
        )
        psql(f"""
        INSERT INTO bot_instructions (
            source, source_id, from_user, received_at,
            raw_subject, raw_text, status, entity_id, lane, realm
        ) VALUES (
            'scan-ingest',
            {sql_escape(f"scan:{args.document_id}")},
            'system', NOW(),
            {sql_escape(subj)},
            {sql_escape(body)},
            'pending', {entity_id}, 'data', 'owner'
        )
        ON CONFLICT (source, source_id) DO NOTHING;
        """)
        print("→ bot_instructions row opened for human mapping", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
