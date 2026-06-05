# Invoice Pipeline (P2) — account-aware attachment fetch (DWD-safe)

**Date:** 2026-06-05 · U243 S3 (design only — produced by the overnight run; build is an
attended task). Companion: `.claude/decisions/2026-06-05-invoice-pipeline-p2-diagnosis.md`.

## Problem
P2 fetches the invoice PDF from Gmail via an **OAuth-only** chain:
`Vault: Gmail Creds (GET secret/data/gmail/{account})` → `OAuth refresh` →
`Gmail: Fetch Attachment`. For `info`/`admin` — Workspace inboxes on **Domain-Wide
Delegation (sa-malthouse), not per-account OAuth** — `secret/gmail/{account}` doesn't exist
→ 404 (`NodeApiError: resource could not be found`) → every Workspace invoice fails. Since
`info`/`admin` are the main invoice inboxes, P2 fails on most events.

## Solution (approach B — reuse google-fetch; chosen because it already solves auth-mode)
`services/google-fetch/main.py` already dispatches per-account auth
(`access_token()` → `access_token_oauth` for `auth=='oauth'`, `access_token_sa` /
service-account impersonation for `auth=='service_account'`; accounts + their `auth` mode
come from `static_context.gmail.accounts`). It already exposes:

```
GET /attachment/{account}/{message_id}/{attachment_id}
    -> {"attachment_id":..., "size":..., "data_b64url": "<base64url bytes>"}
```

This works for **any** account regardless of auth mode. **So P2 should fetch the attachment
through google-fetch, not its own Gmail flow.**

## Exact P2 changes (n8n workflow `invoice-pipeline-v1`, version-surgery per the n8n DB-edit pattern)
By this point P2 already has (from the validated event + `Find Attachment`): `account`,
`gmail_message_id`, `attachment_id`.

1. **Delete / bypass** three nodes: `Vault: Gmail Creds`, `OAuth refresh`, `Gmail: Fetch Attachment`.
2. **Add one HTTP Request node** `Fetch Attachment (google-fetch)`:
   - `GET http://homeai-google-fetch:<PORT>/attachment/{{account}}/{{gmail_message_id}}/{{attachment_id}}`
     (confirm google-fetch's container name + internal port from `docker-compose.yml`; it's the
     same service `/poll-and-emit` runs in.)
   - No credential needed (internal Docker network; google-fetch holds the Gmail auth).
3. **`Decode + Build Form`** (next node): base64url-decode `data_b64url` into the PDF bytes,
   then continue unchanged into `Extract Text → pdfplumber(8003)/markitdown(8004)` →
   `Build Extractor Prompt` → `Extract via Claude Haiku` → `Build OutcomeObject` → write to
   `vendor_invoice_inbox` / `supplier_invoice_history` / `audit_log`.
4. **Keep** the `Vault: Signing Key` and `Vault: Anthropic Key` nodes — they use the
   `vault-token-header` credential, which is now fixed + (when the cron is on) auto-renewing.
   The `Validate Event` string-body fix is **already applied** in version `3839dde2`.

## Re-enable sequence (attended; watch for flood)
1. Apply the P2 node changes (new active version), `docker restart homeai-n8n`.
2. **Test ONE Workspace-account event** first: pick a pending `invoice.detected` with
   `payload.account='info'`, POST it (double-encoded, as the Master Router does) to
   `/webhook/invoice-pipeline`; confirm the execution reaches `Extract via Claude Haiku` and
   writes a `vendor_invoice_inbox` row (status `extracted`). Then test an OAuth account (e.g. `jo`).
3. **Re-admit** `invoice.detected` to the claim: remove it from the `NOT IN (...)` list in
   `claim_event_batch()` (the V224/V232 toggle). Reactivate P2 (`active=true`).
4. Watch: P2 executions success, `vendor_invoice_inbox.status='extracted'` rises,
   `invoice.detected` pending drains, **no dead_letter flood / auto-pause**. If it floods,
   re-exclude + deactivate (the documented stable state) and investigate the failing node.
5. The ~1,500 backlog (357 new + 1,171 needs_review) then extracts via Haiku
   (~$10–25 one-time; `v_invoice_categorised` + `home_ai.canonical_category()` from U243 S4
   give the unified categories).

## Test plan / acceptance
- One `info` event → execution reaches Haiku + writes an `extracted` row (proves DWD path).
- One `jo` (OAuth) event → same (proves no regression for consumer accounts).
- After re-admit + reactivate: `invoice.detected` pending trends to 0, `extracted` count rises,
  no flood, email pipeline still healthy.

## Cost / risk
~$10–25 one-time (Haiku over the backlog), ~$0.30/day ongoing. Risk is bounded by the
test-one-first + flood-guard + the documented re-exclude-and-deactivate rollback.
