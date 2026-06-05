# Invoice Pipeline (P2) — why it was off, what's fixed, what's left

**Date:** 2026-06-05 · Context: traced while investigating the email/invoice outage.

P2 (`invoice-pipeline-v1`, "Invoice Pipeline (P2)") was found `active=false`. It was NOT
off by accident — it has a stack of issues, peeled back in order:

1. **Claim stopgap (V224).** `claim_event_batch()` excludes
   `document.received / invoice.detected / child.event.detected` so their events don't
   get routed to dead/broken pipelines (they accumulate as `pending`). This is why the
   ~145 pending `invoice.detected` never reach P2. (Re-admit by removing `invoice.detected`
   from the `NOT IN (...)` list once P2 fully works.)
2. **`activeVersionId` was NULL** → n8n webhook returned 404
   `Active version not found for workflow id "invoice-pipeline-v1"`. Repointed to its only
   history version, then to the patched one (below).
3. **"Validate Event" string-body bug — FIXED.** The Master Router POSTs
   `body = JSON.stringify($json)`, so the webhook receives the event as a JSON *string*.
   P2's Validate Event did `const body = raw.body || raw` (no parse) → `body.id` undefined
   → `throw 'missing event id'`. The working pipelines tolerate it. **Fix applied:** parse a
   string body (`if (typeof body === 'string') body = JSON.parse(body)`). Lives in new n8n
   version **`3839dde2-f571-4eb0-a242-e5ea4d67c6d4`** (DB: `workflow_history` +
   `workflow_entity`). ⚠️ NOT in `.claude/n8n-exports/invoice-pipeline.json` — re-apply if P2
   is ever re-imported from that export.
4. **THE REMAINING BLOCKER — "Vault: Gmail Creds" 404 for Workspace accounts.** P2 node 5
   does `GET secret/data/gmail/{account}` to get OAuth creds for the attachment fetch. For
   `info`/`admin` that path doesn't exist (404) — those are **Workspace inboxes on
   Domain-Wide Delegation (sa-malthouse), not per-account OAuth** (see
   `feedback_google_identity_auth_split`). Since `info`/`admin` are the *main* invoice
   inboxes, P2 fails on most events → would flood. P2 works only for the OAuth consumer
   accounts (jo/bot/pounana).

## To finish P2 (focused follow-up)
Make P2's attachment fetch account-aware: use DWD (sa-malthouse) for Workspace accounts
(`info`/`admin`) and OAuth (`secret/gmail/<acct>`) for consumer accounts — OR, cleaner,
route the fetch through the **google-fetch** service, which already handles both auth modes
for ingestion. Then: re-admit `invoice.detected` to `claim_event_batch()`, reactivate P2,
and watch the ~1,500 backlog extract (~$10–25 one-time, Haiku). The Vault token credential
(`vault-token-header`) is already fixed/renewing, so node 6/7 (Signing/Anthropic) are fine.

## Current state (left stable)
P2 `active=false` (patched version retained); `invoice.detected` excluded from claim
(parked, no flood); email pipeline healthy. Workflow active/deactivate now audited
(`audit_log action='workflow_active_change'`, trigger V231).
