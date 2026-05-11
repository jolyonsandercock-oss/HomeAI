#!/bin/bash
# Gate B verification — runs all 8 checks against the most recent
# gmail_message_id (or one passed as $1). Use after a real email has been
# fetched, classified, and emit-completed by gmail-ingest-v1.
set -euo pipefail

GMSG_ID="${1:-}"

if [[ -z "$GMSG_ID" ]]; then
  GMSG_ID=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc "
    SELECT gmail_message_id FROM emails ORDER BY id DESC LIMIT 1;" | tr -d ' \n')
  echo "Using most recent gmail_message_id: $GMSG_ID"
fi

if [[ -z "$GMSG_ID" ]]; then
  echo "✗ no email found — Gmail poller hasn't run yet?"
  exit 1
fi

# Get trace_id from the events row whose payload references this gmail_message_id
# (emails.trace_id may be null — the workflow doesn't backfill from events).
TRACE=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc "
  SELECT trace_id FROM events
   WHERE event_type='email.received'
     AND payload->>'gmail_message_id' = '$GMSG_ID'
   ORDER BY id DESC LIMIT 1;" | tr -d ' \n')
echo "Trace ID: $TRACE"
echo

run() {
  local label="$1"; local sql="$2"; local expect="$3"
  local got
  got=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc "$sql" | tr -d '[:space:]')
  if [[ "$got" == "$expect" ]]; then
    printf '  [PASS] %s (got %s)\n' "$label" "$got"
  else
    printf '  [FAIL] %s — expected %s, got %s\n' "$label" "$expect" "$got"
  fi
}

echo "════════ GATE B (real email: $GMSG_ID) ════════"

run "Q1 email.received in events_2026_05" \
  "SELECT count(*) FROM events_2026_05 WHERE event_type='email.received' AND trace_id='$TRACE';" \
  "1"

run "Q2 emails.classification populated" \
  "SELECT count(*) FROM emails WHERE gmail_message_id='$GMSG_ID' AND classification IS NOT NULL;" \
  "1"

run "Q3 email.classified event emitted" \
  "SELECT count(*) FROM events WHERE event_type='email.classified' AND trace_id='$TRACE';" \
  "1"

run "Q4 events_overflow stays empty" \
  "SELECT count(*) FROM events_overflow;" \
  "0"

run "Q5 HMAC signature non-placeholder on this trace" \
  "SELECT count(*) FROM events WHERE trace_id='$TRACE' AND (payload_signature IS NULL OR payload_signature='' OR payload_signature='init_placeholder');" \
  "0"

run "Q6 audit_log entry with pipeline=email_pipeline ai_worker=email_classifier" \
  "SELECT count(*) FROM audit_log WHERE trace_id='$TRACE' AND pipeline='email_pipeline' AND ai_worker='email_classifier';" \
  "1"

# Q7 deferred — Metabase card UI step, can't verify from CLI

run "Q8 no dead_letter for this trace" \
  "SELECT count(*) FROM dead_letter WHERE event_id IN (SELECT id FROM events WHERE trace_id='$TRACE');" \
  "0"

echo
echo "Q7 (Metabase email review queue UI card) — deferred to user UI step."
echo
echo "Email metadata for this run:"
docker exec homeai-postgres psql -U postgres -d homeai -c "
SELECT id, from_address, subject, classification, confidence_score, entity_id, processed
  FROM emails WHERE gmail_message_id='$GMSG_ID';"
