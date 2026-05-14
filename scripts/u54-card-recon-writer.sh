#!/usr/bin/env bash
#
# u54-card-recon-writer.sh — flag Dojo↔TouchOffice card mismatches.
#
# Reads v_card_reconciliation, INSERTs a reconciliation_flags row for every
# (date, site) where status='mismatch' and there is not already an open flag
# for the same date+site+flag_type. Sends a single Telegram digest if at
# least one new flag was written (so a quiet day stays quiet).
#
# Window: yesterday and the 6 days before. We deliberately skip today
# because the Dojo CSV is imported manually; today's row is incomplete
# until Jo re-imports.
#
# Idempotency: existing open flags on the same (description-prefix, date)
# are NOT duplicated.
#
# Exit codes:
#   0 — no new flags (or new flags only, both ok)
#   2 — DB error

set -euo pipefail

LOG_PFX="[u54-card-recon]"

# Insert new flags for unflagged mismatches yesterday and prior week,
# skipping today (CSV import is manual).
NEW_FLAGS=$(docker exec -i homeai-postgres psql -U postgres -d homeai -X -q -A -t <<'SQL' 2>/dev/null
WITH candidate AS (
    SELECT date, site, touchoffice_card, dojo_gross, delta
      FROM v_card_reconciliation
     WHERE status = 'mismatch'
       AND date BETWEEN now()::date - INTERVAL '7 days' AND now()::date - INTERVAL '1 day'
),
not_yet_flagged AS (
    SELECT c.*
      FROM candidate c
     WHERE NOT EXISTS (
        SELECT 1 FROM reconciliation_flags f
         WHERE f.flag_type = 'card_dojo_vs_touchoffice'
           AND f.status = 'open'
           AND f.description LIKE 'date=' || c.date || ' site=' || c.site || '%'
     )
),
ins AS (
    INSERT INTO reconciliation_flags (entity_id, flag_type, description, status, realm)
    SELECT 1, 'card_dojo_vs_touchoffice',
           format('date=%s site=%s to=£%s dojo=£%s delta=£%s',
                  date, site, touchoffice_card, dojo_gross, delta),
           'open', 'work'
      FROM not_yet_flagged
    RETURNING id, description
)
SELECT description FROM ins ORDER BY 1;
SQL
)

if [[ -z "$NEW_FLAGS" ]]; then
    echo "${LOG_PFX} no new mismatches"
    exit 0
fi

count=$(echo "$NEW_FLAGS" | wc -l | tr -d ' ')
echo "${LOG_PFX} wrote ${count} new flag(s):"
echo "$NEW_FLAGS" | sed 's/^/  /'

# Telegram digest — one message for the lot, not one per flag.
preview=$(echo "$NEW_FLAGS" | head -n 5 | sed 's/^/• /')
extra=""
[[ $count -gt 5 ]] && extra=" (+$((count-5)) more)"
msg="<b>Card recon: ${count} new mismatch(es)${extra}</b>%0A${preview//$'\n'/%0A}"

bash /home_ai/.claude/scripts/notify-telegram.sh "$msg" "u54-card-recon" >/dev/null
exit 0
