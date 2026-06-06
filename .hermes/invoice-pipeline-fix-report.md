I am maintaining the Home AI system. Read AGENTS.md and SPEC.md for full context.

We completed a deep investigation into why vendor invoices aren't being categorised and line items aren't being extracted. The root cause is clear: THREE critical pipelines are deactivated in n8n, and Vault is down. Fix in this exact order — each depends on the previous.

---

## STEP 1 — Restore Vault

`docker compose ps` shows `homeai-vault` is not running. The invoice pipeline depends on Vault for: Gmail OAuth creds, HMAC signing key, Anthropic API key.

```
docker compose up -d homeai-vault
docker compose exec homeai-vault vault status
```

If sealed: unseal it. Verify keys are accessible:
```
docker compose exec homeai-vault vault kv get secret/data/gmail/personal1
docker compose exec homeai-vault vault kv get secret/data/signing
docker compose exec homeai-vault vault kv get secret/data/anthropic
```

---

## STEP 2 — Activate Master Router

File: `/home_ai/.claude/n8n-exports/master-router.json`
Current state: `"active": false`

This is the central event router. Without it, no events flow to ANY pipeline — 148 events are stuck as `pending`. Import and activate it in n8n:

```
# Via n8n API or UI — set active: true
```

Verify by checking the events table after activation:
```sql
SELECT status, COUNT(*) FROM events GROUP BY status;
-- Should see 'pending' count dropping as router claims batches
```

---

## STEP 3 — Activate Gmail Ingest Pipeline

File: `/home_ai/.claude/n8n-exports/gmail-ingest.json`

This classifies incoming emails (invoice, nanny, etc.) and emits events. Without it, no `invoice.detected` events are created. The Gmail Poll Driver IS active and fetching emails, but nothing processes them.

Activate in n8n, then verify:
```sql
SELECT classification, COUNT(*) FROM emails WHERE processed = false GROUP BY classification;
```

---

## STEP 4 — Activate Invoice Pipeline

File: `/home_ai/.claude/n8n-exports/invoice-pipeline.json`
Current state: `"active": false`

This is the core pipeline — 15 nodes:
1. Webhook receiver (triggered by master router)
2. Validate Event — checks payload shape
3. Find Attachment — looks up `document.received` event for this email
4. Merge Attachment Meta — picks pdfplumber vs markitdown by MIME type
5-7. Vault: Gmail Creds, Signing Key, Anthropic Key
8. OAuth refresh
9. Gmail: Fetch Attachment
10. Decode + Build Form
11. Extract Text → pdfplumber (port 8003) or markitdown (port 8004)
12. Build Extractor Prompt
13. Extract via Claude Haiku (Anthropic API) — structured JSON extraction
14. Build OutcomeObject + Idempotency Key
15. Write to invoices table + supplier_invoice_history + audit_log

Activate in n8n. The pipeline is event-driven — it fires when the master router POSTs an `invoice.detected` event. Once active, it should start processing the backlog.

---

## STEP 5 — Backfill the 357 'new' + 1,171 'needs_review' invoices

Once the pipeline is running, replay the backlog. Check the database:

```sql
-- Current backlog
SELECT status, COUNT(*) FROM vendor_invoice_inbox
WHERE status IN ('new', 'needs_review')
GROUP BY status;
```

For `needs_review` items: these are emails that were flagged as invoices but never had their PDF extracted. The pipeline should pick them up when the Master Router replays their events.

For `new` items: these are unprocessed emails. Re-trigger the Gmail Ingest pipeline to classify them, then the router will feed them to the invoice pipeline.

---

## STEP 6 — Fix data quality issues (once pipeline is running)

After the pipeline is processing again, fix these:

### 6a. Westcountry Fruit is misclassified
```sql
-- Current rule says Beverage — should be Food
SELECT * FROM vendor_category_rules WHERE domain_pattern = 'westcountry';
-- Fix it:
UPDATE vendor_category_rules SET category = 'Food' WHERE domain_pattern = 'westcountry';
```

### 6b. St Austell Brewery statements excluded from COGS
The `v_daily_cost_vs_sales` view filters out `is_statement = true`. St Austell sends monthly statements, not individual invoices. This means your biggest supplier (£5k+/month) never appears in costs.

Fix: modify the view or add a separate statement ingestion path. The view SQL is:
```sql
-- Current filter: AND is_statement = false
-- This excludes ALL statements including St Austell Brewery
```

Option A: Remove the `is_statement = false` filter from the view
Option B: Create a separate statement parser that extracts line items from statement PDFs

### 6c. Category vocabulary mismatch
The AI pipeline outputs `wet_purchase`/`dry_purchase`/`software`/`repairs_maintenance`/`utilities`/`other`.
The vendor_category_rules table uses `Food`/`Beverage`/`Maintenance`/`Software`/`Bookings`/`Laundry`.

These don't map. Create a mapping table or standardise on one vocabulary.

### 6d. 47.5% of invoices have zero data
```sql
SELECT COUNT(*) FROM vendor_invoice_inbox
WHERE status NOT IN ('duplicate', 'ignored') AND is_statement = false
  AND category_canonical IS NULL AND net_amount IS NULL AND gross_amount IS NULL;
-- 1,210 invoices — completely empty
```

These were ingested before the pipeline was turned off and never processed. Once the pipeline is running, they should be re-processed.

---

## Verification — after all steps

```sql
-- Should show active processing
SELECT status, COUNT(*) FROM events GROUP BY status;

-- Should show growing categorisation
SELECT category_canonical, COUNT(*) FROM vendor_invoice_inbox
WHERE status = 'extracted' GROUP BY category_canonical;

-- Master Router should be claiming events
SELECT COUNT(*) FROM events WHERE status = 'processing';
```

---

## Context

- P620, Ubuntu 22.04, Docker Compose
- n8n at http://n8n:5678 (inside Docker network)
- Database: postgres:5432, database homeai
- pdfplumber at http://homeai-pdfplumber:8003
- markitdown at http://homeai-markitdown:8004
- Vault at http://vault:8200
- All secrets in Vault, not .env
- Never write secrets to files
- Pipeline uses Anthropic API (Claude Haiku) — costs per extraction
- Confidence threshold: 0.85 for success, escalates below that
- Idempotency key format: invoice_{sha256(supplier+gross+date+entity)}

Work through steps 1-6 in order. Propose fixes before implementing. Report after each step.
