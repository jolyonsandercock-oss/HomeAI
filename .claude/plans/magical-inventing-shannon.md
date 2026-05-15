# Home AI Build Plan — Phase 1 Completion

## Context

Infrastructure is fully stood up (14 Docker containers, schema applied, Vault seeded).
Build state in AGENTS.md says "Step 0 (not started)" but Steps 1–9b are actually complete.
The one active blocker is n8n crash-looping due to `homeai_pipeline` password mismatch — caused by someone running `docker compose up -d` directly instead of `./start.sh`. Everything else flows from fixing this first.

Gmail workspace service account is in Vault (`secret/gmail/workspace`). Personal OAuth deferred.

---

## Phase A — Fix n8n + Housekeeping (right now, no browser needed)

### Step 1: Fix n8n crash loop
```bash
newgrp docker   # activate docker group for this shell
cd /home_ai
./start.sh      # fetches all secrets from Vault, injects env, restarts compose
```
Verify: `docker ps | grep n8n` → should show `Up X seconds` (healthy, not restarting)

### Step 2: Verify Gate A passes
```bash
# Vault unsealed
docker exec homeai-vault vault status | grep "Sealed.*false"

# Schema applied
docker exec homeai-postgres psql -U postgres -d homeai -c "\dt" | grep events

# Events routing to correct partition (not overflow)
docker exec homeai-postgres psql -U postgres -d homeai -c "SELECT COUNT(*) FROM events_overflow;"
# Expected: 0
```

### Step 3: Upgrade Ollama hot tier to qwen3:8b
Per STRETCH doc Section 2.1 — qwen3:8b supersedes qwen2.5:7b (same VRAM, one tier better quality).
```bash
docker exec -it homeai-ollama ollama pull qwen3:8b
# After pulling, register with model-evaluator:
curl -X POST http://localhost:8008/api/models/qwen3%3A8b/deploy/hot
```

### Step 4: Update AGENTS.md build state
Update line: `Phase: 1 | Milestone: B | Last completed step: 9b`
(Steps 1–9b are confirmed done from infrastructure inspection)

---

## Phase B — n8n Pipelines (needs n8n UI access via browser)

### Step 5: Get n8n API key
Access `http://100.104.82.53:5678/` in local browser → Settings → API → Create key.
Store in Vault:
```bash
docker exec -e VAULT_TOKEN=$VAULT_TOKEN homeai-vault vault kv put secret/n8n api_key="KEY_HERE"
```

### Step 6: Import Master Router workflow
The JSON is already exported at `/home_ai/.claude/n8n-exports/master-router.json`.
Import via n8n UI: Workflows → Import from file → select the JSON → Activate.

### Step 7: Build Gmail Ingest — Pipeline 1 (work account only)
This is the Gate B vertical slice. Build n8n workflow that:
1. Fetches service account JSON from `secret/gmail/workspace` via Vault HTTP node
2. Uses service account to authenticate with Gmail API (domain-wide delegation required — check Google Admin console)
3. Polls inbox → parses email → inserts to `emails` table with RLS entity context
4. Emits `email.received` event (signed with HMAC from `secret/signing`)
5. Routes to `email_classifier` AI worker (qwen3:8b via Ollama)
6. Updates `emails.classification` → emits `email.classified` event
7. Dead letter handling on failure

### Step 8: Gate B verification
```
[ ] One real work email → events table → email.received event (correct partition)
[ ] email_classifier ran → emails.classification populated
[ ] email.classified event emitted
[ ] events_overflow: COUNT(*) = 0
[ ] HMAC signature present on all events rows
[ ] audit_log: row with pipeline='email_pipeline'
[ ] No dead letters from this run
```

### Step 9: Minimal Metabase
Connect to PostgreSQL via homeai_readonly credentials.
Build two views: Events log + Email review queue.

---

## Phase C — Deferred (no action yet)

- **Personal Gmail OAuth** (2 accounts): Add when user can complete OAuth flows locally
- **Milestone C pipelines** (Steps 13–19): Pull remaining Ollama models, build 12 remaining workflows, Grafana, Restic backups
- **Phase 5 RAG / Qdrant collections**: Set up after Phase 1 Gate C passes

---

## Critical files
- `/home_ai/SPEC.md` — full spec (sections 4.3, 6.4, 6.5)
- `/home_ai/HOME-AI-STRETCH.md` — STRETCH doc (sections 1.1–1.3)
- `/home_ai/AGENTS.md` — build state + rules
- `/home_ai/start.sh` — MUST use instead of `docker compose up -d`
- `/home_ai/.claude/n8n-exports/master-router.json` — pre-built router workflow
- `/home_ai/postgres/init-db.sql` — schema reference

## Note on private key
The service account JSON stored in Vault is missing the `private_key` field (it was omitted when storing to avoid shell escaping issues). Before building Pipeline 7, re-store with the full private key via a JSON file:
```bash
# Write key to temp file, store, then delete
cat > /tmp/sa.json << 'EOF'
{ ...full JSON including private_key... }
EOF
docker exec -e VAULT_TOKEN=$VAULT_TOKEN homeai-vault vault kv put secret/gmail/workspace @/tmp/sa.json
rm /tmp/sa.json
```
