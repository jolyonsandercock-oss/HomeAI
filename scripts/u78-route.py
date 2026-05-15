#!/usr/bin/env python3
"""u78-route.py — auto-classify documents that arrived via Paperless and
   dispatch them to the right U78 ingester (Clover statement → clover_batches,
   utility bill → vendor_invoice_inbox). Run after u62-paperless-sync.sh.

   A document is "candidate" when its category is NULL or 'paperless' (the
   default tag from Paperless). The ingest scripts overwrite category once
   they've handled the doc, so re-runs are no-ops.
"""
import re
import subprocess
import sys


def psql(sql: str) -> str:
    out = subprocess.run(
        ["docker", "exec", "-i", "homeai-postgres",
         "psql", "-U", "postgres", "-d", "homeai",
         "-tAq", "-v", "ON_ERROR_STOP=1"],
        input=sql, text=True, capture_output=True, check=True,
    )
    return out.stdout.strip()


def detect(ocr: str) -> str | None:
    """Return 'clover' / 'utility' / None based on fingerprints in OCR."""
    if re.search(r"MERCHANT CARD PROCESSING STATEMENT", ocr, re.IGNORECASE) \
       or re.search(r"\bclover\b.*Merchant Number", ocr, re.IGNORECASE | re.DOTALL):
        return "clover"
    if "source4b.co.uk" in ocr.lower() or "Source\nfor Business" in ocr:
        return "utility"
    return None


SCRIPTS = {
    "clover":  ("/home_ai/scripts/u78-ingest-clover.py",
                ["--entity-id", "1", "--site", "accom"]),
    "utility": ("/home_ai/scripts/u78-ingest-utility.py",
                ["--default-entity-id", "3"]),
}


def main() -> int:
    rows = psql("""
        SELECT id FROM documents
         WHERE category IS NULL OR category = 'paperless'
         ORDER BY id;
    """)
    if not rows:
        print("u78-route: no candidate documents")
        return 0

    routed = skipped = 0
    for doc_id in rows.splitlines():
        ocr = psql(f"SELECT COALESCE(ocr_text,'') FROM documents WHERE id={doc_id};")
        kind = detect(ocr)
        if not kind:
            skipped += 1
            continue
        script, args = SCRIPTS[kind]
        print(f"u78-route: doc {doc_id} → {kind}")
        rc = subprocess.call([script, doc_id, *args])
        if rc == 0:
            routed += 1
        else:
            print(f"  ⚠ {kind} ingester exited {rc}", file=sys.stderr)
    print(f"u78-route: routed={routed} skipped(unrecognised)={skipped}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
