#!/bin/bash
# /home_ai/scripts/u159-revenue-email.sh
# Daily 09:00 — yesterday's gross revenue narrative to Jo's inbox.
# Mirrors u109 format (HTML table + bold + colour pct).

set -euo pipefail

YESTERDAY=$(date -d 'yesterday' +%Y-%m-%d)
TODAY=$(date +%Y-%m-%d)

VAULT_TOKEN=$(docker inspect homeai-critical-listener --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)
ANTHROPIC_KEY=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault vault kv get -field=api_key secret/anthropic)

# Pull yesterday's revenue breakdown
PAYLOAD=$(docker exec homeai-playwright python3 -c "
import urllib.request, json, urllib.parse
url = 'http://homeai-build-dashboard:8090/api/finance/slug/frontend_revenue_breakdown_by_day?for_date=$YESTERDAY'
r = urllib.request.urlopen(urllib.request.Request(url, headers={'X-Realm':'owner'}), timeout=15)
print(r.read().decode())
")

# Pull comparison: same DOW last week
LAST_WEEK_PAYLOAD=$(docker exec homeai-playwright python3 -c "
import urllib.request, json, urllib.parse
last = '$(date -d 'yesterday - 7 days' +%Y-%m-%d)'
url = f'http://homeai-build-dashboard:8090/api/finance/slug/frontend_revenue_breakdown_by_day?for_date={last}'
r = urllib.request.urlopen(urllib.request.Request(url, headers={'X-Realm':'owner'}), timeout=15)
print(r.read().decode())
")

# Build prompt for Sonnet narrative
PROMPT=$(python3 -c "
import json
payload = json.loads('''$PAYLOAD''')
last_week = json.loads('''$LAST_WEEK_PAYLOAD''')

rows_y = payload.get('rows', [])
rows_lw = last_week.get('rows', [])

ytotal = sum(r['gross_gbp'] for r in rows_y if r.get('source') != 'card_payments')
lwtotal = sum(r['gross_gbp'] for r in rows_lw if r.get('source') != 'card_payments')
card_y = sum(r['gross_gbp'] for r in rows_y if r['source']=='card_payments')

print(f'''Generate a 2-3 sentence email body summarising yesterday revenue for The Olde Malthouse Inn.

Yesterday ({rows_y[0].get(\"source\",\"?\") if rows_y else \"?\"} format):
- Yesterday rows: {json.dumps(rows_y, indent=2)}
- Last-week-same-DOW rows: {json.dumps(rows_lw, indent=2)}
- Total non-card revenue yesterday: £{ytotal:.2f}
- Same DOW last week: £{lwtotal:.2f}
- Card take yesterday: £{card_y:.2f}

Write 2-3 sentences calling out: (a) the headline number, (b) the WoW comparison with %, (c) the most-significant contributor. Keep it operational, not gushing. End with one practical observation.''')
")

# Get Sonnet narrative
NARRATIVE=$(docker exec -e ANTHROPIC_API_KEY="$ANTHROPIC_KEY" homeai-playwright python3 -c "
import urllib.request, json, os, time
prompt = '''$PROMPT'''
req = urllib.request.Request('https://api.anthropic.com/v1/messages',
    data=json.dumps({
        'model': 'claude-sonnet-4-6',
        'max_tokens': 400,
        'messages': [{'role':'user','content':prompt}]
    }).encode(),
    headers={
        'x-api-key': os.environ['ANTHROPIC_API_KEY'],
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json'
    })
o = None
for _a in range(6):
    try:
        o = json.loads(urllib.request.urlopen(req, timeout=30).read()); break
    except Exception as e:
        if _a < 5:
            time.sleep(min(60, 2 * (2 ** _a))); continue
        raise
print(o['content'][0]['text'])
")

# Build HTML email (u109 v4 style)
HTML=$(python3 -c "
import json, html
payload = json.loads('''$PAYLOAD''')
rows = payload.get('rows', [])
narrative = '''$NARRATIVE'''

# Group by source
by_source = {}
for r in rows:
    by_source.setdefault(r['source'], []).append(r)

html_body = f'''
<div style=\"font-family: -apple-system, sans-serif; max-width: 600px;\">
<h2>📊 Revenue — $(date -d 'yesterday' +'%a %-d %b')</h2>
<p>{narrative}</p>
<hr>
'''
for source, items in by_source.items():
    src_total = sum(i['gross_gbp'] for i in items)
    html_body += f'<h3>{source.replace(\"_\",\" \").title()}: £{src_total:,.2f}</h3><table style=\"width:100%;border-collapse:collapse\">'
    for i in items:
        html_body += f'<tr><td style=\"padding:4px 8px\">{html.escape(str(i.get(\"subcategory\",\"\")))}</td><td style=\"text-align:right;padding:4px 8px\"><b>£{i[\"gross_gbp\"]:,.2f}</b></td></tr>'
    html_body += '</table>'
html_body += '<hr><p style=\"color:#999;font-size:0.8em\">U159 revenue close-loop · auto-generated 09:00</p></div>'
print(html_body)
")

# Send via google-fetch /send/bot
docker exec homeai-bot-responder python3 -c "
import os, urllib.request, json
payload = {
    'to': 'jolyon.sandercock@gmail.com',
    'subject': f'📊 Revenue: $(date -d yesterday +%a\ %-d\ %b) — £$(echo $HTML | grep -oE 'Revenue.*£[0-9,]+' | head -1 | grep -oE '£[0-9,]+' | head -1)',
    'reply_to': 'jolyboxbot@gmail.com',
    'body_text': '''$NARRATIVE''',
    'body_html': '''$HTML'''
}
req = urllib.request.Request('http://google-fetch:8011/send/bot', method='POST',
    data=json.dumps(payload).encode(),
    headers={'Content-Type':'application/json'})
r = urllib.request.urlopen(req, timeout=30)
print(json.loads(r.read()).get('message_id','?'))
"

echo "✓ revenue email for $YESTERDAY sent"
