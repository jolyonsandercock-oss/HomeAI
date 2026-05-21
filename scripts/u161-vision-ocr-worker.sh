#!/bin/bash
# /home_ai/scripts/u161-vision-ocr-worker.sh
# U161 — pick next pending vision-OCR job and process it via u151b logic.
# Cron: */15 * * * *.

set -uo pipefail

VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
ANTHROPIC_KEY=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -field=api_key secret/anthropic)
PG_PASSWORD=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -field=password secret/postgres)
PG_DSN="postgresql://postgres:$PG_PASSWORD@homeai-postgres:5432/homeai"

# Pick one pending job
JOB=$(docker exec homeai-playwright python3 -c "
import os, asyncio, asyncpg
async def go():
    c = await asyncpg.connect('$PG_DSN')
    row = await c.fetchrow('''SELECT id, document_id, paperless_id FROM vision_ocr_jobs
        WHERE status='pending' AND attempts < 3 ORDER BY created_at LIMIT 1''')
    if not row: print('NONE'); return
    print(f\"{row['id']}|{row['document_id']}|{row['paperless_id']}\")
    await c.execute('''UPDATE vision_ocr_jobs SET status='running', started_at=NOW(),
        attempts=attempts+1 WHERE id=\$1''', row['id'])
    await c.close()
asyncio.run(go())
")

if [ "$JOB" = "NONE" ] || [ -z "$JOB" ]; then
  echo "no pending jobs"
  exit 0
fi

JOB_ID=$(echo "$JOB" | cut -d'|' -f1)
DOC_ID=$(echo "$JOB" | cut -d'|' -f2)
PAPERLESS_ID=$(echo "$JOB" | cut -d'|' -f3)

echo "── processing job $JOB_ID  doc_id=$DOC_ID  paperless_id=$PAPERLESS_ID"

# Pull the PDF from paperless
mkdir -p /home_ai/data/mortgage-vision-ocr
docker cp homeai-paperless:/usr/src/paperless/media/documents/originals/$(printf '%07d' $PAPERLESS_ID).pdf \
  /home_ai/data/mortgage-vision-ocr/paperless-$PAPERLESS_ID.pdf 2>&1 | tail -1
docker exec homeai-playwright mkdir -p /home_ai/data/mortgage-vision-ocr
docker cp /home_ai/data/mortgage-vision-ocr/paperless-$PAPERLESS_ID.pdf homeai-playwright:/home_ai/data/mortgage-vision-ocr/

# Run u151b logic on just this PDF (move others aside)
docker exec homeai-playwright sh -c "
mkdir -p /home_ai/data/mortgage-vision-ocr/_staging
for f in /home_ai/data/mortgage-vision-ocr/paperless-*.pdf; do
  case \"\$f\" in
    */paperless-$PAPERLESS_ID.pdf) ;;
    *) mv \"\$f\" /home_ai/data/mortgage-vision-ocr/_staging/ 2>/dev/null;;
  esac
done
"

RESULT=$(docker exec -e PG_DSN="$PG_DSN" -e ANTHROPIC_API_KEY="$ANTHROPIC_KEY" \
  homeai-playwright python3 /tmp/u151b.py 2>&1 | tail -5)

PERIODS_ADDED=$(echo "$RESULT" | grep -oE "'inserted': [0-9]+" | head -1 | grep -oE "[0-9]+")
PERIODS_ADDED=${PERIODS_ADDED:-0}
echo "  result: $RESULT"
echo "  periods added: $PERIODS_ADDED"

# Restore staging
docker exec homeai-playwright sh -c "mv /home_ai/data/mortgage-vision-ocr/_staging/* /home_ai/data/mortgage-vision-ocr/ 2>/dev/null; rmdir /home_ai/data/mortgage-vision-ocr/_staging 2>/dev/null"

# Mark job done + flip doc.vision_ocr_done
docker exec homeai-playwright python3 -c "
import asyncio, asyncpg
async def go():
    c = await asyncpg.connect('$PG_DSN')
    await c.execute('SET app.current_entity = ' + chr(39) + 'all' + chr(39))
    await c.execute(\"SELECT home_ai.set_realm('owner')\")
    await c.execute('''UPDATE vision_ocr_jobs SET status='done', completed_at=NOW(),
        periods_added=\$1 WHERE id=\$2''', $PERIODS_ADDED, $JOB_ID)
    await c.execute('UPDATE documents SET vision_ocr_done=true WHERE id=\$1', $DOC_ID)
    await c.close()
asyncio.run(go())
"

echo "✓ job $JOB_ID done"
