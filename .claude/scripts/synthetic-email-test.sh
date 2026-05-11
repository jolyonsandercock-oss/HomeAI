#!/bin/bash
# End-to-end Gate B mechanics test using synthetic data.
# Bypasses Gmail OAuth — injects a fake email + email.received event,
# watches Master Router → Email Pipeline → llm-router → emails update +
# email.classified event + audit_log.
#
# Cleans up after itself unless KEEP=1.
set -euo pipefail

GMSG_ID="synthetic_$(date +%s)"
TRACE_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
echo "Test trace_id: $TRACE_ID"
echo "Test gmail_message_id: $GMSG_ID"

# ────────────────────────────────────────────────────────
# Inject fixtures
# ────────────────────────────────────────────────────────
docker exec -i homeai-postgres psql -U postgres -d homeai >/dev/null <<EOF
SET LOCAL app.current_entity = 'all';

INSERT INTO emails
  (gmail_message_id, account, from_address, from_name, subject,
   body_text, body_text_safe, received_at, trace_id)
VALUES
  ('$GMSG_ID',
   'test-account',
   'no-reply@touchoffice.co.uk',
   'TouchOffice EPoS',
   'Daily Z-report — Olde Malthouse — 2026-05-08',
   'Gross sales: £1,234.56\nCash: £400\nCard: £834.56\nCovers: 42',
   'Gross sales: GBP 1234.56. Cash: 400. Card: 834.56. Covers: 42.',
   NOW(),
   '$TRACE_ID');

INSERT INTO events
  (event_type, source, payload, payload_signature, status, trace_id,
   idempotency_key, pipeline_version)
VALUES
  ('email.received',
   'gmail_ingest',
   jsonb_build_object('gmail_message_id', '$GMSG_ID', 'received_at', NOW()::text),
   'synthetic_test_signature_$GMSG_ID',
   'pending',
   '$TRACE_ID'::uuid,
   'synthetic_$GMSG_ID',
   '1.0');
EOF

EVENT_ID=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc "
SELECT id FROM events WHERE idempotency_key = 'synthetic_$GMSG_ID';")
echo "Injected event id: $EVENT_ID"

# ────────────────────────────────────────────────────────
# Wait for routing + processing (Master Router cron is 30s)
# ────────────────────────────────────────────────────────
echo
echo "Waiting up to 90s for chain to complete..."
for i in $(seq 1 30); do
  STATUS=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc "
    SELECT status FROM events WHERE id = $EVENT_ID;")
  CLASSIFIED=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc "
    SELECT count(*) FROM events
     WHERE event_type='email.classified' AND parent_event_id = $EVENT_ID;")
  echo "  t=$((i*3))s parent_status=$STATUS classified_emitted=$CLASSIFIED"
  if [ "$STATUS" = "done" ] && [ "$CLASSIFIED" = "1" ]; then
    echo "  → chain complete"
    break
  fi
  sleep 3
done

# ────────────────────────────────────────────────────────
# Gate B checks (Q1–6, 8 — Q7 needs Metabase card, deferred)
# ────────────────────────────────────────────────────────
echo
echo "════════ GATE B RESULTS ════════"

run() {
  local label="$1"; local sql="$2"; local expect="$3"
  local got
  got=$(docker exec homeai-postgres psql -U postgres -d homeai -tAc "$sql" | tr -d '[:space:]')
  if [ "$got" = "$expect" ]; then
    printf '  [PASS] %s (got %s)\n' "$label" "$got"
  else
    printf '  [FAIL] %s — expected %s, got %s\n' "$label" "$expect" "$got"
  fi
}

run "Q1 email.received in events_2026_05 with this trace_id" \
  "SELECT count(*) FROM events_2026_05 WHERE event_type='email.received' AND trace_id='$TRACE_ID';" \
  "1"

run "Q2 emails.classification populated" \
  "SELECT count(*) FROM emails WHERE gmail_message_id='$GMSG_ID' AND classification IS NOT NULL;" \
  "1"

run "Q3 email.classified event emitted" \
  "SELECT count(*) FROM events WHERE event_type='email.classified' AND parent_event_id=$EVENT_ID;" \
  "1"

run "Q4 events_overflow stays empty" \
  "SELECT count(*) FROM events_overflow;" \
  "0"

run "Q5 HMAC signature present on this trace's events" \
  "SELECT count(*) FROM events WHERE trace_id='$TRACE_ID' AND (payload_signature IS NULL OR payload_signature='');" \
  "0"

run "Q6 audit_log row with pipeline='email_pipeline' ai_worker='email_classifier'" \
  "SELECT count(*) FROM audit_log WHERE trace_id='$TRACE_ID' AND pipeline='email_pipeline' AND ai_worker='email_classifier';" \
  "1"

run "Q8 no dead letters for this trace" \
  "SELECT count(*) FROM dead_letter WHERE event_id IN (SELECT id FROM events WHERE trace_id='$TRACE_ID');" \
  "0"

echo
echo "Q7 (Metabase email review queue) — deferred to sprint item 2."

# ────────────────────────────────────────────────────────
# Cleanup
# ────────────────────────────────────────────────────────
if [ "${KEEP:-0}" = "1" ]; then
  echo
  echo "KEEP=1 → leaving synthetic data in place (trace_id=$TRACE_ID)"
else
  echo
  echo "Cleaning up synthetic data..."
  docker exec -i homeai-postgres psql -U postgres -d homeai >/dev/null <<EOF
SET LOCAL app.current_entity = 'all';
DELETE FROM audit_log WHERE trace_id='$TRACE_ID';
DELETE FROM events WHERE trace_id='$TRACE_ID';
DELETE FROM emails WHERE gmail_message_id='$GMSG_ID';
EOF
  echo "  done."
fi
