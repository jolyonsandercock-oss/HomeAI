#!/bin/bash
# /home_ai/scripts/r1-dress-rehearsal.sh
#
# Dress rehearsal for R2 (RLS enforcement). RLS isn't yet keyed on realm —
# this script simulates what R2's policy will see by manually filtering on
# the realm column. Use it to catch surprise rows (e.g. a caterbook row
# tagged 'family') before R2 actually flips RLS.

set -euo pipefail

PG_CONTAINER="${PG_CONTAINER:-homeai-postgres}"
PG_DB="${PG_DB:-homeai}"
PG_USER="${PG_USER:-postgres}"

psql() {
    docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -X "$@"
}

echo "═══════════════════════════════════════════════════════════════════════"
echo " R1 dress rehearsal — what each realm WILL see when R2 enforces RLS"
echo "═══════════════════════════════════════════════════════════════════════"
echo

# Representative sample of tables across all three realms + cross-realm.
SAMPLE_TABLES=(
    "emails"
    "events"
    "vendor_invoice_inbox"
    "touchoffice_fixed_totals"
    "caterbook_observations"
    "workforce_shifts"
    "properties"
    "rent_payments"
    "vehicles"
    "audit_log"
    "bot_instructions"
    "dreaming_heuristics"
    "weather_daily"
    "entities"
)

echo "Per-table row count by realm:"
echo
printf "%-32s %8s %8s %8s %8s\n" "table" "owner" "work" "family" "shared"
printf "%-32s %8s %8s %8s %8s\n" "--------------------------------" "--------" "--------" "--------" "--------"

for tbl in "${SAMPLE_TABLES[@]}"; do
    counts=$(psql -tA -c "
        SELECT
            COUNT(*) FILTER (WHERE realm='owner'),
            COUNT(*) FILTER (WHERE realm='work'),
            COUNT(*) FILTER (WHERE realm='family'),
            COUNT(*) FILTER (WHERE realm='shared')
          FROM $tbl;
    ")
    IFS='|' read -r o w f s <<<"$counts"
    printf "%-32s %8s %8s %8s %8s\n" "$tbl" "$o" "$w" "$f" "$s"
done

echo
echo "═══════════════════════════════════════════════════════════════════════"
echo " R2 visibility preview (what each realm will see when logged in)"
echo "═══════════════════════════════════════════════════════════════════════"
echo

simulate_realm() {
    local r=$1
    echo "── as realm='$r' ──"
    psql -c "
        SELECT
            'emails' AS tbl,
            COUNT(*) FILTER (WHERE realm IN ('$r','shared') OR '$r'='owner') AS visible,
            COUNT(*) AS total
        FROM emails
        UNION ALL
        SELECT 'events',
            COUNT(*) FILTER (WHERE realm IN ('$r','shared') OR '$r'='owner'),
            COUNT(*)
        FROM events
        UNION ALL
        SELECT 'vendor_invoice_inbox',
            COUNT(*) FILTER (WHERE realm IN ('$r','shared') OR '$r'='owner'),
            COUNT(*)
        FROM vendor_invoice_inbox
        UNION ALL
        SELECT 'touchoffice_fixed_totals',
            COUNT(*) FILTER (WHERE realm IN ('$r','shared') OR '$r'='owner'),
            COUNT(*)
        FROM touchoffice_fixed_totals
        UNION ALL
        SELECT 'rent_payments',
            COUNT(*) FILTER (WHERE realm IN ('$r','shared') OR '$r'='owner'),
            COUNT(*)
        FROM rent_payments
        UNION ALL
        SELECT 'audit_log',
            COUNT(*) FILTER (WHERE realm IN ('$r','shared') OR '$r'='owner'),
            COUNT(*)
        FROM audit_log
        UNION ALL
        SELECT 'weather_daily',
            COUNT(*) FILTER (WHERE realm IN ('$r','shared') OR '$r'='owner'),
            COUNT(*)
        FROM weather_daily
        ORDER BY 1;
    "
}

simulate_realm "owner"
simulate_realm "work"
simulate_realm "family"

echo
echo "═══════════════════════════════════════════════════════════════════════"
echo " Surprise-row check (rows with unexpected realm for their table kind)"
echo "═══════════════════════════════════════════════════════════════════════"
echo

psql -c "
    -- caterbook/touchoffice/workforce must all be 'work'
    SELECT 'caterbook_observations'    AS tbl, realm, COUNT(*) FROM caterbook_observations    WHERE realm != 'work' GROUP BY realm
    UNION ALL
    SELECT 'touchoffice_fixed_totals',  realm, COUNT(*) FROM touchoffice_fixed_totals WHERE realm != 'work' GROUP BY realm
    UNION ALL
    SELECT 'workforce_shifts',          realm, COUNT(*) FROM workforce_shifts         WHERE realm != 'work' GROUP BY realm
    -- properties/rent/vehicles/children must all be 'family'
    UNION ALL
    SELECT 'properties',                realm, COUNT(*) FROM properties               WHERE realm != 'family' GROUP BY realm
    UNION ALL
    SELECT 'rent_payments',             realm, COUNT(*) FROM rent_payments            WHERE realm != 'family' GROUP BY realm
    UNION ALL
    SELECT 'vehicles',                  realm, COUNT(*) FROM vehicles                 WHERE realm != 'family' GROUP BY realm
    ;
"
echo "(Empty result above = no surprises. Investigate any row that prints.)"
echo
echo "✓ Dress rehearsal complete. If counts look right, R2 (RLS enforcement) is safe to plan."
