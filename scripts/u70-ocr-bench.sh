#!/usr/bin/env bash
# u70-ocr-bench.sh — compare OCR adapters on the documents.ocr_text already
# captured for invoice-typed Paperless docs. Today (only tesseract wired)
# this just reports baseline coverage. When you `vault kv put secret/azure-di`
# or `secret/mistral-ocr`, re-running adds those engines to the comparison.
#
# Output: a single SQL-driven markdown report on stdout.

set -euo pipefail

docker exec -i homeai-postgres psql -U postgres -d homeai -At <<'SQL'
SELECT set_config('app.current_entity','all',false);
SELECT home_ai.set_realm('owner');

\echo '## U70 OCR baseline — Paperless-tesseract'
\echo
\echo '| paperless_id | title | chars | extraction_method | confidence |'
\echo '|---|---|---|---|---|'
SELECT '| ' || d.paperless_id || ' | ' || left(d.title, 30) || ' | ' || length(d.ocr_text)
       || ' | ' || COALESCE(vii.extraction_method, '—')
       || ' | ' || COALESCE(vii.extraction_confidence::text, '—') || ' |'
  FROM documents d
  LEFT JOIN vendor_invoice_inbox vii ON vii.paperless_doc_id = d.id
 WHERE d.paperless_id IS NOT NULL
 ORDER BY d.paperless_id;

\echo
\echo '## Adapter availability (from Vault + system_state)'

SELECT '- preferred: **' || value || '**'
  FROM system_state WHERE key = 'ocr.engine';
SQL

# Show which premium adapters could activate (Vault check)
echo
echo "## Vault adapter credentials"
VT=$(docker inspect homeai-bot-responder --format '{{range .Config.Env}}{{println .}}{{end}}' \
     | grep '^VAULT_TOKEN=' | cut -d= -f2-)
for path in azure-di mistral-ocr; do
    if docker exec -e VAULT_TOKEN="$VT" homeai-vault \
       vault kv get -format=json "secret/$path" >/dev/null 2>&1; then
        echo "- $path → **available**"
    else
        echo "- $path → unset (adapter inactive)"
    fi
done
unset VT
