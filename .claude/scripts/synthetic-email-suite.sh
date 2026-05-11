#!/bin/bash
# /home_ai/.claude/scripts/synthetic-email-suite.sh
#
# U17 — End-to-end regression suite for the email classifier + pipelines.
#
# Builds on synthetic-email-test.sh. Inserts a list of synthetic emails with
# known expected classifications, watches the live pipelines process them,
# asserts each lands the right category + the right downstream table.
#
# Trace IDs are unique per run so cleanup is surgical. Failures Telegram-alert.
#
# Usage:
#   bash /home_ai/.claude/scripts/synthetic-email-suite.sh
#
# Cron line (installed at the end of this file by the install routine):
#   30 2 * * * /home_ai/.claude/scripts/synthetic-email-suite.sh \
#                >> /home_ai/backups/synthetic-suite.log 2>&1

set -uo pipefail

PSQL() { docker exec -i homeai-postgres psql -U postgres -d homeai "$@"; }
sql()  { docker exec    homeai-postgres psql -U postgres -d homeai -tAc "$@"; }

RUN_ID=$(date -u +%Y%m%d-%H%M%S)
TRACE_BASE="synthetic-suite-$RUN_ID"
PASS=0; FAIL=0
FAIL_DETAILS=""

# Each fixture: name | from | subject | body | expected_category | downstream_check_sql
# downstream_check_sql is a SELECT returning 1 if the test passes, else 0.
declare -a FIXTURES=(
  # 1. Real invoice — should land as 'invoice' and create an invoices row
  "real-invoice|accounts@quaffle-wines.example.com|Invoice INV-2026-014 — Quaffle Wines|Hi Jo, Please find your monthly wine order invoice INV-2026-014. Amount due £1,247.83. VAT 20% included (£207.97). Due date: 30/05/2026. Please pay by BACS to Sort 12-34-56 Acc 12345678. Thanks, Quaffle Wines.|invoice"

  # 2. Amazon Payment Declined — REGRESSION on U14: must NOT classify as invoice
  "payment-declined-regression|no-reply@amazon.co.uk|Payment Declined for 202-0557688-8176333|Your card payment was declined. Order: 202-0557688-8176333. Total: £24.99. Please update your payment information to avoid order cancellation.|action-required"

  # 3. Stripe payment receipt — should be fyi (not invoice)
  "stripe-receipt|receipts@stripe.com|Receipt for your payment to Caterbook|Thanks for your payment of £49.00 to Caterbook on 2026-05-09. Receipt number: ch_3QbX...|fyi"

  # 4. School medical — head teacher to parent re: medication
  "school-medical|head@stmaryskindergarten.example.com|Asthma inhaler reminder for Charlotte|Dear Mrs Sandercock, A reminder that Charlotte's blue inhaler is running low. Please send a replacement when convenient. Best regards, Mrs Smith.|school-medical"

  # 5. Junk — Nigerian prince classic
  "junk-nigerian|prince.bankole@gov.example.ng|Urgent business proposal — \$1,000,000|My dear friend, I am Prince Bankole and I have inherited \$1,000,000 from my late father. I require your bank details to transfer this fortune. You will receive 30%. Please reply with your account number.|junk"

  # 6. Generic action-required — login alert
  "login-alert|noreply@google.com|Security alert: new sign-in to your Google Account|A new device signed in to your Google Account jolyon.sandercock@gmail.com from London, UK. If this wasn't you, please review your account activity immediately.|action-required"
)

inject() {
  local fixture="$1"
  IFS='|' read -r name from subject body expected <<<"$fixture"
  local trace_id; trace_id=$(python3 -c "import uuid; print(uuid.uuid4())")
  local gmsg="$TRACE_BASE-$name"
  local expected_norm; expected_norm=$(echo "$expected" | tr -d '[:space:]')

  # Don't pre-insert emails — let the classifier do it. Same flow as real emails.
  PSQL >/dev/null <<EOF
SET row_security = off;

INSERT INTO events (event_type, source, entity_id, payload, payload_signature, status, trace_id, idempotency_key, pipeline_version)
VALUES ('email.received', 'synthetic_suite', 3,
        jsonb_build_object(
          'gmail_message_id', '$gmsg',
          'account',         'bot',
          'from_address',    '$from',
          'from_name',       '',
          'subject',         \$\$$subject\$\$,
          'body_text',       \$\$$body\$\$,
          'body_text_safe',  \$\$$body\$\$,
          'received_at',     NOW()::text,
          'has_attachment',  false,
          'synthetic',       true),
        'synthetic-sig-$gmsg',
        'pending',
        '$trace_id'::uuid,
        '$gmsg',
        'synthetic_suite:1.0');
EOF

  printf '%s\t%s\t%s\t%s\n' "$name" "$trace_id" "$gmsg" "$expected_norm"
}

echo "=== Synthetic Email Suite — $RUN_ID ==="
echo
echo "Inject ${#FIXTURES[@]} fixtures..."

INJECTED=()
for f in "${FIXTURES[@]}"; do
  if line=$(inject "$f"); then
    INJECTED+=("$line")
    name=$(echo "$line" | cut -f1)
    echo "  injected: $name"
  fi
done

echo
echo "Waiting up to 180s for classifier (Ollama + master-router cron is 30s)..."

# Poll: every fixture's emails row should have classification populated
DONE_COUNT=0
for i in $(seq 1 60); do
  DONE_COUNT=0
  for line in "${INJECTED[@]}"; do
    gmsg=$(echo "$line" | cut -f3)
    cls=$(sql "SELECT classification FROM emails WHERE gmail_message_id = '$gmsg';" 2>/dev/null)
    if [[ -n "$cls" && "$cls" != "" ]]; then
      DONE_COUNT=$((DONE_COUNT+1))
    fi
  done
  echo "  t=$((i*3))s — classified $DONE_COUNT / ${#INJECTED[@]}"
  if [[ "$DONE_COUNT" -ge "${#INJECTED[@]}" ]]; then break; fi
  sleep 3
done

echo

# Assertions
for line in "${INJECTED[@]}"; do
  name=$(echo "$line" | cut -f1)
  trace_id=$(echo "$line" | cut -f2)
  gmsg=$(echo "$line" | cut -f3)
  expected=$(echo "$line" | cut -f4)

  actual=$(sql "SELECT classification FROM emails WHERE gmail_message_id = '$gmsg';" 2>/dev/null | tr -d '[:space:]')
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS+1))
    echo "  PASS  $name → $actual"
  else
    FAIL=$((FAIL+1))
    detail="  FAIL  $name — expected=$expected actual=$actual"
    echo "$detail"
    FAIL_DETAILS="${FAIL_DETAILS}${detail}\\n"
  fi
done

# Regression-specific extra check on payment-declined: NO invoice row should exist
PAYMENT_DECLINED_TRACE=$(echo "${INJECTED[*]}" | tr ' ' '\n' | grep -i 'payment-declined-regression' | cut -f2)
if [[ -n "$PAYMENT_DECLINED_TRACE" ]]; then
  inv_count=$(sql "SELECT COUNT(*) FROM invoices WHERE trace_id = '$PAYMENT_DECLINED_TRACE'::uuid;" 2>/dev/null | tr -d '[:space:]')
  if [[ "$inv_count" == "0" ]]; then
    PASS=$((PASS+1))
    echo "  PASS  payment-declined-regression: no invoices row created"
  else
    FAIL=$((FAIL+1))
    echo "  FAIL  payment-declined-regression: $inv_count invoices row(s) created (expected 0)"
    FAIL_DETAILS="${FAIL_DETAILS}  FAIL payment-declined invoice leak: $inv_count rows\\n"
  fi
fi

echo
echo "════ RESULT: $PASS pass, $FAIL fail ════"

# Cleanup unless KEEP=1
if [[ "${KEEP:-0}" != "1" ]]; then
  echo
  echo "Cleanup..."
  for line in "${INJECTED[@]}"; do
    trace_id=$(echo "$line" | cut -f2)
    gmsg=$(echo "$line" | cut -f3)
    PSQL >/dev/null <<EOF
SET row_security = off;
-- Clean by gmail_message_id pattern catches child events the classifier emitted
-- with the same trace_id AND other downstream rows linked via event_id or payload.
WITH synth AS (
  SELECT id, trace_id FROM events
   WHERE trace_id = '$trace_id'::uuid OR payload->>'gmail_message_id' = '$gmsg'
)
DELETE FROM child_events WHERE source_email_id IN (SELECT id FROM emails WHERE gmail_message_id = '$gmsg');

WITH synth AS (
  SELECT id, trace_id FROM events
   WHERE trace_id = '$trace_id'::uuid OR payload->>'gmail_message_id' = '$gmsg'
)
DELETE FROM dead_letter WHERE event_id IN (SELECT id FROM synth);

DELETE FROM audit_log WHERE trace_id = '$trace_id'::uuid;
DELETE FROM invoices WHERE trace_id = '$trace_id'::uuid OR event_id IN (SELECT id FROM events WHERE payload->>'gmail_message_id' = '$gmsg');
DELETE FROM events WHERE trace_id = '$trace_id'::uuid OR payload->>'gmail_message_id' = '$gmsg';
DELETE FROM emails WHERE gmail_message_id = '$gmsg';
EOF
  done
  echo "  done."
fi

# On failure, fire a Telegram alert (only if running from cron)
if [[ "$FAIL" -gt 0 && "${SKIP_TELEGRAM:-0}" != "1" ]]; then
  bash /home_ai/.claude/scripts/notify-telegram.sh \
    "🔥 <b>Synthetic email suite — $FAIL fail / $PASS pass</b> ($RUN_ID)
$(echo -e "$FAIL_DETAILS" | head -c 500)" \
    >/dev/null 2>&1 || true
fi

[[ "$FAIL" -eq 0 ]]
