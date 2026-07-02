#!/bin/bash
# invoice-backlog-drain.sh — one-off recovery of the ~1,944 invoices stuck in
# status='new' with extraction_method='no_pdf' since the late-May cron outage.
#
# STAGED FOR THE 48GB GPU SWAP — do NOT run on the 3060. Re-extracting ~1,900
# invoices runs the ladder (qwen→Haiku→Sonnet) + vision OCR for image-only PDFs;
# on the 12GB card the vision model spills to CPU (heat) and it's real API spend.
# On the 48GB card the local tiers absorb far more, cheaper and cooler.
#
# ROOT CAUSE (2026-06-15 diagnosis): u125-pdf-attachment-fetch was dropped from
# cron ~2026-05-30 (same churn that killed the data-lane-router + dojo path).
# Invoices then arrived with no PDF → u35 stamped extraction_method='no_pdf' and
# left status='new'. That stamp EXCLUDES them from u35's candidate query forever
# (it requires extraction_method IS NULL). u125 also does NOT clear the stamp when
# it later fetches a PDF — so step 1 below (the reset) is mandatory, not optional.
#
# SEQUENCE: (1) reset the recoverable 'no_pdf' stamp → NULL, (2) batch u125 to
# fetch the PDFs, (3) batch u35 to extract — paced with sleeps to respect the
# £/day API budget. Idempotent and re-runnable; safe to stop/resume.
#
# PRE-REQ: re-add the routine cron first so forward intake stays healthy:
#   ( crontab -l; echo '5 * * * * bash /home_ai/scripts/u125-pdf-attachment-fetch.sh 200 >> /home_ai/logs/u125-pdf-fetch.log 2>&1' ) | crontab -
#
# DRY RUN by default. Usage:
#   bash scripts/invoice-backlog-drain.sh                 # dry run (counts only)
#   bash scripts/invoice-backlog-drain.sh --execute [BATCH] [SLEEP_S] [MAX_BATCHES]
set -euo pipefail
EXECUTE=0; [ "${1:-}" = "--execute" ] && EXECUTE=1
BATCH="${2:-200}"
SLEEP="${3:-120}"        # seconds between batches — budget pacing
MAX_BATCHES="${4:-20}"   # safety cap per invocation (200*20 = 4000 capacity)
LOG=/home_ai/logs/invoice-backlog-drain.log
# tail -1: skip the "SET" echo line so we return only the query result
Q() { docker exec homeai-postgres psql -U postgres -d homeai -tAc "SET app.current_entity='all'; $1" 2>/dev/null | tail -1 | tr -d '[:space:]'; }

stuck=$(Q "SELECT count(*) FROM vendor_invoice_inbox WHERE status='new' AND extraction_method='no_pdf' AND source_email_id ~ '^[0-9a-f]+\$';")
vision=$(Q "SELECT count(*) FROM vendor_invoice_inbox WHERE status='new' AND extraction_method='haiku_no_text';")
echo "$(date -Is) backlog-drain start: no_pdf-recoverable=$stuck  image-only(vision)=$vision  execute=$EXECUTE" | tee -a "$LOG"

if [ "$EXECUTE" -ne 1 ]; then
  cat <<EOF
DRY RUN — nothing changed. On --execute this will:
  1. reset extraction_method->NULL on the $stuck recoverable 'no_pdf' rows (hex Gmail ids only;
     leaves the genuinely no-pdf-attached / non-pdf-attached rows alone).
  2. run u125-pdf-attachment-fetch in batches of $BATCH, ${SLEEP}s apart, up to $MAX_BATCHES batches.
  3. run u35-invoice-pdf-extract the same way.
The $vision image-only rows need the vision path (u281) — verify it's accepting on the new card
(it logged accepted=0 rejected=29 on the 3060) before resetting those separately.
Re-run with:  bash $0 --execute
EOF
  exit 0
fi

echo "$(date -Is) STEP 1: reset 'no_pdf' stamp so u35 will re-attempt after PDF fetch" | tee -a "$LOG"
docker exec homeai-postgres psql -U postgres -d homeai -tAc \
  "SET app.current_entity='all';
   UPDATE vendor_invoice_inbox SET extraction_method=NULL
    WHERE status='new' AND extraction_method='no_pdf' AND source_email_id ~ '^[0-9a-f]+\$';" >>"$LOG" 2>&1

echo "$(date -Is) STEP 2: fetch PDFs in paced batches" | tee -a "$LOG"
for i in $(seq 1 "$MAX_BATCHES"); do
  remain=$(Q "SELECT count(*) FROM vendor_invoice_inbox WHERE status='new' AND (NOT has_pdf OR pdf_local_path IS NULL) AND source_email_id ~ '^[0-9a-f]+\$';")
  [ "${remain:-0}" -eq 0 ] && { echo "$(date -Is) PDF-fetch: drained" | tee -a "$LOG"; break; }
  echo "$(date -Is) PDF-fetch batch $i ($remain remaining)" | tee -a "$LOG"
  bash /home_ai/scripts/u125-pdf-attachment-fetch.sh "$BATCH" >>"$LOG" 2>&1 || echo "  (u125 batch returned $?)" | tee -a "$LOG"
  sleep "$SLEEP"
done

echo "$(date -Is) STEP 3: extract in paced batches" | tee -a "$LOG"
for i in $(seq 1 "$MAX_BATCHES"); do
  remain=$(Q "SELECT count(*) FROM vendor_invoice_inbox WHERE status='new' AND extraction_method IS NULL AND has_pdf AND source_email_id ~ '^[0-9a-f]+\$';")
  [ "${remain:-0}" -eq 0 ] && { echo "$(date -Is) extract: drained" | tee -a "$LOG"; break; }
  echo "$(date -Is) extract batch $i ($remain remaining)" | tee -a "$LOG"
  bash /home_ai/scripts/u35-invoice-pdf-extract.sh "$BATCH" >>"$LOG" 2>&1 || echo "  (u35 batch returned $?)" | tee -a "$LOG"
  sleep "$SLEEP"
done

echo "$(date -Is) backlog-drain run complete. Remaining new (any method): $(Q "SELECT count(*) FROM vendor_invoice_inbox WHERE status='new';")" | tee -a "$LOG"
