#!/bin/bash
# projA-daily.sh — ongoing invoice capture + future-vendor auto-tag.
# 1. extract any NEW inbox invoices into purchases (idempotent, capped spend)
# 2. auto-categorise from each vendor's learned (verified) category
# Self-heals the bot-responder /app copies (writable layer is wiped on recreate).
set -euo pipefail
docker cp /home_ai/scripts/projA/ladder.py homeai-bot-responder:/app/ladder.py 2>/dev/null
docker cp /home_ai/ai_schemas/invoice_extract.schema.json homeai-bot-responder:/app/invoice_extract.schema.json 2>/dev/null
docker exec homeai-bot-responder python3 /app/ladder.py --limit 0 --max-cloud-usd 3
docker exec homeai-postgres psql -U postgres -d homeai -c "SELECT home_ai.propagate_vendor_categories() AS auto_tagged;"
