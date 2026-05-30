#!/bin/bash
# /home_ai/scripts/trigger-touchoffice.sh
# Force a TouchOffice scrape + bridge run for today.
# Launches in background and returns immediately.
# Usage: bash trigger-touchoffice.sh

set -uo pipefail
LOG="/home_ai/logs/touchoffice-trigger.log"
TODAY=$(date '+%Y-%m-%d')

echo "$(date -Iseconds) — manual trigger requested" >> "$LOG"

# Step 1: Scrape + ingest via the existing pipeline
docker exec homeai-playwright python -c "
import urllib.request, json, sys
results = {}
for site in ['malthouse', 'sandwich']:
    url = f'http://localhost:8001/ingest/touchoffice?site={site}&date=$TODAY'
    for attempt in range(1, 4):
        try:
            resp = urllib.request.urlopen(url, timeout=120)
            results[site] = json.loads(resp.read())
            break
        except Exception as e:
            results[site] = {'error': str(e)[:100]}
            if attempt < 3:
                import time
                time.sleep(10)
print(json.dumps(results))
" >> "$LOG" 2>&1

echo "  scrape done, exit=$?" >> "$LOG"

# Step 2: Run the bridge to epos_daily_reports
docker exec homeai-bot-responder python3 /app/touchoffice-to-epos.py >> "$LOG" 2>&1
echo "  bridge done, exit=$?" >> "$LOG"

echo "$(date -Iseconds) — trigger complete" >> "$LOG"
