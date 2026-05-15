# U47d — Stop the Bleed

**Prereqs**: none — this is regression + onset triage; runs ahead of U47c/U48.

**Remote vs in-person**: ~95/5 remote. Only Authelia + Vault auto-unseal sudo bits need in-person; those stay deferred to U48 anyway.

**Why this sprint exists**: two issues found 2026-05-14 during session start that aren't visible from the dashboards:

1. **`document.received` flood** — same `gmail_message_id` re-emitting on every poll cycle. 4,969 events in last 24h vs 166 actual emails (≈30×). Top offenders: 36 re-emits per message in last hour. The U43 fix added per-attachment emission but no idempotency key — every Gmail poll cycle re-emits all attachments of all "new" messages.
2. **Parser onset 2026-05-13T01:30** — caterbook (1,424 unparseables/24h), caterbook-bookings (96), EPOS (96) all broke simultaneously. Dreaming Workflow H flagged it on both 2026-05-13 and 2026-05-14 (heuristics ids 3, 4, 5, 6, 8). Nothing reviewed/actioned. Daily numbers from these pipelines may already be wrong.

Plus three smaller follow-ons that block downstream work and are cheap to clear.

## Tracks

### Track 1 — Idempotency on `document.received` emission (~1.5h, remote)

**Problem**: `/home_ai/services/google-fetch/main.py` `/poll-and-emit` emits `document.received` per attachment, but doesn't track which `(gmail_message_id, attachment_id)` pairs have already been emitted. Every 1-min poll cycle re-emits everything it currently sees as "new".

**Approach**:
1. Add a small `document_emit_log` table (V58):
   ```sql
   CREATE TABLE document_emit_log (
     gmail_message_id TEXT NOT NULL,
     attachment_id    TEXT NOT NULL,
     account          TEXT NOT NULL,
     emitted_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
     PRIMARY KEY (gmail_message_id, attachment_id)
   );
   CREATE INDEX idx_del_emitted_at ON document_emit_log(emitted_at DESC);
   ```
2. In `/poll-and-emit`, before emitting `document.received` for each attachment, `INSERT ... ON CONFLICT DO NOTHING`; if no row was inserted, skip the emit.
3. Backfill cleanup — collapse the existing 4,969 dup events:
   ```sql
   DELETE FROM events e
     USING events e2
    WHERE e.event_type='document.received'
      AND e2.event_type='document.received'
      AND e.payload->>'gmail_message_id' = e2.payload->>'gmail_message_id'
      AND e.payload->>'attachment_id'    = e2.payload->>'attachment_id'
      AND e.id > e2.id;
   ```
   (Keep the earliest row per `(message,attachment)` pair.) Backfill `document_emit_log` from what remains.
4. Verify on next poll cycle: re-poll count of `document.received` events in trailing 5 min should match number of newly-arrived attachments only.

**Acceptance**:
- After deploy, `SELECT COUNT(*) FROM events WHERE event_type='document.received' AND created_at > NOW() - INTERVAL '1 hour'` ≤ count of new emails with attachments in same window.
- No `(gmail_message_id, attachment_id)` pair appears more than once in `events` going forward.
- Cleanup deletes ~4,800 rows; dashboard event counters stop the runaway.

### Track 2 — Diagnose the 2026-05-13T01:30 parser onset (~2h, remote)

Three pipelines (P5 EPOS, P6 Caterbook, P6b Caterbook-bookings) broke at the same minute. Either a shared upstream change or a shared ingestion regression on our side. The Dreaming proposals (id 3/4/5/6/8) all hypothesise an unknown format.

**Diagnostic steps** (in this order — stop when root cause is found):
1. Pull the raw inputs from 2026-05-13 01:25–01:35 for each pipeline:
   - Caterbook: latest `caterbook_email_reports` row before the onset vs after — diff the raw HTML/PDF.
   - EPOS: latest `touchoffice_scrapes` HTML before vs after.
   - Compare the parser inputs visually + checksum.
2. Check the git/disk timestamp of `services/playwright/main.py` and any caterbook parser — was a deploy mid-air at 01:30? (`stat -c '%y' /home_ai/services/**/main.py`.)
3. Check Tanda/Caterbook/TouchOffice login state — expired credential would show as different "unparseable" content (login page returned instead of data).
4. If it really is an upstream format change, implement the system-wide proposal (heuristic id 8): add a pre-parse format sniff that routes unknown input to `qwen2.5:7b` with an "extract whatever fields you can find" fallback.

**Acceptance**:
- Root cause documented in `/home_ai/notes/` (one-pager) and the matching `dreaming_heuristics` row marked `reviewed_by='claude-u47d'` with `status='accepted'`/`rejected'`.
- For the day-of-the-onset (2026-05-13), backfill any caterbook + EPOS rows that ended up empty if root cause is fixable.
- New parser failures over the next 24h drop to <5% (current: 100% for caterbook).

### Track 3 — `u47-tanda-timesheets-sync.sh` (~30m, remote)

`forecast_vs_actual` view exists but `workforce_timesheets` table is empty because we only call `/api/v2/shifts`. Mirror the existing `u29-workforce-sync` script:
- New script `/home_ai/scripts/u47-tanda-timesheets-sync.sh`
- Endpoint: Tanda `/api/v2/timesheets?date_from=<n-1>&date_to=<today>`
- UPSERT into `workforce_timesheets` on `(tanda_timesheet_id)`
- Cron daily 02:20 (5 min after the shifts sync)

**Acceptance**:
- `SELECT COUNT(*) FROM workforce_timesheets` non-zero, growing daily.
- `/api/workforce/forecast_vs_actual` returns rows for the last completed pay period.

### Track 4 — Cafe vendor list capture via Telegram prompt (~45m, remote)

178 invoices currently classified `shared`, **0 cafe** because Jo hasn't supplied cafe vendor names. Don't keep waiting passively — push a single Telegram prompt with the top-25 unclassified vendor names and let Jo reply with cafe-only names.

**Approach**:
1. One-shot script `/home_ai/scripts/u47d-cafe-vendor-prompt.sh`:
   ```sql
   SELECT vendor_name, COUNT(*)
     FROM vendor_invoice_inbox
    WHERE site='shared'
    GROUP BY 1
    ORDER BY 2 DESC LIMIT 25;
   ```
   Telegram message: numbered list, "Reply with comma-separated numbers that are cafe-only vendors, e.g. `2,7,13`."
2. New `bot_instructions.intent='cafe_vendor_list'` handler that parses the reply and updates `vendor_category_rules` with `site='cafe'` for the named vendors.
3. Trigger a one-off re-classify pass: `UPDATE vendor_invoice_inbox SET site = derive_site(...) WHERE ...` so historical rows recategorise.

**Acceptance**:
- Telegram prompt sent.
- After Jo's reply, `SELECT site, COUNT(*) FROM vendor_invoice_inbox GROUP BY 1` shows non-zero `cafe` count.

### Track 5 — Surface uncertain classifications in the daily digest (~30m, remote)

102 rows in `v_classifier_uncertain`, `bot_feedback` table empty — the U47a Teach-AI modal exists but isn't being used because Jo never sees the prompt. Push it into the 21:00 digest.

**Approach**:
- Extend `u29-daily-digest.sh` to add a "Top 5 uncertain classifications today" section: vendor + subject + current category + link to invoice page (anchored to the Feedback modal).
- Cap to 5/day so digest doesn't bloat.

**Acceptance**:
- Tomorrow's digest contains the section.
- After one week, `bot_feedback` has ≥3 rows (assuming Jo engages).

## Out of scope

- Authelia forward_auth (still needs `tailscale cert` FQDN — keep in U48).
- Vault auto-unseal sudo run (Jo to bash `u35-vault-autounseal-bootstrap.sh` separately).
- U38.5 n8n Anthropic node migrations (keep as background work).
- P3 Xero (vendor-blocked).
- Real-time bot replies (keep for later).
- SDD migration + Wix hosting (U48).

## Stop conditions

- If Track 2 reveals the parser onset was a one-off (e.g. a single corrupted scrape) and current data is clean, mark it observed and skip the LLM-fallback work — don't over-engineer.
- If Track 1 cleanup hits row-lock contention, do the DELETE in batches of 1,000 with a `LIMIT` + loop.
