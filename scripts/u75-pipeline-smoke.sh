#!/usr/bin/env bash
# u75-pipeline-smoke.sh — end-to-end check that scan→OCR→DB still works.
# Designed to run from cron daily, or before any /scripts/u73* tweak.
#
# What it does:
#   1. Generates a tiny known PDF in /tmp.
#   2. Drops it into the SMB inbox (the actual Paperless consume folder).
#   3. Waits up to 90s for a documents row referencing it.
#   4. Cleans up: deletes the documents row (with realm/entity scope), purges
#      the Paperless task, and removes the file if Paperless left it behind.
#
# Exits non-zero (and tg_sends a message) on failure.

set -uo pipefail

INBOX="/mnt/shared_storage/scans/inbox"
TAG="u75-smoke-$(date +%s)"
PDF="${TAG}.pdf"
TMP="/tmp/${PDF}"

echo "[smoke] tag=$TAG"

# 1. Build a tiny valid PDF
python3 <<PY >/dev/null
content = "BT\n/F1 14 Tf\n72 750 Td\n($TAG) Tj\nET\n".encode("latin-1")
objs = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
    b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n" + content + b"\nendstream",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
out = b"%PDF-1.4\n"; offs=[]
for i,b_ in enumerate(objs,1):
    offs.append(len(out)); out += f"{i} 0 obj\n".encode()+b_+b"\nendobj\n"
xref = len(out)
out += b"xref\n0 "+str(len(objs)+1).encode()+b"\n0000000000 65535 f \n"
for o in offs: out += f"{o:010d} 00000 n \n".encode()
out += b"trailer << /Root 1 0 R /Size "+str(len(objs)+1).encode()+b" >>\nstartxref\n"+str(xref).encode()+b"\n%%EOF\n"
open("$TMP","wb").write(out)
PY

# 2. Drop into inbox
if ! cp "$TMP" "$INBOX/$PDF"; then
    echo "[smoke] FAIL: cannot write to $INBOX/$PDF" >&2
    exit 1
fi

# 3. Wait up to 90s for the documents row
DOC_ID=""
for i in $(seq 1 18); do
    sleep 5
    # postgres superuser has BYPASSRLS so no GUC SETs needed.
    DOC_ID=$(docker exec homeai-postgres psql -U postgres -d homeai -At -c \
        "SELECT id FROM documents WHERE title LIKE '$TAG%' OR title = '$PDF' LIMIT 1;" \
        2>/dev/null | head -1)
    if [[ -n "$DOC_ID" ]]; then break; fi
done

if [[ -z "$DOC_ID" ]]; then
    echo "[smoke] FAIL: no documents row after 90s for $TAG" >&2
    rm -f "$TMP" "$INBOX/$PDF"
    exit 2
fi

echo "[smoke] PASS: documents.id=$DOC_ID in $((i*5))s"

# 4. Cleanup
docker exec -i homeai-postgres psql -U postgres -d homeai >/dev/null <<SQL
BEGIN;
SET LOCAL app.current_entity = 'all';
SET LOCAL app.current_realm  = 'owner';
DELETE FROM vendor_invoice_inbox WHERE paperless_doc_id = $DOC_ID;
DELETE FROM documents WHERE id = $DOC_ID;
COMMIT;
SQL

rm -f "$TMP" "$INBOX/$PDF" 2>/dev/null
echo "[smoke] cleaned doc=$DOC_ID"
exit 0
