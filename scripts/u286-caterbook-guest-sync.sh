#!/bin/bash
# u286-caterbook-guest-sync.sh — wrapper: run the Caterbook API guest sync in
# the playwright container (egress + vault) and apply its emitted SQL on the
# host side (playwright has no docker/db access). Fills NULL guest_email/
# guest_phone on accommodation_bookings only — never overwrites.
# Cron: 05:37 daily (after the 03:xx scrape window). Window: -7/+45 in cron
# mode; first run used -30/+120.
set -euo pipefail
WINDOW_BACK="${1:-7}"
WINDOW_FWD="${2:-45}"
VT=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

applied=0
while IFS= read -r line; do
  case "$line" in
    SQL$'\t'*)
      sql="${line#SQL$'\t'}"
      # NO -i here: an interactive exec inside a while-read loop inherits the
      # loop's stdin and slurps the remaining python output (lost SQL + # done)
      docker exec homeai-postgres psql -d homeai -U postgres -q \
        -c "SET app.current_entity='all';" -c "$sql" >/dev/null 2>&1 && applied=$((applied+1))
      ;;
    *) echo "$line" ;;
  esac
done < <(docker exec -i -e VAULT_TOKEN="$VT" -e WINDOW_BACK="$WINDOW_BACK" -e WINDOW_FWD="$WINDOW_FWD" \
           homeai-playwright python3 - < /home_ai/scripts/u286-caterbook-guest-sync.py)
echo "$(date -Is) [u286] applied $applied contact updates"
docker exec -i homeai-postgres psql -d homeai -U postgres -tAc "SET app.current_entity='all';
SELECT 'coverage: phones='||count(guest_phone)||'/'||count(*)||' emails='||count(guest_email)
FROM accommodation_bookings WHERE checkin_date >= current_date - ${WINDOW_BACK};" 2>/dev/null | tail -1 || true
