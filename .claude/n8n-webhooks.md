# n8n Webhook Registry

Generated record of every n8n webhook URL in the live stack. Updated as
workflows are built. Per HOME-AI-STRETCH §3.4 — webhook URLs are only known
after the workflow is created, so this file is the lookup of last resort
when configuring upstream callers (Master Router, microservices, etc).

- Internal base (Docker network):  `http://homeai-n8n:5678/webhook/<path>`
- Tailscale base (LAN access):     `http://100.104.82.53:5678/webhook/<path>` (when port mapping enabled; otherwise via Caddy)
- Test variant:                     `/webhook-test/<path>` only fires when "Listen for test event" is on in the n8n UI

---

## Live webhooks (verified 2026-05-09 against `workflow_entity` rows)

### `POST /webhook/email-pipeline`
- **Workflow:** `gmail-ingest-v1` (Gmail Ingest Pipeline)
- **Trigger source:** Master Router → `email.received` route
- **Body:** events row body (`{id, trace_id, event_type, payload: {gmail_message_id, ...}}`)
- **Response:** classified email → INSERT emails → emits `email.classified`, optionally `invoice.detected` and `child.event.detected`

### `POST /webhook/bank-csv`
- **Workflow:** `bank-csv-import-v1` (Bank CSV Import)
- **Trigger source:** manual user upload
- **Body:** `multipart/form-data` with:
  - `bank_account_id` (form field, integer) — must match a row in `bank_accounts`
  - `csv` (file) — CSV with at minimum a date column and an amount column. UK column name variants are auto-detected (date / transaction date / posted date; amount / money in + money out).
- **Sample:**
  ```bash
  curl -X POST http://homeai-n8n:5678/webhook/bank-csv \
    -F bank_account_id=2 \
    -F csv=@statement.csv
  ```
- **Response:** `{set_config: "1"}` (n8n quirk — ignore; rows + `bank.imported` event land in DB regardless). Verify via:
  ```sql
  SELECT id, transaction_date, amount FROM bank_transactions
   WHERE bank_account_id=<id> ORDER BY id DESC LIMIT 5;
  ```

### `POST /webhook/invoice-pipeline`
- **Workflow:** `invoice-pipeline-v1` (Invoice Pipeline P2)
- **Trigger source:** Master Router → `invoice.detected` route (emitted by gmail-ingest-v1 when classified='invoice')
- **Body:** events row with payload `{gmail_message_id, email_id, attachment_id, filename, mime_type}` (resolved by P2 from email_attachments)
- **Response:** pdfplumber/MarkItDown extraction → Haiku invoice_extractor → INSERT invoices + supplier_invoice_history rolling stats + emits `invoice.unmatched` (Xero matching is stubbed pending P3) + audit_log.
- Idempotency key: `invoice_{sha256(supplier+gross+date+entity)}`.

### `POST /webhook/report-ingestion`
- **Workflow:** `report-ingestion-v1` (Report Ingestion P9)
- **Trigger source:** Master Router → `document.received` route (emitted by Gmail Poller per attachment, post-Sprint-2 A3)
- **Body:** events row with payload `{gmail_message_id, attachment_id, filename, mime_type, size}`
- **Response:** updates `email_attachments.extracted_text + processed=true`, audit_log row with OutcomeObject

### `POST /webhook/nanny`
- **Workflow:** `nanny-v1` (Nanny P8)
- **Trigger source:** Master Router → `child.event.detected` route (emitted by gmail-ingest-v1 when classification = `school-medical`)
- **Body:** events row with payload `{gmail_message_id, email_id, from_address, subject, body_text_safe, classification, ai_summary}`
- **Response:** INSERT `child_events` (+ `medical_history` if is_medical=true) + audit_log with OutcomeObject

### `POST /webhook/prom-alert`
- **Workflow:** `alert-sink-v1` (Alertmanager Sink)
- **Trigger source:** Alertmanager (`homeai-alertmanager:9093`) per `prometheus.yml` `alerting:` block
- **Body:** Alertmanager batch payload `{alerts: [{labels, annotations, status, ...}]}`
- **Response:** flatten + UPSERT `system_alerts` + audit_log row + branch on `auto_pause` flag (when `alertname == DeadLetterFlood && status == firing` it sets `static_context.system.state` to paused, Master Router's Kill Switch catches on next 30s cycle)

---

## Master Router routing table

Master Router (`test-master-router`) claims `events` rows in batches of 10
every 30s and POSTs each event's row body to the matching webhook based on
`event_type`. Source: `master-router.fixed.json`.

| event_type             | Target URL                                                   | Status |
|------------------------|--------------------------------------------------------------|--------|
| `email.received`       | `http://homeai-n8n:5678/webhook/email-pipeline`              | wired |
| `invoice.detected`     | `http://homeai-n8n:5678/webhook/invoice-pipeline`            | wired (Sprint 3) |
| `document.received`    | `http://homeai-n8n:5678/webhook/report-ingestion`            | wired |
| `child.event.detected` | `http://homeai-n8n:5678/webhook/nanny`                       | wired |
| `bank.transaction`     | (no listener yet — bank_pipeline = post-P3 Xero)             | route only |
| `epos.report.received` | (no listener yet — P5)                                       | route only |
| `accommodation.received` | (no listener yet — P6)                                     | route only |
| `cashing_up.entry`     | (no listener yet — P7)                                       | route only |
| `digest.scheduled`     | (no listener yet — P10 = U8 sprint Stage 1)                  | route only |

Pipelines that don't exist yet have a Switch output with no downstream
node, so events of those types land back in the `events` table and stay
`processing` until `recover_stale_leases()` recovers/dead-letters them.

---

## Other active workflows (no webhook — schedule or trigger driven)

| Workflow | Trigger | Purpose |
|---|---|---|
| `Gmail Poll Driver` (`gmail-poll-driver-v1`) | scheduleTrigger every 15 min | 2-node workflow: schedule → HTTP POST `http://google-fetch:8011/poll-and-emit`. The Python sidecar `homeai-google-fetch` does the actual auth + Gmail API + atomic claim+INSERT for all 5 accounts (jo/pounana/bot/info/admin). Replaces legacy single-account `QMKzaCFrKBS4ewWm` (deactivated in U10-bis). Audit row written per fire. |
| `Master Router` (`test-master-router`) | scheduleTrigger every 30s | Claims pending events in batches of 10, dispatches per the routing table above |
| `Partition Maintenance` (`partition-maintenance-v1`) | cron `0 9 25 * *` | Calls `ensure_next_event_partition()` for month+2 |
| `HMAC Signature Verifier` (`hmac-verifier-v1`) | cron `30 4 * * *` | Samples 100 random events, verifies HMAC-SHA256 against `secret/signing` |
| `Watchdog — n8n Errors` (`watchdog-n8n-errors`) | n8n errorTrigger | Catches workflow execution errors → INSERTS `system_alerts` row (Telegram path stubbed pending U8-S1) |
| `Dreaming (Workflow H)` (`dreaming-v1`) | cron `0 2 * * *` | Aggregates audit_log failures → Haiku → writes /home_ai/storage/dreaming/heuristics.md |
| `Diagnostics (daily)` (`diagnostics-v1`) | cron `30 10 * * *` | 10 health tests via single SQL → forwards critical/warning to alert-sink |
| `Cleanup (weekly)` (`cleanup-v1`) | cron `0 4 * * 0` | Prunes >30d successful executions / >30d resolved alerts / >90d diagnostic_history / >90d dead_letter_archive + VACUUM ANALYZE |

---

## Inactive / placeholder routes (no listener yet)

| Event type | Future pipeline | Future webhook path |
|---|---|---|
| `bank.flagged` | reconciliation_pipeline | `/webhook/reconciliation` |
| `compliance.check` | compliance_pipeline | `/webhook/compliance` |
| `xero.sync.scheduled` | xero_pipeline (U8-S4) | `/webhook/xero-sync` |
| `digest.scheduled` | daily_digest (U8-S1) | `/webhook/daily-digest` |
| `health.sync.scheduled` | personal_trainer_pipeline | `/webhook/personal-trainer` |

---

## Reachability + testing

n8n is on docker networks: `ai-internal`, `ai-services`, `ai-egress`. There
is no host port published in `docker-compose.yml`; Caddy reverse-proxies
external access. From a one-off curl container on the right network:

```bash
docker run --rm --network home_ai_ai-services curlimages/curl:latest \
  -sS -X POST http://homeai-n8n:5678/webhook/<path> ...
```

---

## How to refresh this file

```bash
docker exec homeai-postgres psql -U postgres -d homeai -tAc "
SELECT we.name || ' | ' || (n->>'name') || ' | path=' || COALESCE(n->'parameters'->>'path','-') || ' | method=' || COALESCE(n->'parameters'->>'httpMethod','POST')
FROM workflow_entity we, jsonb_array_elements(we.nodes::jsonb) n
WHERE we.active=true AND n->>'type' = 'n8n-nodes-base.webhook'
ORDER BY we.name;"
```
