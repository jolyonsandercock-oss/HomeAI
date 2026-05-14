#!/bin/bash
# /home_ai/scripts/u53-r5-realm-backfill.sh
#
# R5 ingest-tagging audit + backfill.
#
# Audits the last 30 days of emails / email_attachments / events
# (email.received + document.received) / vendor_invoice_inbox for
# `realm` values that disagree with the SPEC §2.5 mailbox map:
#   info / admin / stay → work
#   jo   / pounana      → family
#   bot                  → owner
#
# Usage:
#   bash u53-r5-realm-backfill.sh --audit-only   (default; just report)
#   bash u53-r5-realm-backfill.sh --apply        (UPDATE mismatches
#                                                  via home_ai.realm_override
#                                                  — requires V67 + owner GUC)

set -uo pipefail

MODE="${1:---audit-only}"

# Peer auth from inside the postgres container — no PGPASSWORD needed.
PSQL="docker exec -i homeai-postgres psql -U postgres -d homeai -A -t"

# ── Mailbox → realm reference table, materialised as a CTE so the
#     audit query can join it. Keep in sync with _MAILBOX_REALM in
#     services/google-fetch/main.py.
MAILBOX_MAP="
WITH mailbox_realm(account, expected) AS (VALUES
    ('info',    'work'),
    ('admin',   'work'),
    ('stay',    'work'),
    ('jo',      'family'),
    ('pounana', 'family'),
    ('bot',     'owner')
)
"

echo "── R5 realm audit ──"

mismatches_total=0

run_audit() {
    local table="$1"     # display name
    local query="$2"
    local count
    count=$( $PSQL <<< "$query" 2>&1 | tr -d ' ' )
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        printf "  %-28s ERROR: %s\n" "$table" "$count"
        mismatches_total=$(( mismatches_total + 1 ))
        return
    fi
    printf "  %-28s %s\n" "$table" "$count mismatches"
    mismatches_total=$(( mismatches_total + count ))
}

run_audit "emails (30d)" "
${MAILBOX_MAP}
SELECT COUNT(*) FROM emails e
  JOIN mailbox_realm m USING (account)
 WHERE e.received_at > now() - interval '30 days'
   AND e.realm IS DISTINCT FROM m.expected;
"

run_audit "events.email.received (30d)" "
${MAILBOX_MAP}
SELECT COUNT(*) FROM events ev
  JOIN mailbox_realm m ON m.account = ev.payload->>'account'
 WHERE ev.event_type = 'email.received'
   AND ev.created_at > now() - interval '30 days'
   AND ev.realm IS DISTINCT FROM m.expected;
"

run_audit "events.document.received (30d)" "
${MAILBOX_MAP}
SELECT COUNT(*) FROM events ev
  JOIN mailbox_realm m ON m.account = ev.payload->>'account'
 WHERE ev.event_type = 'document.received'
   AND ev.created_at > now() - interval '30 days'
   AND ev.realm IS DISTINCT FROM m.expected;
"

run_audit "vendor_invoice_inbox (30d)" "
${MAILBOX_MAP}
SELECT COUNT(*) FROM vendor_invoice_inbox v
  JOIN mailbox_realm m USING (account)
 WHERE v.received_at > now() - interval '30 days'
   AND v.realm IS DISTINCT FROM m.expected;
"

echo "── total mismatches: $mismatches_total"

if [[ "$MODE" == "--audit-only" ]]; then
    exit $([[ $mismatches_total -eq 0 ]] && echo 0 || echo 1)
fi

if [[ "$MODE" != "--apply" ]]; then
    echo "Unknown mode: $MODE" >&2
    exit 2
fi

# ── --apply path: walk the 4 tables, call home_ai.realm_override for each
#     row whose realm disagrees with the mailbox map. Audit_log records each.
echo
echo "── R5 apply (via home_ai.realm_override) ──"

apply_table() {
    local table="$1"
    local id_col="$2"
    local account_expr="$3"
    local date_col="$4"

    $PSQL <<EOF
SET app.current_realm = 'owner';
${MAILBOX_MAP}
SELECT home_ai.realm_override('$table', t.$id_col, m.expected,
                              'r5-backfill-' || to_char(now(),'YYYY-MM-DD'))
  FROM $table t
  JOIN mailbox_realm m ON m.account = $account_expr
 WHERE t.$date_col > now() - interval '30 days'
   AND t.realm IS DISTINCT FROM m.expected;
EOF
}

apply_table "emails"                "id"  "t.account"              "created_at"
apply_table "vendor_invoice_inbox"  "id"  "t.account"              "received_at"
# events partitions: id is non-unique without created_at; handle via raw UPDATE
# inside the override function — only do the simple cases here.

echo "── apply complete; re-running audit ──"
exec "$0" --audit-only
