# Overnight plan — 12-hour window, three sprints

Goal: ship as much real value as possible while Jo is away, without crossing
any of the boundaries (no self-modify settings.json, no Vault restart, no
sudo, no Vault token reads, no destructive DB ops, no destructive prod ops).

Pacing: 12-hour budget. Three sprints, ~3 hours each. ~3 hours buffer for
unexpected blockers and selftests.

Heartbeat continues — Jo gets a Telegram ping every 15 minutes regardless.

## Why these three (not others)

**U15 (Master Router Intelligence)** — direct continuation of the U11 dead-
letter incident. Master Router declares "max retries exceeded" without
checking whether the downstream effect (the emails row, the invoice row,
etc.) already exists. We saw 8 false dead letters this session — they all
had downstream data. Fix the root cause, then auto-clean the historical
backlog. Highest ROI per hour.

**U16 (Caterbook Attachment Pipeline)** — closes the medium-severity P6
debt. Caterbook's daily-report email format doesn't match the fixture
parser, BUT the per-day "Arrivals and Departures" emails carry a PDF that
DOES contain useful occupancy data. We have markitdown running already.
Wire it up. Real accommodation data starts flowing.

**U17 (Synthetic Test Harness + Digest Polish)** — defensive infra. After
the classifier bug + dead-letter false positives, a nightly synthetic-
email regression suite catches future regressions. Plus tidy up the
daily-digest formatting using new data sources. Lower-feature-velocity
but high-confidence-buy.

## What I am explicitly NOT doing autonomously
- Vault auto-unseal cutover (script ready, sudo-gated)
- NAS mount (script ready, sudo-gated)
- Hooks install (script ready, agent-self-modify gated)
- Authelia bootstrap (script ready, sudo-gated)
- Real Caterbook/EPOS daily-report formats (need user-forwarded sample)
- bank-csv-import deep-work (existing workflow not yet audited; out of
  scope for an overnight)
- LoRA fine-tune, SearXNG, Storyblok, Calendar pipelines (Phase 3 — would
  need user direction on priority)

---

## Sprint U15 — Master Router Intelligence

**Problem:** `recover_stale_leases()` declares an event "dead-lettered" when
retries exceed 3, regardless of whether downstream side-effects landed. This
session: 8 false-positive dead letters — all had `emails` rows.

### Stages
- **A.** V24 migration: `recover_stale_leases_v2()` function. Same retry
  semantics, but before dead-lettering, verifies downstream:
  - `email.received` → row exists in `emails` keyed by `gmail_message_id`
  - `invoice.detected` → row exists in `invoices` keyed by `event_id`
  - `accommodation.report.detected` → row in `accommodation_daily` keyed by `email_id`
  - `epos.report.detected` → row in `epos_daily` keyed by `email_id`
  - default → fall through to dead-letter (unknown event types)
  When downstream is present, mark event `processed` (not dead-letter) and
  emit a `recovered_post_lease` audit log row.
- **B.** Master-router workflow swap to call v2. Keep v1 callable for rollback.
- **C.** New workflow `dead-letter-sweeper-v1`: hourly. Scans unresolved
  dead letters whose event_type has known downstream verification — if
  downstream is now present, auto-resolve with note. Quiet healing of
  historical false positives.
- **D.** Regression test SQL (`u15-regression.sql`): synthesise a stuck
  event with retry_count=3 + a downstream emails row, run v2, assert
  status='processed' and dead_letter empty.
- **E.** `u15-selftest.sh`: function exists, sweeper active, regression passes.
- **F.** Telegram close + memory note.

**Risk:** the function runs SECURITY DEFINER on a hot path. Test in a
transaction first — never let the migration commit on first run.

---

## Sprint U16 — Caterbook Attachment Pipeline

**Problem:** P6 Caterbook pipeline expects a "Daily Report" plaintext email
that doesn't exist in production traffic. The emails Caterbook actually
sends have a PDF attached ("see attached PDF detailing your N arrivals…").
Nothing in the system extracts these.

### Stages
- **A.** Extend `homeai-google-fetch` with `/fetch-attachment` — given
  gmail message id + attachment id, returns base64 bytes. Service already
  authenticated with Gmail API.
- **B.** Extend gmail-ingest-v1 classifier to detect attachments in the
  Gmail message metadata, write rows to `email_attachments` table
  (already exists), emit `attachment.detected` events for each.
- **C.** New workflow `attachment-extract-v1`: triggered on
  `attachment.detected` events. If mime_type is PDF, fetch bytes, send to
  markitdown:8004 for text extraction, store result in
  `email_attachments.extracted_text`.
- **D.** V25 migration: `accommodation_bookings` table — id, entity_id,
  guest_name, source, checkin, checkout, room_type, gross_amount, email_id,
  source_event_id, raw_text, RLS, UNIQUE on (entity_id, source, source_id).
- **E.** New workflow `caterbook-arrivals-v1`: parses extracted_text from
  Caterbook arrivals/departures PDFs → upserts `accommodation_daily` row
  with rooms_occupied + total_rooms.
- **F.** New workflow `caterbook-bookings-v1`: parses "New Reservation"
  email body (which is structured) → inserts into `accommodation_bookings`.
  Handles "Cancelled Reservation" too.
- **G.** Backfill on existing 6 Caterbook emails — exercise the parsers
  end-to-end, validate inserts.
- **H.** `u16-selftest.sh` — table exists, workflows active, real rows
  present after backfill.

**Risk:** Gmail attachment fetch needs the right scope (already granted in
U9). PDF parsing may need iteration — markitdown isn't perfect on all
layouts. If the PDF parse is too fragile, fall back to body-text-only
parsing for "New Reservation" / "Cancelled Reservation" emails (which
ARE structured plain text).

---

## Sprint U17 — Synthetic Test Harness + Digest Polish

**Problem:** No automated regression coverage. Future prompt changes,
classifier tweaks, or schema migrations could re-introduce the invoice
false-positive bug or others. Plus daily-digest formatting could use the
new data sources (epos, accommodation, dead-letter health).

### Stages
- **A.** New test harness `/home_ai/.claude/scripts/synthetic-email-test-suite.sh`
  builds on existing `synthetic-email-test.sh`. Test cases:
    1. Real invoice (Quaffle Wine Co, line items + total + due date) → expect category=invoice → invoices row created
    2. Amazon "Payment Declined" → expect category=action-required, NO invoice row (regression on U14)
    3. Stripe receipt → expect category=fyi, no invoice row
    4. School medical (head teacher to parent re: medication) → category=school-medical, child-event row
    5. Caterbook arrivals/departures (with mock PDF) → category=report-attachment, accommodation_daily row
    6. ICRTouch Z-report → category=report-attachment, epos_daily row
    7. Junk (Nigerian prince) → category=junk, no event emitted downstream
- **B.** Inject each via the existing event-emitter path (synthetic
  `email.received` events with HMAC-signed payloads — pattern from
  existing scripts/synthetic-email-test.sh).
- **C.** Wait for pipeline completion. Assert downstream tables look right.
- **D.** Cleanup: remove the synthetic rows so they don't pollute prod.
  (use a `synthetic=true` flag on emails to make this surgical)
- **E.** Add cron: `30 2 * * *` (between dreaming 02:00 and backup 03:00).
  On any failure, Telegram alert with details.
- **F.** Daily digest fixes:
    - Currently fires only at 05:00 / 22:00 UTC ("morning brief / nightly
      close") — confirmed correct, no bug. But the format misses dead-letter
      summary, EPOS revenue, accommodation occupancy.
    - Add: today's epos_daily total, today's accommodation occupancy_pct,
      open-and-aged dead letters, top 3 unresolved invoices needing review.
- **G.** `u17-selftest.sh` — synthetic suite passes, cron installed,
  digest format includes new fields.

**Risk:** Synthesising an email that flows through the live classifier
costs a few seconds of Ollama compute per case. 7 cases × few seconds =
~30s. Acceptable. Failure mode: synthetic rows leak into prod metrics if
cleanup fails — `synthetic=true` flag mitigates.

---

## After-action

End-of-window Telegram message summarises:
- Which sprints landed
- Selftest scores
- Any blockers I had to defer
- What's queued for Jo's morning review (if anything)

Memory written for: U15, U16, U17 closes; classifier prompt fingerprint;
caterbook attachment field map; synthetic test schedule.

---

## Stretch (only if time allows after all 3 selftests pass)
- Resolve the 1 remaining unresolved historical dead letter (event 528 —
  Amazon payment-declined invoice.detected). Now that the classifier won't
  re-emit those, this row is just legacy noise.
- Add a /pause and /resume command to telegram-bot that flips
  static_context.system.state — currently advertised in /help but not yet
  wired.
- Run the image-audit workflow once manually to verify Docker Hub queries
  work (catches issues before the first scheduled fire on June 1st).
