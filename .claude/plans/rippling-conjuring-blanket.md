# Plan: Milestone B — First Vertical Slice

## Context
Phase 1, Milestone A is complete. All 14 services running. Model evaluator healthy, all three tiers deployed.

Milestone B requires one real email to flow end-to-end:
Gmail → email.received event → email_classifier (Ollama) → emails table → Metabase visible.

Gate B has 8 checks that must all pass before we move to Step 13.

---

## What exists already
- `/home_ai/.claude/n8n-exports/master-router.json` — Master Router workflow JSON, ready to import
- PostgreSQL credential already referenced in master-router.json: id `O7IPdbabKrYdm4Lq`, name "HomeAI Postgres"
- Ollama hot tier: qwen2.5:7b running and deployed
- n8n accessible at `http://100.104.82.53:5678`

---

## Step 10: Import and activate Master Router

### 10a — n8n API key (you do this in browser)
1. Open `http://100.104.82.53:5678`
2. Settings → API Keys → Create API key → copy it
3. Paste it back here — I'll use it for all remaining n8n API calls

### 10b — Verify/create HomeAI Postgres credential in n8n
The master-router.json references credential id `O7IPdbabKrYdm4Lq`. If that doesn't exist yet in n8n, I'll create it via API:
- Host: `postgres`, Port: `5432`, DB: `homeai`, User: `homeai_pipeline`, Password: `n8n99RedBalloons!`

### 10c — Import master-router.json via n8n API
```bash
curl -X POST "http://100.104.82.53:5678/api/v1/workflows" \
  -H "X-N8N-API-KEY: <key>" \
  -H "Content-Type: application/json" \
  -d @/home_ai/.claude/n8n-exports/master-router.json
```

### 10d — Activate it
```bash
curl -X PATCH "http://100.104.82.53:5678/api/v1/workflows/<id>/activate" \
  -H "X-N8N-API-KEY: <key>"
```

---

## Step 11: Build Gmail Ingest Pipeline

### 11a — Gmail credential (you do this in browser)
n8n → Credentials → New → Gmail OAuth2
- Requires Google OAuth client_id + client_secret (from Vault at `secret/gmail/account1` — needs OAuth setup)
- **Blocker:** Gmail OAuth not yet in Vault — marked deferred in spec. For Milestone B, we use a test approach: inject a synthetic `email.received` event directly and test the classifier + DB write path.

### 11b — Build Gmail Pipeline workflow JSON
I'll generate the full JSON for the Gmail Ingest workflow following the spec:
- Webhook trigger (receives `email.received` events from Master Router)
- Idempotency check (`email_{gmail_message_id}`)
- Sanitise body to `body_text_safe`
- Call Ollama qwen2.5:7b for classification
- Confidence check → Haiku escalation if < 0.8
- HMAC-sign payload
- INSERT to `emails` table (with `SET LOCAL app.current_entity`)
- INSERT to `events` (emit `email.classified`)
- Write to `audit_log`
- Error path → `dead_letter`

### 11c — Synthetic email test
Since Gmail OAuth is deferred, inject one test event directly:
```sql
INSERT INTO events (event_type, source, entity_id, payload, payload_signature, idempotency_key, status)
VALUES ('email.received', 'test', 1,
  '{"gmail_message_id":"test_001","from":"billing@staustellbrewery.co.uk",
    "subject":"Invoice INV-204418","body_text":"Please find attached...","body_text_safe":"Please find attached..."}',
  '<hmac>', 'email_test_001', 'pending');
```
This triggers the Master Router → email pipeline → full flow.

---

## Step 12: Metabase setup (you do this in browser)

1. Open `http://100.104.82.53:3000`
2. Add Data Source → PostgreSQL: host=`postgres`, db=`homeai`, user=`homeai_readonly`, password=(from Vault)
3. Create "Events Log" question: `SELECT id, event_type, source, created_at, status FROM events ORDER BY created_at DESC LIMIT 50`
4. Create "Email Review Queue" question: `SELECT id, from_address, subject, classification, entity_id, created_at FROM emails ORDER BY created_at DESC`
5. Save both to a new "Home AI" dashboard

---

## Gate B verification (after steps 10-12)
Run all 8 gate B checks:
1. email.received event in correct partition ✓
2. emails.classification populated ✓
3. email.classified event emitted ✓
4. events_overflow COUNT = 0 ✓
5. HMAC signature present on events rows ✓
6. audit_log row with pipeline='email_pipeline' ✓
7. Metabase shows email in review queue ✓
8. No dead letters ✓

---

## Files to create/modify
- `/home_ai/.claude/n8n-exports/gmail-pipeline.json` — new Gmail Pipeline workflow
- No other files — all work goes through n8n API or browser

## Constraints
- Never write the `n8n99RedBalloons!` password to any file (Vault-only rule)
- Gmail OAuth deferred — use synthetic test event for Gate B
- HMAC signing uses PAYLOAD_HMAC_KEY from Vault (available in n8n via VAULT_TOKEN env)
