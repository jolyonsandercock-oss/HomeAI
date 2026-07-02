#!/usr/bin/env bash
#
# paperless-post-consume.sh — POST_CONSUME_SCRIPT for Paperless-ngx.
# Runs inside homeai-paperless after each document consume; posts a payload
# to build-dashboard /api/documents/ingest-from-paperless so the doc is
# mirrored into our documents + (if invoice/receipt/bill) vendor_invoice_inbox.
#
# Paperless invokes us with these env vars (per
# https://docs.paperless-ngx.com/configuration/#hooks):
#   DOCUMENT_ID            int
#   DOCUMENT_FILE_NAME     e.g. /usr/src/paperless/media/documents/originals/...pdf
#   DOCUMENT_SOURCE_PATH   the consume-folder source
#   DOCUMENT_ARCHIVE_PATH  PDF/A archive path (post-processing)
#   DOCUMENT_CREATED       ISO timestamp
#   DOCUMENT_MODIFIED      ISO timestamp
#   DOCUMENT_ADDED         ISO timestamp
#   DOCUMENT_DOWNLOAD_URL  /api/documents/$id/download/
#   DOCUMENT_THUMBNAIL_URL /api/documents/$id/thumb/
#   DOCUMENT_CORRESPONDENT
#   DOCUMENT_TAGS          comma-separated names
#   DOCUMENT_ORIGINAL_FILENAME
#
# We also need: ocr_text (Paperless API), mime_type, sha256, document_type.
# Pulls these from Paperless's own REST API.

set -euo pipefail

WEBHOOK_URL="${PAPERLESS_WEBHOOK_URL:-http://homeai-build-dashboard:8090/api/documents/ingest-from-paperless}"
SECRET="${PAPERLESS_WEBHOOK_SECRET:-}"
API_ROOT="http://localhost:8000/api"
API_TOKEN="${PAPERLESS_API_TOKEN:-}"

if [[ -z "$SECRET" ]]; then
    echo "[post-consume] ERROR: PAPERLESS_WEBHOOK_SECRET not set" >&2
    exit 1
fi
if [[ -z "$API_TOKEN" ]]; then
    echo "[post-consume] WARN: PAPERLESS_API_TOKEN not set — will skip OCR-text retrieval" >&2
fi

DOC_ID="${DOCUMENT_ID:-}"
[[ -z "$DOC_ID" ]] && { echo "[post-consume] no DOCUMENT_ID, skip" >&2; exit 0; }

# Fetch OCR text + document_type + sha256 via Paperless API.
OCR_TEXT=""
DOC_TYPE=""
SHA=""
MIME="application/pdf"
if [[ -n "$API_TOKEN" ]]; then
    META=$(curl -fsSL -H "Authorization: Token $API_TOKEN" "$API_ROOT/documents/$DOC_ID/" 2>/dev/null || echo "{}")
    OCR_TEXT=$(echo "$META" | python3 -c "import sys,json;print((json.load(sys.stdin).get('content') or '')[:30000])") || OCR_TEXT=""
    DOC_TYPE_ID=$(echo "$META" | python3 -c "import sys,json;v=json.load(sys.stdin).get('document_type');print(v if v else '')") || DOC_TYPE_ID=""
    if [[ -n "$DOC_TYPE_ID" ]]; then
        DOC_TYPE=$(curl -fsSL -H "Authorization: Token $API_TOKEN" "$API_ROOT/document_types/$DOC_TYPE_ID/" 2>/dev/null \
                   | python3 -c "import sys,json;print((json.load(sys.stdin).get('name') or '').lower())") || DOC_TYPE=""
    fi
    SHA=$(echo "$META" | python3 -c "import sys,json;print(json.load(sys.stdin).get('checksum') or '')") || SHA=""
fi

# Build JSON payload using Python so quoting is safe.
PAYLOAD=$(python3 -c "
import json, os
print(json.dumps({
    'paperless_id':  int(os.environ['DOCUMENT_ID']),
    'title':         os.environ.get('DOCUMENT_ORIGINAL_FILENAME') or f\"paperless-{os.environ['DOCUMENT_ID']}\",
    'original_path': os.environ.get('DOCUMENT_FILE_NAME', ''),
    'mime_type':     '$MIME',
    'sha256':        '$SHA',
    'ocr_text':      '''$OCR_TEXT'''[:30000],
    'tags':          [t.strip() for t in (os.environ.get('DOCUMENT_TAGS') or '').split(',') if t.strip()],
    'correspondent': os.environ.get('DOCUMENT_CORRESPONDENT') or None,
    'document_type': '''$DOC_TYPE''' or None,
    'secret':        '$SECRET',
}))
")

curl -fsSL -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$WEBHOOK_URL" \
    >/tmp/paperless-post-consume.last 2>&1 || true
echo "[post-consume] doc=$DOC_ID type=$DOC_TYPE size=$(echo "$OCR_TEXT" | wc -c) → $(cat /tmp/paperless-post-consume.last | head -c 120)"
