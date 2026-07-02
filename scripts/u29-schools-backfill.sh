#!/bin/bash
# /home_ai/scripts/u29-schools-backfill.sh
#
# Filler-grade backfill of last 90 days of school correspondence into
# child_events. Maps sender domain → child via children.school_email_domain.
#
# No AI extraction — just (event_date, summary=subject, child_id, source_email_id).
# A later sprint can enrich with Haiku to set urgency/deadline/etc.
#
# Idempotent: idempotency_key = 'school_<gmail_msg_id>'.

set -euo pipefail

SCHOOL_DOMAINS=("stjosephscornwall.co.uk" "stbreock.org.uk" "wadebridgeprimary.co.uk")
NEWER_THAN="${1:-90d}"
ACCOUNT="${2:-jo}"

echo "── backfill: account=$ACCOUNT newer_than=$NEWER_THAN ──"

# Build the Gmail q= covering all three domains in one search.
q="newer_than:$NEWER_THAN ("
for i in "${!SCHOOL_DOMAINS[@]}"; do
  [[ $i -gt 0 ]] && q="$q OR "
  q="${q}from:${SCHOOL_DOMAINS[$i]}"
done
q="$q)"

echo "── search ($q) ──"
msgs_json=$(docker exec homeai-google-fetch python -c "
import urllib.request, json, urllib.parse
url = 'http://localhost:8011/messages?account=$ACCOUNT&max_results=500&q=' + urllib.parse.quote('''$q''')
r = urllib.request.urlopen(url, timeout=60)
print(r.read().decode())
")
total=$(echo "$msgs_json" | python3 -c "import json,sys;print(json.load(sys.stdin)['count'])")
echo "── matched $total emails ──"

# Build a domain → child_id map from the DB.
declare -A CHILD_MAP
while IFS=$'\t' read -r dom cid; do
  CHILD_MAP[$dom]="$cid"
done < <(docker exec homeai-postgres psql -U postgres -d homeai -tAF $'\t' -c \
         "SELECT school_email_domain, id FROM children WHERE school_email_domain IS NOT NULL;")

inserted=0
skipped=0
errors=0

while IFS=$'\t' read -r mid from_addr subject internal_date; do
  [[ -z "$mid" ]] && continue
  # Pick the matching school domain from the From header.
  child_id=""
  for dom in "${SCHOOL_DOMAINS[@]}"; do
    if [[ "$from_addr" == *"@$dom"* || "$from_addr" == *"$dom>"* ]]; then
      child_id="${CHILD_MAP[$dom]:-}"
      break
    fi
  done
  if [[ -z "$child_id" ]]; then
    errors=$((errors + 1))
    continue
  fi
  # Date: internal_date is epoch ms.
  event_date=$(date -u -d "@$((internal_date / 1000))" '+%Y-%m-%d' 2>/dev/null || echo '2000-01-01')

  # INSERT — RLS requires SET LOCAL on the same transaction.
  out=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc "
    BEGIN;
    SET LOCAL app.current_entity = '3';
    INSERT INTO child_events (idempotency_key, child_id, event_type, event_date, summary)
    VALUES ('school_$mid', $child_id, 'school_correspondence', '$event_date',
            \$\$$(echo "$subject" | tr "'" '_' | cut -c1-300)\$\$)
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING 1;
    COMMIT;" 2>&1 | tr -d '[:space:]') || true
  if [[ "$out" == "1" ]]; then
    inserted=$((inserted + 1))
  else
    skipped=$((skipped + 1))
  fi
done < <(echo "$msgs_json" | python3 -c "
import json, sys
o = json.load(sys.stdin)
for m in o.get('messages', []):
    print('\t'.join([
        m.get('id',''),
        (m.get('from') or '').replace('\t',' '),
        (m.get('subject') or '').replace('\t',' ')[:300],
        str(m.get('internal_date') or '0'),
    ]))
")

echo
echo "── done: $inserted inserted, $skipped skipped (already loaded), $errors errors ──"
exit 0
