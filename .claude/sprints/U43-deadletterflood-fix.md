# U43 — Fix recurring DeadLetterFlood (invoice.detected without document.received)

**Why**: every 1-2 hours new `invoice.detected` events arrive without their sibling `document.received`, the Invoice Pipeline retries 3× and dead-letters, the DeadLetterFlood alert auto-pauses the system. Triaged twice in U38→U42 — that's two hours of ops attention per day on the same root cause. Highest-value remote-doable fix on the board.

**Constraint**: 100% remote-doable. No sudo, no infra changes. Risk is on n8n workflow patches.

## What's happening (diagnosis from U38/U42 triage)

- `invoice.detected` events are being emitted (likely by `gmail-ingest-v1` classifier as it processes emails)
- `document.received` events are NOT being emitted at the same rate (Gmail Poller `QMKzaCFrKBS4ewWm` is INACTIVE)
- Invoice Pipeline P2's `Validate Event` reads the invoice.detected event, then looks for attachment metadata via the sibling document.received — which isn't there
- Result: pipeline fails, retries 3×, lease expires, recover_stale_leases → dead_letter
- DeadLetterFlood alert auto-pauses `system.state` after >5 dead_letters in 15 min

## Track 1 — Investigation (45 min)

Before any patch, understand the asymmetry. State sync (3 commands) then:

| # | Question | Method |
|---|---|---|
| 1 | What does gmail-ingest-v1 emit per email? | Inspect `workflow_history` for the active gmail-ingest-v1 version. Find every `INSERT INTO events` node. List the event_type values they produce. |
| 2 | Why is `QMKzaCFrKBS4ewWm` Gmail Poller inactive? | `SELECT id, status, "startedAt", "stoppedAt" FROM execution_entity WHERE "workflowId"='QMKzaCFrKBS4ewWm' ORDER BY "startedAt" DESC LIMIT 10`. Look at error executions. |
| 3 | Where do `invoice.detected` events come from? | `SELECT pipeline_version, COUNT(*) FROM events WHERE event_type='invoice.detected' AND created_at > now() - interval '24 hours' GROUP BY 1` |
| 4 | Are document.received events EVER emitted now? | `SELECT created_at, payload->>'gmail_message_id' FROM events WHERE event_type='document.received' ORDER BY id DESC LIMIT 5` |
| 5 | Is there a separate workflow that emits document.received? | grep `workflow_entity` for any active workflow with `document.received` in code/SQL |

**Decision point after Track 1**: pick fix path A, B, or C below based on what you find.

## Track 2 — Fix (one of three paths; pick after investigation)

### Path A — Re-activate Gmail Poller (`QMKzaCFrKBS4ewWm`) [easiest]

If Track 1 shows the Poller was deactivated due to a fixable error (e.g. one-off Vault token expiry, transient API issue):

1. Inspect the last few error executions; identify and fix the underlying cause.
2. `UPDATE workflow_entity SET active = true WHERE id = 'QMKzaCFrKBS4ewWm'`
3. Restart n8n container to reload (per [[feedback_homeai]] — workflow caches).
4. Watch first 2-3 cycles for clean execution.

Risk: if it was deactivated for a non-transient reason, reactivating just re-triggers the same problem.

### Path B — Patch gmail-ingest-v1 to emit document.received itself [most robust]

Both `invoice.detected` AND `document.received` would come from the same workflow, atomically (same WHERE NOT EXISTS pattern, same transaction window).

1. Inspect `gmail-ingest-v1`'s active version in `workflow_history`. Find the email-processing section.
2. Add a new "INSERT document.received" node that fires AFTER the email is classified as invoice. Uses the same Vault signing key fetch + canonical-JSON HMAC + WHERE NOT EXISTS idempotency pattern as the other INSERTs in this workflow.
3. The payload: `{gmail_message_id, attachment_id, filename, mime_type, size}` — pulled from the email's `payload.parts` (per the Sprint 2 A3 work in memory).
4. Test with one synthetic invoice email; verify both events appear in the events table with matching `gmail_message_id`.

Risk: editing a live workflow that processes the email backbone. Use `workflow_history` + `workflow_entity` dual-patch pattern from [[feedback_homeai]]. Test before reactivating.

### Path C — Patch invoice-pipeline-v1 to tolerate missing document.received [defensive]

Make the Invoice Pipeline self-sufficient by fetching attachment metadata directly from the email/Gmail rather than relying on the sibling event.

1. Inspect `invoice-pipeline-v1`'s `Validate Event` node code (already done in U38 triage — reads `gmail_message_id`).
2. In the next node (likely "Find Attachment"), if no document.received row exists for this gmail_message_id, fetch attachments via `google-fetch:8011/attachments/{account}/{message_id}` directly.
3. Pick the first PDF attachment. Continue the pipeline.

Risk: changes the contract — invoice-pipeline now needs google-fetch reachable. (It already is via ai-internal network.)

**Recommended**: **Path A first** (cheap to test). If Poller deactivation was for a real reason, fall through to **Path B** (atomic emission). **Path C** as belt-and-braces hardening regardless.

## Track 3 — Verify + memory + commit (30 min)

- Emit a synthetic invoice email via `synthetic-email-suite.sh` and watch for clean processing: invoice.detected AND document.received both appear, Invoice Pipeline runs successfully, no dead_letter row.
- Watch for 1 full hour, verify no auto-pause fires.
- Selftest 50+/52.
- New memory `feedback_invoice_pipeline_sibling_events.md` documenting the asymmetry, the fix path chosen, and the assumptions.
- Update STATUS.md to remove the recurring auto-pause warning.

## Acceptance gates

- [ ] `SELECT COUNT(*) FROM dead_letter WHERE created_at > now() - interval '2 hours' AND resolved = false` returns 0 for 2 hours after fix lands.
- [ ] `SELECT (value->>'state') FROM static_context WHERE key='system.state'` returns `'running'` for the full 2-hour window.
- [ ] If Gmail Poller was reactivated: it executes successfully 3 cycles in a row (cron should fire every 1-5 min depending on its schedule).
- [ ] Synthetic test: insert one invoice email, both events appear, pipeline runs.

## Anti-scope

- **No new pipelines.** Pure fix work.
- **No schema changes.** All n8n + script.
- **No Authelia / Vault / image updates.**
- **No further sibling-event refactoring** beyond the immediate fix.

## Files in scope

- `workflow_history` rows for `gmail-ingest-v1` (if Path B) and `QMKzaCFrKBS4ewWm` (if Path A)
- `/home_ai/.claude/n8n-exports/gmail-ingest.json` — keep canonical export in sync
- `/home_ai/.claude/n8n-exports/invoice-pipeline.json` — same if Path C
- New: `/home/joly/.claude/projects/-home-joly/memory/feedback_invoice_pipeline_sibling_events.md`

## Total

~2 hr autonomous (1 hr investigation + ~45 min fix + 30 min verify). Lower than other recent sprints because it's targeted.
