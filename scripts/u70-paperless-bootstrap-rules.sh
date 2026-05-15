#!/usr/bin/env bash
# u70-paperless-bootstrap-rules.sh — one-shot: create the canonical document
# types our webhook routes on (`invoice`, `receipt`, `bill`, `letter`) plus a
# match rule so PDFs containing "invoice"/"VAT"/"tax invoice" auto-classify
# as invoices. Idempotent.

set -euo pipefail

VAULT_TOKEN=$(docker inspect homeai-bot-responder \
  --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep '^VAULT_TOKEN=' | cut -d= -f2-)
TOKEN=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault \
        vault kv get -field=token secret/paperless/api)
API="http://100.104.82.53:8011/api"

doctype_id() {  # name -> id (or empty)
    curl -fsS -H "Authorization: Token $TOKEN" "$API/document_types/?name__iexact=$1" \
      | python3 -c "import sys,json;r=json.load(sys.stdin)['results'];print(r[0]['id'] if r else '')"
}

create_doctype() {  # name -> id (creates if absent)
    local name="$1" id
    id=$(doctype_id "$name")
    if [[ -z "$id" ]]; then
        id=$(curl -fsS -X POST -H "Authorization: Token $TOKEN" \
                -H 'Content-Type: application/json' \
                -d "{\"name\":\"$name\",\"matching_algorithm\":0,\"match\":\"\",\"is_insensitive\":true}" \
                "$API/document_types/" \
              | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
        echo "  ✓ created document_type '$name' → id=$id"
    else
        echo "  • document_type '$name' already exists (id=$id)"
    fi
    printf '%s' "$id"
}

# Create the four canonical types.
INV_ID=$(create_doctype invoice)
create_doctype receipt >/dev/null
create_doctype bill    >/dev/null
create_doctype letter  >/dev/null

# Add an auto-matching rule on "invoice": algorithm=3 (any-word match),
# tokens "invoice tax-invoice VAT". Idempotent on existing match string.
existing_match=$(curl -fsS -H "Authorization: Token $TOKEN" "$API/document_types/$INV_ID/" \
                 | python3 -c "import sys,json;d=json.load(sys.stdin);print((d.get('match') or '').strip())")
# Paperless matching_algorithm: 0=none, 1=any-words, 2=all-words, 3=literal,
# 4=regex, 5=fuzzy, 6=auto. We want ANY-of-words (1).
if [[ -z "$existing_match" ]]; then
    curl -fsS -X PATCH -H "Authorization: Token $TOKEN" \
         -H 'Content-Type: application/json' \
         -d '{"matching_algorithm": 1, "match": "invoice VAT receipt", "is_insensitive": true}' \
         "$API/document_types/$INV_ID/" >/dev/null
    echo "  ✓ invoice match rule installed"
else
    echo "  • invoice match rule already set ($existing_match)"
fi

echo "All four document types ready."
