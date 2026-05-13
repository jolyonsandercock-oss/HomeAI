# HOME AI ADMINISTRATIVE ENGINE
## Master Build Specification — v5.2 (Definitive)
## Owner: Jo | Atlantic Road Trading Ltd / Atlantic Road Estates Limited
## April 2026 | Supersedes: all previous versions including v4.x series

---

## HOW TO USE THIS DOCUMENT WITH CLAUDE CODE

This is a single self-contained build document. Every decision is resolved. No external documents are needed.

### Starting a session

```bash
cd /home_ai
claude          # opens Claude Code
```

At the first prompt:
> *"I am building the Home AI system. Read AGENTS.md for full context. We are on [Phase N, Step N] — let's start there."*

Between sessions:
> *"We are building the Home AI system. AGENTS.md has full context. We completed up to [Phase N, Step N]. Continue from there."*

If something breaks:
> *"Step N failed with this error: [paste error]. Read the relevant section of SPEC.md and propose a fix before making any changes."*

### Mandatory workflow — Plan Mode first

**Every step must begin in Plan Mode.** Press `Shift+Tab` twice to activate. Claude reads files and analyses without touching anything.

Four-phase sequence for every step:

```
1. EXPLORE  (Plan Mode)    — read relevant spec section + existing files
2. PLAN     (Plan Mode)    — propose implementation, press Ctrl+G to edit
3. VERIFY   (Plan Mode)    — iterate with "address all notes, don't implement yet"
4. EXECUTE  (Normal Mode)  — only after plan is approved, switch with Shift+Tab
```

**The guard phrase matters.** Always say "don't implement yet" when refining a plan. Without it, Claude skips straight to writing files.

**Split large steps.** If a plan has more than 6 actions, split it. Three plans of two steps each ship more reliably than one plan of six.

**Verify the first file write.** After approving a plan, open the first file Claude writes and confirm it matches expectations before letting it continue.

### Context window discipline

A fresh session loads ~20,000 tokens before you type anything. Quality degrades noticeably past 40% of the 200k window. Auto-compaction fires at ~83% and is lossy — retaining only 20–30% of details. One developer lost three hours of database migration work to a mid-session auto-compaction.

**Rules:**
- Watch the context indicator (bottom of terminal)
- Run `/compact` before reaching 60% — never let auto-compaction fire during a Vault, database, or Docker step
- When compacting, use: `/compact Preserve: current phase and step number, all Vault secrets confirmed loaded, all Docker services confirmed running, all PostgreSQL tables confirmed created, any idempotency key formats discussed`
- If context feels stale (Claude starts repeating itself or ignoring instructions), run `/clear` and restart the step with a tighter prompt

### Parallel subagents

Claude Code can run up to 10 subagents in parallel, each with its own isolated context window. Use them for independent domains — never for tasks that write to the same files.

**Domain routing for this project:**

| Domain | Parallel-safe | Notes |
|---|---|---|
| Microservices (pdfplumber, garmin) | ✓ Yes | Independent builds, no shared files |
| n8n pipeline workflows | ✓ Yes | Each is an independent JSON workflow |
| Monitoring config | ✓ Yes | Separate from all other services |
| PostgreSQL schema + seed data | ✗ No | Sequential — tables have foreign keys |
| Vault configuration | ✗ No | Sequential — order matters |
| Docker Compose | ✗ No | Single file, one writer |

To spawn a subagent for an independent task: *"Use a subagent to build the pdfplumber service while we continue with the Garmin service in this session."*

For subagents handling focused tasks (reading files, checking outputs), use a lighter model to save cost: `export CLAUDE_CODE_SUBAGENT_MODEL="claude-haiku-4-5-20251001"` in the session environment.

### Step discipline — four rules that compound

**1. One step at a time.** Only ask Claude for the very next step. Review it. Then ask for the one after. Asking for multiple steps at once produces unreviable output and errors that compound invisibly.

**2. `/rewind` before `/clear`.** When Claude makes a mistake mid-step, press ESC ESC (or `/rewind`) to step back to the last good state without losing session context. Use `/clear` only when the entire session direction is wrong. `/rewind` is the right default; `/clear` is the nuclear option.

**3. Don't fix bugs yourself.** When Claude introduces a bug, resist the urge to patch it yourself. Ask Claude to investigate the bug, update the relevant Gotchas section in AGENTS.md to explain what went wrong, then fix it. The documentation persists across sessions; the lesson stays in the system.

**4. `/simplify` then `/review` before marking any step done.** `/simplify` strips over-engineering Claude tends to add (unnecessary abstractions, speculative error handling, defensive code for problems that don't exist). `/review` lets Claude catch its own issues. Run both before any human review — the output is cleaner and your review is faster.

### End-of-session retro

At the end of every build session, ask Claude: *"What did you learn during this session?"*

Route the output to the correct file:
- Build failures and fixes → `System/Assistant/logs/issues-fixes-log.md`
- Architectural decisions → `/home_ai/.claude/decisions/YYYY-MM-DD-topic.md` (new ADR folder)
- Repeated mistakes or Claude failure modes → AGENTS.md Gotchas section
- General project conventions → AGENTS.md

This is how institutional knowledge accumulates. Without the retro, lessons from Phase 1 build don't make it into the context for Phase 2.

### Slash commands

Run these at any point in a session:

| Command | Action |
|---|---|
| `/verify-phase1` | Runs the full Phase 1 testing checklist |
| `/check-vault` | Verifies all required secrets are loaded |
| `/check-services` | `docker compose ps` + health checks |
| `/replay-event` | Dead letter replay — prompts for event_id |
| `/check-partitions` | Verifies events table partitions + overflow count |
| `/security-review` | Runs `/security` and summarises findings |
| `/compact` | Manual context compaction (use before 60%) |
| `/rewind` | Step back to last good state (ESC ESC) — use before /clear |
| `/simplify` | Strip over-engineering from Claude's output |
| `/review` | Claude self-reviews its own output before human review |
| `/pause-all` | Set system_state = paused — all pipelines stop |
| `/resume-all` | Set system_state = running — pipelines resume |
| `/btw` | Quick question that never enters context history |

### Build order is mandatory

Phase 1 must be fully tested before Phase 2. Do not skip steps. The AGENTS.md file (created in Step 4) gives Claude Code persistent project context — it is read every session automatically.

---

# PART 0: HOW TO USE YOUR SYSTEM (OPERATIONAL GUIDE)

**This section is for Jo, not for Claude Code.** It describes how to actually use the system once it is built — which interface, for what, and with concrete examples. Read this before Part 1.

---

## 0.1 The Six Interfaces

You have six ways to interact with your system. They are not interchangeable — each has a job.

| Interface | When to use it | Where |
|---|---|---|
| **Telegram bot** | Quick queries at the pub — takings, cashflow, approvals | Your phone |
| **Next.js dashboard** | Review and action flagged items — Kanban, Action Queue | Phone or browser |
| **Claude.ai (here)** | Complex analysis, thinking through problems, business questions | claude.ai |
| **Open WebUI** | Free local chat — simple questions to your local models | Tailscale IP:8088 |
| **Obsidian** | Writing, notes, your personal knowledge base | Desktop or Obsidian app |
| **Claude Code** | Building, fixing, and maintaining the system — not for daily use | P620 terminal |

---

## 0.2 Pattern 1 — Automatic (Nothing Required)

**Most of the system runs itself.** These things happen whether you look at them or not:

- Emails are classified and routed the moment they arrive
- Invoices are extracted from PDFs and matched against Xero
- Bank transactions are reconciled (once Open Banking is live in Phase 2)
- Cashing up variance is checked and flagged if > £5
- The beer garden probability is calculated from tomorrow's forecast
- ICRTouch Z-reports are parsed and stored every evening
- The morning digest is composed at 06:45 and delivered at 07:00

**Your input:** Read the Telegram digest in the morning. Act on anything marked `[!]`. Everything else has been handled.

---

## 0.3 Pattern 2 — Telegram Bot (At the Pub)

**The fastest interface. Works on any phone with no app to open.**

Your Telegram bot accepts commands as well as sending alerts. Send any of these to your bot:

```
/takings          → last night's Z-report summary (gross, card, cash, variance)
/cashflow         → 30-day cashflow forecast for Trading Ltd
/rent             → this month's rent status (7 properties — received / outstanding)
/queue            → count of items in the Action Queue requiring your attention
/approve [id]     → approve an Action Queue item by ID (shown in the Telegram alert)
/pause            → pause all pipelines immediately (global kill switch)
/resume           → resume all pipelines
/beer             → today's beer garden probability from the Oracle
/tides            → today's tide times for Tintagel Haven
/status           → system health summary (services up, dead letters, last pipeline run)
```

**Add to n8n Workflow E (Telegram bot — activate Phase 1):**

```javascript
// n8n Telegram Trigger node — listens for inbound messages to your bot
// Routes commands to the appropriate query or action

const msg = $input.first().json.message?.text || '';
const chatId = $input.first().json.message?.chat?.id;

const commands = {
  '/takings':  () => db.fetchRow('SELECT gross_sales, card_total, cash_counted, variance FROM till_reconciliation ORDER BY recon_date DESC LIMIT 1'),
  '/cashflow': () => db.fetchRow('SELECT forecast_closing, forecast_income, forecast_expenses FROM cashflow_forecast WHERE entity_id=1 ORDER BY forecast_date DESC LIMIT 1'),
  '/rent':     () => db.fetch('SELECT p.address_line1, rp.status, rp.expected_amount FROM rent_payments rp JOIN tenancies t ON rp.tenancy_id=t.id JOIN properties p ON t.property_id=p.id WHERE rp.expected_date >= date_trunc('month', NOW())'),
  '/queue':    () => db.fetchVal('SELECT COUNT(*) FROM invoices WHERE requires_human=true AND status='pending''),
  '/status':   () => db.fetchRow('SELECT COUNT(*) FILTER (WHERE resolved=false) as dead_letters FROM dead_letter'),
};

const handler = commands[msg.split(' ')[0]];
if (handler) {
  const result = await handler();
  // Format result → send to chatId via Telegram HTTP node
}
```

**Why this matters:** You're behind the bar at 7pm and someone asks about a payment. You pull out your phone, type `/rent`, and have the answer in 3 seconds. No laptop, no dashboard, no waiting.

---

## 0.4 Pattern 3 — Dashboard (Actioning Things)

**The Next.js dashboard (Phase 3) is for actioning flagged items — not for reading data.**

Open it on your phone when you get an alert that something needs attention:

- A Telegram alert fires: *"[!] Invoice for EDF Energy flagged — VAT mismatch"*
- You open the dashboard at `/action`
- You see the Goal Card: EDF Energy, £847, the reasoning visible, a hypothesis below it
- You tap Approve or Flag
- Done. Back to running the pub.

The dashboard also gives you the Morning Command Center at `/` — a one-screenful snapshot of yesterday and today. Open this over morning coffee instead of hunting through emails.

**The dashboard is not a BI tool.** Don't use it to analyse trends or run reports. For that, use Claude.ai (Pattern 4).

---

## 0.5 Pattern 4 — Claude.ai (Analysis and Thinking)

**For anything that requires reasoning, not just retrieval — use this interface.**

Claude.ai (what you are using right now) is where you come when you have a question that doesn't have a simple SQL answer.

**With the PostgreSQL MCP connector (Phase 3 addition — see Section 8.6):**

Once the database MCP server is connected to your Claude.ai account, you can ask questions against live data directly in this interface:

```
"What's my food GP trend over the last 3 months?"
"Which staff member is consistently cashing up short?"
"Compare this month's accommodation revenue to the same period last year."
"Is my Korev consumption running ahead of last summer?"
"What would happen to my wage percentage if I added one more full-time member?"
```

Claude will query your database, pull the numbers, and reason about them. No copy-pasting, no exports.

**Without the MCP connector (Phase 1 and 2):**

Export data from Metabase or run a quick SQL query, paste the results here, and ask your question. The context window holds a full month of EPoS data comfortably.

**Best uses for Claude.ai:**

- Thinking through a difficult staff situation
- Drafting a response to a difficult TripAdvisor review
- Analysing a complex reconciliation flag the system has raised
- Planning next season's menu based on this season's data
- Understanding a legal or contractual question about a tenancy
- Anything where you need to *think*, not just *retrieve*

**The Obsidian connection:** Once your Obsidian vault has context about your business (Phase 3), you can paste relevant sections into a Claude.ai conversation to give it business-specific context: *"Here's my pub context [paste MEMORY.md] and here's last month's EPoS data [paste export] — analyse my ploughs."*

---

## 0.6 Pattern 5 — Open WebUI (Free Local Chat)

**For simple questions that don't need cloud intelligence and don't need your data.**

Open WebUI runs locally on the P620 and gives you a ChatGPT-style interface backed by your local Ollama models. Access it at `http://[tailscale-ip]:8088` from any device on your Tailscale network.

**Good uses:**
- Drafting a quick email or letter
- Summarising a document you paste in
- Brainstorming ideas for the pub
- Asking a general knowledge question
- Testing what your local models can do

**Not suitable for:**
- Questions about your business data (no database access unless you add it)
- High-stakes analysis (local 70B is good, Sonnet is better for complex reasoning)
- Anything requiring internet access (local only)

It's free — no API costs. Use it liberally for things that don't need Sonnet's reasoning capability.

---

## 0.7 Pattern 6 — Claude Code (Maintenance Only)

**Open Claude Code only when something needs building, fixing, or changing.**

You should not be in Claude Code daily. If you find yourself opening it every day for operational queries, something is missing from the Telegram bot or dashboard — add it there instead.

**Legitimate Claude Code tasks:**
- A pipeline is broken (dead letter, wrong output)
- You want to add a new feature to the system
- You want to run `/biography` for a periodic review
- You want to update a prompt because AI worker confidence has dropped
- A new model needs benchmarking and deploying

**Opening phrase for maintenance sessions:**
> *"Something needs fixing: [describe problem]. Read the relevant section of SPEC.md and propose a fix before making any changes."*

---

## 0.8 The Daily Rhythm

What a normal day looks like once the system is running:

```
06:50  Telegram delivers the morning digest
       Read it over coffee — 2 minutes
       Act on anything marked [!] immediately
       Everything else: noted, handled later or automatically

During the day
       Telegram alerts fire if something needs attention
       Each alert has an action: approve, check, call someone
       Most resolve with one tap in the dashboard

Evening (pub)
       /takings before close to check cashing up status
       Dashboard shows variance if flagged

Weekly (Sunday evening)
       Ice Cream Oracle recommendation arrives in Telegram
       Beer Garden forecast for the week in the Monday digest
       St Austell draft order arrives Tuesday for Thursday delivery

Monthly
       Ghost Shift Detector quiet flag in digest (if anything to flag)
       Menu Engineering Agent 2x2 in /pub/menu dashboard
       Model evaluator benchmark results (automated)

Ad hoc (when needed)
       Open Claude.ai for analysis or thinking
       Open dashboard for complex Action Queue items
       Open Claude Code only if something broke or needs building
```

---

# PART 1: CONTEXT AND FOUNDATION

## 1.1 Business Entities

| ID | Entity | Type | Key Systems |
|---|---|---|---|
| 1 | Atlantic Road Trading Ltd | Company — pub/restaurant/inn/ice cream | Xero org 1, NatWest business, ICRTouch EPoS, Caterbook, Dext |
| 2 | Atlantic Road Estates Limited | Company — property/ATM | Xero org 2, RBS business |
| 3 | Personal | Individual finances, health, family | NatWest personal |
| 4 | Family | 3 children (ages 8, 10, 16), school, medical | School, NHS, activities |

**The Olde Malthouse** — pub, restaurant, inn, ice cream shop. Tintagel, North Cornwall. EPoS: ICRTouch/TouchOffice Web (touchoffice.net). Accommodation: Caterbook. Wholesale: St Austell Brewery.

**Source of truth hierarchy** — system DB is a mirror and enrichment layer only:
```
Bank statements  →  transaction truth
Xero             →  accounting truth
Email PDF        →  invoice truth (extracted via pdfplumber + Haiku)
Dext             →  manual review tool only (no API integration)
ICRTouch         →  EPoS sales truth
Caterbook        →  accommodation truth
System DB        →  mirror + derived data + reconciliation flags
```

## 1.2 Design Principles

1. **Events are truth.** Everything enters as an event. Nothing bypasses the event store.
2. **Pipelines are reliability.** All processing is deterministic, idempotent, and independently testable.
3. **AI is enrichment, not logic.** AI workers take input and return structured output. They never control routing or write to the database directly.
4. **Security is the foundation.** Every input is validated. Every AI call is sandboxed. Every secret is rotated. Every action is audited.
5. **Reliable before intelligent.** Correct and slow beats incorrect and fast.
6. **Xero is never written to automatically.** All financial actions require confirmation.
7. **Dext stays live as a manual review tool.** No API integration — Dext does not expose a public API. Run the internal extraction pipeline (pdfplumber/MarkItDown + Haiku) in parallel for 60+ days and compare outputs manually to validate extraction accuracy.
8. **Idempotent.** All pipeline runs are safe to repeat. Duplicate events produce no duplicate records.
9. **Fail philosophy is explicit.** Every pipeline has a declared fail-open or fail-closed mode (see Section 4.6).

## 1.3 Hardware

| Component | Spec | Role |
|---|---|---|
| CPU | AMD Threadripper PRO 5945WX (12c/24t) | Pipeline processing |
| RAM | 128 GB DDR4 ECC | Databases, inference |
| Storage — OS/DB | 1 TB NVMe SSD | Ubuntu, Docker volumes, PostgreSQL |
| Storage — archive | 4 TB HDD | Email archive, documents, photos |
| GPU | NVIDIA RTX 3060 12 GB | Ollama local inference |
| OS | Ubuntu 22.04 LTS | Base system |
| Backup — local | WD MyCloud NAS | Restic nightly |
| Backup — cloud | OneDrive 1 TB | Restic weekly |

## 1.4 Technology Stack

| Service | Image | Role |
|---|---|---|
| n8n | `n8nio/n8n:latest` | Pipeline orchestration, scheduling |
| PostgreSQL | `postgres:16` | Event store + all structured data |
| Qdrant | `qdrant/qdrant:latest` | Vector store for RAG (Phase 3+) |
| Redis | `redis:7-alpine` | Cache, queuing |
| Metabase | `metabase/metabase:latest` | Phase 1–2 dashboards |
| Ollama | `ollama/ollama:latest` | Local LLM (GPU-accelerated) |
| HashiCorp Vault | `hashicorp/vault:latest` | Secrets management |
| Authelia | `authelia/authelia:latest` | SSO authentication |
| Grafana | `grafana/grafana:latest` | Monitoring dashboards |
| Prometheus | `prom/prometheus:latest` | Metrics |
| Netdata | `netdata/netdata:latest` | Real-time system health |
| pdfplumber service | Custom FastAPI | PDF/XLSX/CSV extraction (table-heavy PDFs) |
| MarkItDown service | Custom FastAPI (Microsoft MarkItDown) | Audio, images, Word, YouTube → markdown (Phase 3) |
| vault-mcp service | Custom FastAPI | Obsidian vault MCP tools for Claude.ai (Phase 3) |
| Garmin service | Custom FastAPI | Garmin Connect data (Phase 2) |
| Playwright service | Custom FastAPI | Browser automation (Phase 3) |
| Baileys bridge | Custom Node.js | WhatsApp read-only (Phase 4) |

**LLM Cascade:**

| Tier | Model | Use cases | Cost |
|---|---|---|---|
| Local | Ollama `llama3.3:70b` | Email classification, simple extraction | Free |
| Haiku | `claude-haiku-4-5-20251001` | Invoice extraction, report parsing, nanny classification | ~$0.80/1M |
| Sonnet | `claude-sonnet-4-6` | Reconciliation analysis, cashflow, digest composition | ~$3/1M |
| Opus | `claude-opus-4-6` | Legal review, high-consequence financial decisions | ~$15/1M |

Target: ≤ £20/month API spend. Route aggressively to local. Escalate only on validation failure.

---

# PART 2: SECURITY ARCHITECTURE

**Read this section before writing any code.** Security is the foundation — it cannot be retrofitted.

## 2.1 Secret Management — HashiCorp Vault

**Rule: No secret ever exists outside Vault.** No .env files with secrets. No hardcoded values. No n8n credential store.

**All secrets at these Vault paths:**
```
secret/gmail/account1          { oauth_client_id, oauth_client_secret, refresh_token }
secret/gmail/account2          { oauth_client_id, oauth_client_secret, refresh_token }
secret/xero/trading            { client_id, client_secret, refresh_token, org_id }
secret/xero/estates            { client_id, client_secret, refresh_token, org_id }
secret/natwest/openbanking     { client_id, client_secret, access_token, consent_id }
secret/rbs/openbanking         { client_id, client_secret, access_token, consent_id }
secret/garmin                  { email, password }
secret/telegram                { bot_token, chat_id }
secret/github                  { personal_access_token }
secret/google/calendar         { oauth_client_id, oauth_client_secret, refresh_token }
secret/google/sheets           { oauth_client_id, oauth_client_secret, refresh_token }
secret/google/drive            { oauth_client_id, oauth_client_secret, refresh_token }
secret/anthropic               { api_key }
secret/postgres                { host, port, database, username, password }
secret/signing                 { payload_hmac_key }
secret/encryption              { aes_key }
```

**n8n Vault fetch pattern (use in every workflow needing a secret):**
```
HTTP Request Node:
  Method: GET
  URL: http://vault:8200/v1/secret/data/{{secret_path}}
  Headers: X-Vault-Token: {{$env.VAULT_N8N_TOKEN}}
  Output field: data.data.{{field_name}}
```

**Vault policy for n8n (least privilege) — file: security/vault-policies/n8n-policy.hcl:**
```hcl
path "secret/data/gmail/*"    { capabilities = ["read"] }
path "secret/data/xero/*"     { capabilities = ["read"] }
path "secret/data/anthropic"  { capabilities = ["read"] }
path "secret/data/postgres"   { capabilities = ["read"] }
path "secret/data/telegram"   { capabilities = ["read"] }
path "secret/data/google/*"   { capabilities = ["read"] }
path "secret/data/signing"    { capabilities = ["read"] }
# n8n cannot access: garmin, encryption, admin paths
```

**Secret rotation schedule:**

| Type | Frequency | Method |
|---|---|---|
| OAuth refresh tokens | On expiry (auto) | Token refresh flow |
| API keys | Quarterly | Manual + Vault update |
| HMAC signing key | Monthly | Vault rotate + pipeline restart |
| PostgreSQL password | Quarterly | Vault + Docker update |

## 2.2 Payload Integrity — HMAC Signing

Every event written to the `events` table is HMAC-SHA256 signed. Prevents tampering with historical events.

**Signing Code Node (n8n — runs before every events INSERT):**
```javascript
const hmacKey = $('Vault-Fetch-Signing').first().json.data.data.payload_hmac_key;
const payload = $input.first().json;
const canonical = JSON.stringify(payload, Object.keys(payload).sort());
const crypto = require('crypto');
const signature = crypto.createHmac('sha256', hmacKey)
  .update(canonical).digest('hex');
return [{ json: { ...payload, payload_signature: signature } }];
```

**Verify before replay (Python — used in microservices):**
```python
import hmac, hashlib, json

def verify_payload(payload: dict, signature: str, key: str) -> bool:
    canonical = json.dumps(payload, sort_keys=True, separators=(',', ':'))
    expected = hmac.new(key.encode(), canonical.encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)
```

Events with invalid signatures go directly to dead_letter with flag: SIGNATURE_MISMATCH.

## 2.3 Database Security — Row Level Security

All entity-scoped tables use RLS. Pipelines set `app.current_entity` at connection time. Full SQL in Section 3.3 (rls-policies.sql).

**Database roles:**
- `homeai_pipeline` — used by n8n and most pipelines (SELECT, INSERT, UPDATE)
- `homeai_hr` — used by HR pipeline only (staff, holiday, training tables)
- `homeai_readonly` — used by Metabase (SELECT only)

**n8n entity context pattern (prepend to every PostgreSQL query):**
```sql
SET LOCAL app.current_entity = '{{entityId}}';
-- Then run the actual query
```

## 2.4 Prompt Injection Protection

All external content (email bodies, invoice text, document extracts) must be sanitised before passing to any AI model.

**Sanitise function — n8n Code Node (run before EVERY AI worker call):**
```javascript
function sanitiseForPrompt(rawText) {
  if (!rawText || typeof rawText !== 'string') return '';
  let clean = rawText.replace(/<[^>]*>/g, ' ');
  const patterns = [
    /ignore\s+(all\s+)?previous\s+instructions?/gi,
    /forget\s+(all\s+)?instructions?/gi,
    /you\s+are\s+now\s+/gi,
    /new\s+instructions?:/gi,
    /system\s*:/gi,
    /\[INST\]/gi, /\[\/INST\]/gi,
    /<\|im_start\|>/gi, /<\|im_end\|>/gi,
    /###\s*instruction/gi,
    /act\s+as\s+/gi,
    /pretend\s+(you\s+are|to\s+be)\s+/gi,
    /override\s+(the\s+)?system/gi,
    /jailbreak/gi,
  ];
  patterns.forEach(p => { clean = clean.replace(p, '[REDACTED]'); });
  clean = clean.substring(0, 2000);
  clean = clean.replace(/\s+/g, ' ').trim();
  return clean;
}
const raw = $input.first().json.body_text || '';
return [{ json: { ...($input.first().json), body_text_safe: sanitiseForPrompt(raw) } }];
```

**Rules:**
- Always use `body_text_safe` in AI prompts — never `body_text`
- System prompt is always separate from user content
- All AI output is parsed as JSON before any action
- Log raw AI response to `audit_log.ai_raw_output` for security review
- If JSON parse fails → flag as `needs_review`, do not retry with same prompt

**Output validation (run after every AI worker call):**
```javascript
function validateAIOutput(raw, requiredFields, numericFields = []) {
  let parsed;
  try {
    const cleaned = raw.replace(/```json\n?/g,'').replace(/```\n?/g,'').trim();
    parsed = JSON.parse(cleaned);
  } catch(e) { throw new Error(`AI output not valid JSON: ${e.message}`); }
  for (const f of requiredFields) {
    if (!(f in parsed)) throw new Error(`Missing required field: ${f}`);
  }
  if (typeof parsed.confidence_score !== 'undefined') {
    if (typeof parsed.confidence_score !== 'number' ||
        parsed.confidence_score < 0 || parsed.confidence_score > 1)
      throw new Error('confidence_score must be float 0.0–1.0');
  }
  for (const f of numericFields) {
    if (parsed.data?.[f] != null && typeof parsed.data[f] !== 'number')
      throw new Error(`Field ${f} must be numeric`);
    if (parsed.data?.[f] > 1000000 || parsed.data?.[f] < 0)
      throw new Error(`Field ${f} out of expected range`);
  }
  return parsed;
}
```

## 2.5 Network Security

**Docker networks (three isolated networks):**
```yaml
networks:
  ai-internal:    # Core services — no external routing
    driver: bridge
    internal: true
  ai-services:    # Microservices that need Vault access
    driver: bridge
    internal: true
  ai-monitoring:  # Prometheus, Grafana
    driver: bridge
```

**UFW firewall rules (run immediately after Ubuntu install):**
```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 100.64.0.0/10 to any  # Tailscale CGNAT only
sudo ufw enable
```

**Exposed services — all behind Tailscale + Authelia SSO:**

| Service | Port | Auth |
|---|---|---|
| n8n | 5678 | Authelia SSO |
| Metabase | 3000 | Authelia SSO |
| Grafana | 3001 | Authelia SSO |
| Vault UI | 8200 | Authelia SSO |
| PostgreSQL | 5432 | Internal only — never exposed |
| Ollama | 11434 | Internal only — never exposed |

## 2.6 Security Audit Log

Append-only table (no UPDATE or DELETE permissions). Captures: secret access, auth failures, injection attempts, signature mismatches, dead letters.

```sql
CREATE TABLE security_audit_log (
  id             BIGSERIAL PRIMARY KEY,
  event_time     TIMESTAMPTZ DEFAULT NOW(),
  event_type     TEXT NOT NULL,
  source_service TEXT,
  source_ip      TEXT,
  secret_path    TEXT,
  pipeline       TEXT,
  entity_id      INT,
  details        JSONB,
  severity       TEXT DEFAULT 'info'  -- info | warning | critical
);
REVOKE UPDATE, DELETE ON security_audit_log FROM ALL;
GRANT INSERT, SELECT ON security_audit_log TO homeai_pipeline;
GRANT INSERT, SELECT ON security_audit_log TO homeai_hr;
```

---

# PART 3: DATA ARCHITECTURE

## 3.1 Standardised AI Output Schema

All AI workers return this JSON structure. Non-conforming output is rejected.

```json
{
  "entity": "Trading | Estates | Personal | Family",
  "category": "worker-specific string",
  "confidence_score": 0.95,
  "data": { "field_1": "value", "field_2": null },
  "requires_human": false,
  "reasoning": "One sentence explanation",
  "worker": "email_classifier | invoice_extractor | report_parser | nanny_classifier | fitness_coach | digest_generator | reconciliation_explainer"
}
```

## 3.2 Complete Database Schema (init-db.sql)

```sql
-- ============================================================
-- HOME AI SYSTEM — PostgreSQL Schema v4.0
-- Run: psql -U postgres -d homeai -f init-db.sql
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ── ENTITIES ─────────────────────────────────────────────────
CREATE TABLE entities (
  id   SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT,
  xero_org_id TEXT
);

-- ── EVENT STORE (partitioned by month) ───────────────────────
CREATE TABLE events (
  id                    BIGSERIAL,
  event_type            TEXT NOT NULL,
  source                TEXT NOT NULL,
  entity_id             INT REFERENCES entities(id),
  payload               JSONB NOT NULL,
  payload_signature     TEXT NOT NULL,
  status                TEXT DEFAULT 'pending',
  trace_id              UUID NOT NULL DEFAULT gen_random_uuid(),
  parent_event_id       BIGINT,
  idempotency_key       TEXT,
  retry_count           INT DEFAULT 0,
  error_message         TEXT,
  pipeline_version      TEXT,
  processing_started_at TIMESTAMPTZ,
  processing_node_id    TEXT,
  created_at            TIMESTAMPTZ DEFAULT NOW(),
  processed_at          TIMESTAMPTZ,
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

CREATE INDEX idx_events_type_status   ON events (event_type, status);
CREATE INDEX idx_events_trace         ON events (trace_id);
CREATE INDEX idx_events_parent        ON events (parent_event_id);
CREATE INDEX idx_events_entity        ON events (entity_id, status);
CREATE INDEX idx_events_idempotency   ON events (idempotency_key)
  WHERE idempotency_key IS NOT NULL;
CREATE INDEX idx_events_processing    ON events (status, processing_started_at)
  WHERE status = 'processing';

-- Initial partitions (monthly partition workflow extends these)
CREATE TABLE events_2026_04 PARTITION OF events
  FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE events_2026_05 PARTITION OF events
  FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE events_2026_06 PARTITION OF events
  FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE events_overflow PARTITION OF events DEFAULT;

-- ── DEAD LETTER ───────────────────────────────────────────────
CREATE TABLE dead_letter (
  id               BIGSERIAL PRIMARY KEY,
  event_id         BIGINT,
  pipeline         TEXT NOT NULL,
  error_message    TEXT,
  payload          JSONB,
  retry_count      INT DEFAULT 3,
  created_at       TIMESTAMPTZ DEFAULT NOW(),
  resolved         BOOLEAN DEFAULT FALSE,
  resolved_at      TIMESTAMPTZ,
  resolution_notes TEXT
);

-- ── AUDIT LOG ─────────────────────────────────────────────────
CREATE TABLE audit_log (
  id               BIGSERIAL PRIMARY KEY,
  pipeline         TEXT NOT NULL,
  event_id         BIGINT,
  trace_id         UUID,
  action           TEXT NOT NULL,
  entity_id        INT REFERENCES entities(id),
  record_type      TEXT,
  record_id        BIGINT,
  ai_worker        TEXT,
  ai_model         TEXT,
  pipeline_version TEXT,
  ai_input_hash    TEXT,
  ai_raw_output    TEXT,
  ai_parsed        JSONB,
  result           TEXT,
  error_msg        TEXT,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_audit_pipeline ON audit_log (pipeline, created_at DESC);
CREATE INDEX idx_audit_result   ON audit_log (result, created_at DESC);

-- ── SECURITY AUDIT LOG (append-only) ─────────────────────────
CREATE TABLE security_audit_log (
  id             BIGSERIAL PRIMARY KEY,
  event_time     TIMESTAMPTZ DEFAULT NOW(),
  event_type     TEXT NOT NULL,
  source_service TEXT,
  source_ip      TEXT,
  secret_path    TEXT,
  pipeline       TEXT,
  entity_id      INT,
  details        JSONB,
  severity       TEXT DEFAULT 'info'
);

-- ── STATIC CONTEXT ────────────────────────────────────────────
CREATE TABLE static_context (
  key        TEXT PRIMARY KEY,
  entity_id  INT REFERENCES entities(id),
  value      JSONB NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION notify_context_change()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO events (event_type, source, entity_id, payload, status,
                      trace_id, idempotency_key)
  VALUES ('system.correction', 'static_context', NEW.entity_id,
          jsonb_build_object('key', NEW.key, 'old_value', OLD.value,
                             'new_value', NEW.value),
          'pending', gen_random_uuid(),
          'correction_' || NEW.key || '_' || extract(epoch from now())::text);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER static_context_change
  AFTER UPDATE ON static_context
  FOR EACH ROW EXECUTE FUNCTION notify_context_change();

-- ── EMAIL TABLES ──────────────────────────────────────────────
CREATE TABLE emails (
  id                BIGSERIAL PRIMARY KEY,
  gmail_message_id  TEXT UNIQUE NOT NULL,
  event_id          BIGINT,
  trace_id          UUID,
  account           TEXT NOT NULL,
  from_address      TEXT,
  from_name         TEXT,
  subject           TEXT,
  body_text         TEXT,
  body_text_safe    TEXT,
  received_at       TIMESTAMPTZ,
  classification    TEXT,
  confidence_score  DECIMAL(4,3),
  entity_id         INT REFERENCES entities(id),
  nanny_relevant    BOOLEAN DEFAULT FALSE,
  action_required   BOOLEAN DEFAULT FALSE,
  has_attachment    BOOLEAN DEFAULT FALSE,
  requires_human    BOOLEAN DEFAULT FALSE,
  processed         BOOLEAN DEFAULT FALSE
);

CREATE TABLE email_attachments (
  id             BIGSERIAL PRIMARY KEY,
  email_id       BIGINT REFERENCES emails(id),
  event_id       BIGINT,
  filename       TEXT,
  mime_type      TEXT,
  drive_url      TEXT,
  extracted_text TEXT,
  processed      BOOLEAN DEFAULT FALSE
);

-- ── INVOICE TABLES ────────────────────────────────────────────
CREATE TABLE invoices (
  id               BIGSERIAL PRIMARY KEY,
  idempotency_key  TEXT UNIQUE NOT NULL,
  event_id         BIGINT,
  trace_id         UUID,
  entity_id        INT REFERENCES entities(id),
  source           TEXT NOT NULL,
  supplier_name    TEXT,
  invoice_number   TEXT,
  invoice_date     DATE,
  due_date         DATE,
  gross_amount     DECIMAL(12,2),
  net_amount       DECIMAL(12,2),
  vat_amount       DECIMAL(12,2),
  currency         TEXT DEFAULT 'GBP',
  category         TEXT,
  status           TEXT DEFAULT 'pending',
  confidence_score DECIMAL(4,3),
  requires_human   BOOLEAN DEFAULT FALSE,
  anomaly_check    TEXT,
  anomaly_reason   TEXT,
  xero_invoice_id  TEXT,
  drive_url        TEXT,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE supplier_invoice_history (
  id            BIGSERIAL PRIMARY KEY,
  entity_id     INT REFERENCES entities(id),
  supplier_name TEXT NOT NULL,
  invoice_month DATE NOT NULL,
  avg_gross     DECIMAL(12,2),
  min_gross     DECIMAL(12,2),
  max_gross     DECIMAL(12,2),
  invoice_count INT DEFAULT 1,
  updated_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (entity_id, supplier_name, invoice_month)
);
CREATE INDEX idx_supplier_hist ON supplier_invoice_history (entity_id, supplier_name);

-- ── BANK TABLES ───────────────────────────────────────────────
CREATE TABLE bank_accounts (
  id             SERIAL PRIMARY KEY,
  entity_id      INT REFERENCES entities(id),
  bank_name      TEXT,
  account_name   TEXT,
  account_number TEXT,
  sort_code      TEXT,
  account_type   TEXT
);

CREATE TABLE bank_transactions (
  id                  BIGSERIAL PRIMARY KEY,
  idempotency_key     TEXT UNIQUE NOT NULL,
  event_id            BIGINT,
  trace_id            UUID,
  bank_account_id     INT REFERENCES bank_accounts(id),
  entity_id           INT REFERENCES entities(id),
  transaction_date    DATE,
  description         TEXT,
  amount              DECIMAL(12,2),
  balance             DECIMAL(12,2),
  reference           TEXT,
  xero_transaction_id TEXT,
  reconciled          BOOLEAN DEFAULT FALSE,
  source              TEXT
);

CREATE TABLE reconciliation_flags (
  id                   BIGSERIAL PRIMARY KEY,
  event_id             BIGINT,
  entity_id            INT REFERENCES entities(id),
  bank_transaction_id  BIGINT REFERENCES bank_transactions(id),
  xero_transaction_id  TEXT,
  flag_type            TEXT,
  description          TEXT,
  status               TEXT DEFAULT 'open',
  created_at           TIMESTAMPTZ DEFAULT NOW()
);

-- ── PUB TABLES ────────────────────────────────────────────────
CREATE TABLE epos_daily_reports (
  id                  BIGSERIAL PRIMARY KEY,
  idempotency_key     TEXT UNIQUE NOT NULL,
  event_id            BIGINT,
  report_date         DATE NOT NULL,
  session             TEXT,
  gross_sales         DECIMAL(12,2),
  net_sales           DECIMAL(12,2),
  vat                 DECIMAL(12,2),
  cash_total          DECIMAL(12,2),
  card_total          DECIMAL(12,2),
  covers              INT,
  transactions        INT,
  avg_transaction     DECIMAL(8,2),
  voids               DECIMAL(12,2),
  refunds             DECIMAL(12,2),
  gratuities          DECIMAL(12,2),
  food_sales          DECIMAL(12,2),
  drink_sales         DECIMAL(12,2),
  accommodation_sales DECIMAL(12,2),
  source_email_id     BIGINT REFERENCES emails(id),
  created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE till_reconciliation (
  id              BIGSERIAL PRIMARY KEY,
  idempotency_key TEXT UNIQUE NOT NULL,
  event_id        BIGINT,
  recon_date      DATE NOT NULL,
  session         TEXT,
  z_reading       DECIMAL(12,2),
  card_total      DECIMAL(12,2),
  float_returned  DECIMAL(12,2),
  cash_counted    DECIMAL(12,2),
  expected_cash   DECIMAL(12,2),
  variance        DECIMAL(12,2),
  variance_pct    DECIMAL(6,3),
  status          TEXT DEFAULT 'ok',
  staff_notes     TEXT,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE accommodation_daily_reports (
  id                    BIGSERIAL PRIMARY KEY,
  idempotency_key       TEXT UNIQUE NOT NULL,
  event_id              BIGINT,
  report_date           DATE NOT NULL,
  rooms_occupied        INT,
  total_rooms           INT,
  occupancy_pct         DECIMAL(5,2),
  arrivals              INT,
  departures            INT,
  room_revenue          DECIMAL(12,2),
  adr                   DECIMAL(10,2),
  revpar                DECIMAL(10,2),
  forward_7day_revenue  DECIMAL(12,2),
  forward_30day_revenue DECIMAL(12,2),
  source_email_id       BIGINT REFERENCES emails(id),
  created_at            TIMESTAMPTZ DEFAULT NOW()
);

-- ── PROPERTY TABLES ───────────────────────────────────────────
CREATE TABLE properties (
  id             SERIAL PRIMARY KEY,
  entity_id      INT REFERENCES entities(id),
  address_line1  TEXT,
  town           TEXT,
  postcode       TEXT,
  property_type  TEXT,
  purchase_date  DATE,
  purchase_price DECIMAL(12,2),
  current_value  DECIMAL(12,2)
);

CREATE TABLE tenancies (
  id            SERIAL PRIMARY KEY,
  property_id   INT REFERENCES properties(id),
  tenant_name   TEXT,
  tenant_email  TEXT,
  tenant_phone  TEXT,
  start_date    DATE,
  end_date      DATE,
  monthly_rent  DECIMAL(10,2),
  deposit       DECIMAL(10,2),
  status        TEXT DEFAULT 'active'
);

CREATE TABLE rent_payments (
  id                  BIGSERIAL PRIMARY KEY,
  tenancy_id          INT REFERENCES tenancies(id),
  event_id            BIGINT,
  expected_date       DATE,
  expected_amount     DECIMAL(10,2),
  received_date       DATE,
  received_amount     DECIMAL(10,2),
  bank_transaction_id BIGINT REFERENCES bank_transactions(id),
  status              TEXT DEFAULT 'pending'
);

CREATE TABLE property_compliance (
  id              BIGSERIAL PRIMARY KEY,
  property_id     INT REFERENCES properties(id),
  compliance_type TEXT,
  last_completed  DATE,
  expiry_date     DATE,
  document_id     BIGINT,
  status          TEXT DEFAULT 'current',
  alert_sent_90   BOOLEAN DEFAULT FALSE,
  alert_sent_60   BOOLEAN DEFAULT FALSE,
  alert_sent_30   BOOLEAN DEFAULT FALSE
);

-- ── FAMILY TABLES ─────────────────────────────────────────────
CREATE TABLE children (
  id                  SERIAL PRIMARY KEY,
  name                TEXT NOT NULL,
  date_of_birth       DATE,
  school_name         TEXT,
  school_email_domain TEXT,
  gp_name             TEXT,
  nhs_number          TEXT
);

CREATE TABLE child_events (
  id                BIGSERIAL PRIMARY KEY,
  idempotency_key   TEXT UNIQUE NOT NULL,
  event_id          BIGINT,
  trace_id          UUID,
  child_id          INT REFERENCES children(id),
  event_type        TEXT,
  event_date        DATE,
  deadline          DATE,
  urgency           INT DEFAULT 1,
  summary           TEXT,
  requires_human    BOOLEAN DEFAULT FALSE,
  source_email_id   BIGINT REFERENCES emails(id),
  calendar_event_id TEXT,
  status            TEXT DEFAULT 'pending'
);

CREATE TABLE medical_history (
  id              BIGSERIAL PRIMARY KEY,
  child_id        INT REFERENCES children(id),
  event_id        BIGINT,
  event_date      DATE,
  event_type      TEXT,
  practitioner    TEXT,
  notes           TEXT,
  source_email_id BIGINT REFERENCES emails(id)
);

-- ── HEALTH TABLES ─────────────────────────────────────────────
CREATE TABLE garmin_daily_summary (
  id                BIGSERIAL PRIMARY KEY,
  summary_date      DATE UNIQUE NOT NULL,
  steps             INT,
  active_calories   INT,
  body_battery_low  INT,
  body_battery_high INT,
  stress_avg        INT,
  hrv_weekly_avg    DECIMAL(6,2),
  resting_hr        INT
);

CREATE TABLE garmin_sleep (
  id                  BIGSERIAL PRIMARY KEY,
  sleep_date          DATE UNIQUE NOT NULL,
  total_sleep_seconds INT,
  deep_sleep_seconds  INT,
  rem_sleep_seconds   INT,
  sleep_score         INT,
  avg_hrv             DECIMAL(6,2)
);

CREATE TABLE garmin_body_metrics (
  id                  BIGSERIAL PRIMARY KEY,
  measure_date        DATE NOT NULL,
  weight_kg           DECIMAL(5,2),
  body_fat_pct        DECIMAL(5,2),
  muscle_mass_kg      DECIMAL(5,2),
  visceral_fat_rating INT
);

-- ── STAFF AND HR TABLES ───────────────────────────────────────
CREATE TABLE staff (
  id                      SERIAL PRIMARY KEY,
  entity_id               INT REFERENCES entities(id),
  first_name              TEXT NOT NULL,
  last_name               TEXT NOT NULL,
  ni_number               BYTEA,  -- pgp_sym_encrypt(ni_number, key)
  date_of_birth           DATE,
  address                 TEXT,
  email                   TEXT,
  phone                   TEXT,
  start_date              DATE,
  end_date                DATE,
  contract_type           TEXT,
  role                    TEXT,
  hourly_rate             DECIMAL(8,2),
  weekly_hours            DECIMAL(5,2),
  pay_frequency           TEXT DEFAULT 'weekly',
  right_to_work_type      TEXT,
  right_to_work_expiry    DATE,
  dbs_check_date          DATE,
  accommodation_deduction DECIMAL(8,2) DEFAULT 0,
  status                  TEXT DEFAULT 'active'
);

CREATE TABLE holiday_entitlement (
  id                 SERIAL PRIMARY KEY,
  staff_id           INT REFERENCES staff(id),
  holiday_year_start DATE,
  holiday_year_end   DATE,
  statutory_days     DECIMAL(5,2),
  contractual_days   DECIMAL(5,2),
  used_days          DECIMAL(5,2) DEFAULT 0,
  remaining_days     DECIMAL(5,2),
  accrual_method     TEXT DEFAULT 'fixed'
);

CREATE TABLE holiday_requests (
  id               BIGSERIAL PRIMARY KEY,
  staff_id         INT REFERENCES staff(id),
  requested_start  DATE,
  requested_end    DATE,
  days_requested   DECIMAL(5,2),
  status           TEXT DEFAULT 'pending',
  notes            TEXT,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE training_records (
  id             BIGSERIAL PRIMARY KEY,
  staff_id       INT REFERENCES staff(id),
  training_type  TEXT,
  mandatory      BOOLEAN DEFAULT TRUE,
  completed_date DATE,
  expiry_date    DATE,
  alert_sent_14  BOOLEAN DEFAULT FALSE,
  status         TEXT DEFAULT 'current'
);

-- ── DOCUMENT CONTROL ──────────────────────────────────────────
CREATE TABLE documents (
  id           BIGSERIAL PRIMARY KEY,
  entity_id    INT REFERENCES entities(id),
  category     TEXT,
  title        TEXT NOT NULL,
  version      TEXT DEFAULT '1.0',
  status       TEXT DEFAULT 'draft',
  owner        TEXT,
  drive_url    TEXT,
  review_date  DATE,
  expiry_date  DATE,
  access_level TEXT DEFAULT 'owner',
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  updated_at   TIMESTAMPTZ
);

CREATE TABLE document_versions (
  id           BIGSERIAL PRIMARY KEY,
  document_id  BIGINT REFERENCES documents(id),
  version      TEXT,
  drive_url    TEXT,
  changed_by   TEXT,
  change_notes TEXT,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

-- ── CASHFLOW ─────────────────────────────────────────────────
CREATE TABLE cashflow_forecast (
  id                 BIGSERIAL PRIMARY KEY,
  entity_id          INT REFERENCES entities(id),
  forecast_date      DATE NOT NULL,
  generated_at       TIMESTAMPTZ DEFAULT NOW(),
  opening_balance    DECIMAL(12,2),
  forecast_income    DECIMAL(12,2),
  forecast_expenses  DECIMAL(12,2),
  forecast_closing   DECIMAL(12,2),
  confirmed_income   DECIMAL(12,2),
  confirmed_expenses DECIMAL(12,2),
  period_days        INT DEFAULT 30
);

-- ── DIAGNOSTIC HISTORY (Phase 3) ──────────────────────────────
CREATE TABLE diagnostic_history (
  id           BIGSERIAL PRIMARY KEY,
  run_id       UUID NOT NULL DEFAULT gen_random_uuid(),
  test_id      TEXT NOT NULL,
  status       TEXT NOT NULL,
  value        TEXT,
  detail       TEXT,
  duration_ms  INT,
  fix_applied  BOOLEAN DEFAULT FALSE,
  fix_result   TEXT,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_diag_run  ON diagnostic_history (run_id);
CREATE INDEX idx_diag_test ON diagnostic_history (test_id, created_at DESC);

-- ── MODEL STACK EVALUATOR TABLES ─────────────────────────────
CREATE TABLE model_registry (
  id              SERIAL PRIMARY KEY,
  model_name      TEXT UNIQUE NOT NULL,
  family          TEXT,
  params_b        DECIMAL(6,1),
  quantization    TEXT DEFAULT 'Q4_K_M',
  vram_gb         DECIMAL(5,2),
  ram_gb          DECIMAL(5,1),
  installed       BOOLEAN DEFAULT FALSE,
  deployed_tier   TEXT,               -- hot | medium | heavy | null
  ollama_digest   TEXT,
  discovered_at   TIMESTAMPTZ DEFAULT NOW(),
  last_seen_in_registry TIMESTAMPTZ,
  notes           TEXT
);

CREATE TABLE benchmark_results (
  id              BIGSERIAL PRIMARY KEY,
  model_name      TEXT NOT NULL REFERENCES model_registry(model_name),
  run_id          UUID NOT NULL DEFAULT gen_random_uuid(),
  run_at          TIMESTAMPTZ DEFAULT NOW(),
  tier            TEXT NOT NULL,
  task_id         TEXT NOT NULL,
  score           DECIMAL(5,2),
  speed_tps       DECIMAL(8,2),
  latency_ms      INT,
  input_tokens    INT,
  output_tokens   INT,
  passed          BOOLEAN,
  raw_output      TEXT,
  error_message   TEXT,
  UNIQUE (model_name, run_id, task_id)
);
CREATE INDEX idx_bench_model ON benchmark_results (model_name, tier, run_at DESC);

CREATE TABLE model_scores (
  id              BIGSERIAL PRIMARY KEY,
  model_name      TEXT NOT NULL REFERENCES model_registry(model_name),
  scored_at       TIMESTAMPTZ DEFAULT NOW(),
  tier            TEXT NOT NULL,
  composite_score DECIMAL(5,2),
  accuracy_score  DECIMAL(5,2),
  speed_score     DECIMAL(5,2),
  format_score    DECIMAL(5,2),
  avg_speed_tps   DECIMAL(8,2),
  avg_latency_ms  INT,
  task_count      INT,
  UNIQUE (model_name, tier, (scored_at::DATE))
);

CREATE TABLE model_recommendations (
  id                BIGSERIAL PRIMARY KEY,
  generated_at      TIMESTAMPTZ DEFAULT NOW(),
  tier              TEXT NOT NULL,
  action            TEXT NOT NULL,     -- DEPLOY | PULL_AND_BENCH | KEEP | DOWNGRADE
  recommended_model TEXT REFERENCES model_registry(model_name),
  current_model     TEXT REFERENCES model_registry(model_name),
  composite_delta   DECIMAL(6,2),
  speed_delta_pct   DECIMAL(8,2),
  accuracy_delta_pct DECIMAL(6,2),
  reasoning         TEXT,
  confidence        DECIMAL(4,3),
  actioned          BOOLEAN DEFAULT FALSE,
  actioned_at       TIMESTAMPTZ,
  actioned_by       TEXT
);
CREATE INDEX idx_recs_active ON model_recommendations (tier, generated_at DESC)
  WHERE actioned = FALSE;

CREATE TABLE model_scan_log (
  id            BIGSERIAL PRIMARY KEY,
  scanned_at    TIMESTAMPTZ DEFAULT NOW(),
  models_found  INT,
  new_models    TEXT[],
  updated_models TEXT[],
  scan_source   TEXT DEFAULT 'ollama_library'
);

-- ── SEED DATA ─────────────────────────────────────────────────
INSERT INTO entities (id, name, type) VALUES
  (1, 'Atlantic Road Trading Ltd', 'company'),
  (2, 'Atlantic Road Estates Limited', 'company'),
  (3, 'Personal', 'personal'),
  (4, 'Family', 'family');
```

## 3.3 Row Level Security (rls-policies.sql)

```sql
-- Run after init-db.sql

ALTER TABLE events                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE emails                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoices                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE bank_transactions         ENABLE ROW LEVEL SECURITY;
ALTER TABLE epos_daily_reports        ENABLE ROW LEVEL SECURITY;
ALTER TABLE accommodation_daily_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE till_reconciliation       ENABLE ROW LEVEL SECURITY;
ALTER TABLE rent_payments             ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff                     ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE cashflow_forecast         ENABLE ROW LEVEL SECURITY;

-- Isolate by entity for all scoped tables
DO $$ DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['events','emails','invoices','bank_transactions',
    'epos_daily_reports','accommodation_daily_reports','till_reconciliation',
    'rent_payments','documents','cashflow_forecast']
  LOOP
    EXECUTE format('CREATE POLICY entity_isolation ON %I
      USING (entity_id = current_setting(''app.current_entity'', true)::int
             OR current_setting(''app.current_entity'', true) = ''all'')', t);
  END LOOP;
END $$;

CREATE POLICY entity_isolation ON staff
  USING (entity_id = current_setting('app.current_entity', true)::int
         OR current_setting('app.current_entity', true) = 'all');
CREATE POLICY hr_only ON staff USING (current_user = 'homeai_hr');

CREATE ROLE homeai_pipeline LOGIN PASSWORD 'REPLACE_VIA_VAULT';
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO homeai_pipeline;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO homeai_pipeline;

CREATE ROLE homeai_hr LOGIN PASSWORD 'REPLACE_VIA_VAULT';
GRANT SELECT, INSERT, UPDATE ON staff, holiday_entitlement, holiday_requests,
  training_records, audit_log, events, dead_letter TO homeai_hr;

CREATE ROLE homeai_readonly LOGIN PASSWORD 'REPLACE_VIA_VAULT';
GRANT SELECT ON ALL TABLES IN SCHEMA public TO homeai_readonly;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
REVOKE UPDATE, DELETE ON security_audit_log FROM ALL;
```

## 3.4 Static Context Seed Data (seed-data.sql)

```sql
INSERT INTO static_context (key, entity_id, value) VALUES

('pub.details', 1, '{
  "name": "The Olde Malthouse",
  "address": "Tintagel, North Cornwall",
  "epos": "ICRTouch/TouchOffice Web",
  "booking_system": "Caterbook",
  "supplier_primary": "St Austell Brewery"
}'),

('children.profiles', 4, '[
  {"id": 1, "age": 16, "school_type": "secondary"},
  {"id": 2, "age": 10, "school_type": "primary"},
  {"id": 3, "age": 8, "school_type": "primary"}
]'),

('email.routing', null, '{
  "touchoffice_domains": ["touchoffice.net", "icrtouch.com"],
  "caterbook_domains": ["caterbook.com"]
}'),

('holiday.rules', 1, '{
  "method": "statutory_pro_rata",
  "never_use": "12.07_percent_accrual",
  "statutory_minimum_weeks": 5.6,
  "full_time_days_including_bank_holidays": 28
}'),

('ai.thresholds', null, '{
  "email_classifier":       {"min_confidence": 0.80, "escalate_to": "haiku",  "on_failure": "needs_review"},
  "invoice_extractor":      {"min_confidence": 0.90, "escalate_to": "sonnet", "on_failure": "requires_human"},
  "nanny_classifier":       {"min_confidence": 0.85, "escalate_to": "haiku",  "on_failure": "requires_human"},
  "report_parser":          {"min_confidence": 0.70, "escalate_to": "haiku",  "on_failure": "unknown_type"},
  "reconciliation_explainer":{"min_confidence": 0.75, "escalate_to": null,    "on_failure": "flag_for_manual"}
}'),

('ai.anomaly', null, '{
  "invoice": {"multiplier_threshold": 3.0, "min_history_count": 3, "lookback_months": 6}
}'),

('pipeline.versions', null, '{
  "email_pipeline": "1.0", "invoice_pipeline": "1.0", "bank_pipeline": "1.0",
  "xero_pipeline": "1.0", "epos_pipeline": "1.0", "accommodation_pipeline": "1.0",
  "cashing_up_pipeline": "1.0", "nanny_pipeline": "1.0",
  "report_ingestion_pipeline": "1.0", "digest_pipeline": "1.0",
  "personal_trainer_pipeline": "1.0", "compliance_pipeline": "1.0",
  "hr_pipeline": "1.0", "property_pipeline": "1.0", "diagnostics_pipeline": "1.0"
}'),

('system.limits', null, '{
  "max_batch_events": 10, "processing_lease_minutes": 10,
  "stale_lease_check_minutes": 5, "dead_letter_review_hours": 24,
  "dead_letter_digest_threshold": 5, "api_spend_daily_alert_gbp": 15,
  "api_spend_monthly_target_gbp": 20
}'),

('cashing_up.rules', 1, '{
  "variance_amount_threshold_gbp": 5.00, "variance_pct_threshold": 0.5,
  "epos_wait_max_minutes": 180, "epos_retry_interval_minutes": 30
}'),

('model.tiers', null, '{
  "hot":    "qwen2.5:7b",
  "medium": "phi4:14b",
  "heavy":  "llama3.3:70b"
}')

ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
```

---

# PART 4: SYSTEM ARCHITECTURE

## 4.1 Data Flow

```
EVENT SOURCE → EVENT STORE (signed) → EVENT ROUTER (deterministic)
    → PIPELINE (idempotent, fail-declared) → AI WORKER (optional, stateless)
    → STORAGE (PostgreSQL) → EMIT NEW EVENTS → OUTPUT
```

## 4.2 Event Types

```
email.received          email.classified        invoice.detected
invoice.extracted       invoice.matched         invoice.unmatched
bank.transaction        bank.reconciled         bank.flagged
epos.report.received    epos.report.processed   accommodation.received
accommodation.processed cashing_up.entry        cashing_up.reconciled
cashing_up.flagged      xero.sync.scheduled     xero.sync.complete
document.received       document.classified     child.event.detected
child.event.processed   rent.expected           rent.received
rent.arrears            compliance.alert        health.sync.scheduled
health.sync.complete    digest.scheduled        digest.ready
system.error            system.dead_letter      system.correction
security.alert
```

## 4.3 Deterministic Event Router

The Master Router is an n8n workflow. It polls the events table every 30 seconds using `SELECT FOR UPDATE SKIP LOCKED`, claims a batch, and routes each event deterministically. No AI is involved in routing.

**Router query (PostgreSQL node — claims batch of 10):**
```sql
BEGIN;
UPDATE events
SET status = 'processing',
    processing_started_at = NOW(),
    processing_node_id = $1
WHERE id IN (
  SELECT id FROM events
  WHERE status = 'pending'
    AND created_at > NOW() - INTERVAL '7 days'
  ORDER BY created_at ASC
  LIMIT 10
  FOR UPDATE SKIP LOCKED
)
RETURNING id, event_type, source, entity_id, payload, trace_id,
          parent_event_id, idempotency_key, pipeline_version, created_at;
COMMIT;
```

**Routing rules (n8n Switch node — Code node logic):**
```javascript
const eventType = $input.first().json.event_type;
const payload   = $input.first().json.payload;

const touchOfficeDomains = ['touchoffice.net', 'icrtouch.com'];
const caterbookDomains   = ['caterbook.com'];

const routes = {
  'email.received': () => {
    if (touchOfficeDomains.some(d => payload.from_address?.includes(d))) return 'epos_pipeline';
    if (caterbookDomains.some(d => payload.from_address?.includes(d)))   return 'accommodation_pipeline';
    return 'email_pipeline';
  },
  'email.classified':       () => payload.classification === 'invoice' ? 'invoice_pipeline' : 'nanny_pipeline',
  'invoice.detected':       () => 'invoice_pipeline',
  'child.event.detected':   () => 'nanny_pipeline',
  'bank.transaction':       () => 'bank_pipeline',
  'bank.flagged':           () => 'reconciliation_pipeline',
  'epos.report.received':   () => 'epos_pipeline',
  'accommodation.received': () => 'accommodation_pipeline',
  'cashing_up.entry':       () => 'cashing_up_pipeline',
  'document.received':      () => 'report_ingestion_pipeline',
  'health.sync.scheduled':  () => 'personal_trainer_pipeline',
  'digest.scheduled':       () => 'digest_pipeline',
  'xero.sync.scheduled':    () => 'xero_pipeline',
  'compliance.check':       () => 'compliance_pipeline',
};

const route = routes[eventType];
return [{ json: { route: route ? route() : 'dead_letter', event_type: eventType } }];
```

**Global Kill Switch — system_state check:**

The Master Router checks `system_state` in `static_context` before claiming any events. When set to `'paused'`, no events are claimed and no pipelines run. This provides a single point of control to halt all processing — for recursive loop detection, security investigation, or manual intervention.

```javascript
// Add as FIRST Code node in Master Router workflow, before the batch claim query:
const stateResult = await db.fetchOne(
  "SELECT value FROM static_context WHERE key = 'system.state'"
);
const systemState = stateResult?.value?.state || 'running';

if (systemState === 'paused') {
  // Log to audit_log but do NOT claim events
  await db.execute(
    "INSERT INTO audit_log (pipeline, action, result) VALUES ('master_router', 'skipped_paused', 'success')"
  );
  return [{ json: { skipped: true, reason: 'system_paused' } }];
}
// Proceed to SELECT FOR UPDATE SKIP LOCKED batch claim...
```

Add to seed-data.sql:
```sql
INSERT INTO static_context (key, entity_id, value) VALUES
('system.state', null, '{"state": "running", "paused_at": null, "paused_reason": null}'),

('whatsapp.blacklist', null, '{
  "numbers": [],
  "mode": "store_raw_only",
  "note": "Add phone numbers in E.164 format (+447XXXXXXXXX). Content from blacklisted numbers is stored as a hash only — never passed to AI workers or included in any digest."
}')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
```

**Pause/resume n8n workflows (Workflow E — activate with Workflow D in Phase 1 Step 11):**
```
POST /webhook/system-control
Body: { "action": "pause" | "resume", "reason": string }
→ UPDATE static_context SET value = '{"state":"paused","paused_at":"...","paused_reason":"..."}' WHERE key='system.state'
→ INSERT security_audit_log (event_type='system_paused'|'system_resumed', severity='critical')
→ Telegram: "[!!] System PAUSED by command: {reason}" or "✓ System RESUMED"
```

**Slash commands (add to .claude/commands/):**

**pause-all.md:**
```markdown
---
name: pause-all
description: Immediately pause all pipeline processing via system_state in static_context
---
Run: curl -X POST http://n8n:5678/webhook/system-control -d '{"action":"pause","reason":"[STATE REASON]"}'
Confirm: SELECT value FROM static_context WHERE key='system.state';
Expected: {"state":"paused",...}
Alert will be sent to Telegram automatically.
```

**resume-all.md:**
```markdown
---
name: resume-all
description: Resume all pipeline processing after a pause
---
Before resuming, confirm: the root cause of the pause has been resolved.
Run: curl -X POST http://n8n:5678/webhook/system-control -d '{"action":"resume","reason":"[RESOLUTION]"}'
Confirm: SELECT value FROM static_context WHERE key='system.state';
Expected: {"state":"running",...}
```

**Recursive loop detection (add to Gmail Ingest pipeline):**

The most likely loop is the system sending an automated email that then gets ingested and triggers another automated response. Detect and break it:

```javascript
// Add to email_pipeline BEFORE classification — check if sender is self:
const SYSTEM_SENDER_DOMAINS = ['yourdomain.com']; // domain used by n8n to send digests
const fromAddress = $input.first().json.from_address || '';

if (SYSTEM_SENDER_DOMAINS.some(d => fromAddress.includes(d))) {
  // This email was sent BY the system — do not process, mark as self-sent
  return [{ json: {
    skip: true,
    reason: 'self_sent_email_loop_prevention',
    from: fromAddress
  }}];
}
// Proceed to normal classification...
```

**AI escalation (email_pipeline only):**
```
email_classifier (Ollama 70B)
  → confidence >= threshold → use result
  → confidence < threshold  → Claude Haiku escalation
                               → still ambiguous → status = 'needs_review', stop
```

## 4.4 Pipeline Design Rules

Every pipeline must be:
- **Deterministic:** Same input → same output
- **Idempotent:** Safe to run twice — enforced via UNIQUE idempotency_key
- **Fail-declared:** Explicit fail-open or fail-closed mode (see 4.6)
- **Event-emitting:** Emits new events on completion for downstream pipelines
- **Audit-logged:** Every action writes to audit_log with trace_id

**Shared pipeline template (every pipeline starts with this):**
```
1. [Fetch Signing Key from Vault]
2. [Check Idempotency] → if exists and processed: stop
3. [Sanitise Input] → body_text_safe
4. [Core Processing Steps]
5. [AI Worker if needed] → [Validate Output] → [Threshold Check]
6. [Sign Payload]
7. [Write to DB]
8. [Emit New Events]
9. [Write Audit Log]
10. [Error: retry / dead_letter / alert]
```

**Stale lease recovery workflow (separate n8n workflow, runs every 5 min):**
```sql
-- Reset stale leases (retry < 3)
UPDATE events SET status='pending', processing_started_at=NULL,
    processing_node_id=NULL, retry_count=retry_count+1
WHERE status='processing'
  AND processing_started_at < NOW()-INTERVAL '10 minutes'
  AND retry_count < 3;

-- Dead-letter stale leases (retry >= 3)
INSERT INTO dead_letter (event_id, pipeline, error_message, retry_count)
SELECT id, 'stale_lease_recovery',
       'Max retries exceeded — stale on node ' || processing_node_id, retry_count
FROM events
WHERE status='processing'
  AND processing_started_at < NOW()-INTERVAL '10 minutes'
  AND retry_count >= 3
ON CONFLICT DO NOTHING;

UPDATE events SET status='dead_letter'
WHERE status='processing'
  AND processing_started_at < NOW()-INTERVAL '10 minutes'
  AND retry_count >= 3;
```

## 4.5 Confidence Threshold Enforcement

Read thresholds from static_context (not hardcoded). This Code node runs after every AI worker call:

```javascript
const workerName = 'invoice_extractor'; // change per pipeline
const ctx = $('Fetch-Static-Context').first().json.value;
const thresholds = ctx['ai.thresholds'][workerName];
const aiOutput = $input.first().json;
const confidence = aiOutput.confidence_score || 0;

if (confidence < thresholds.min_confidence) {
  return [{ json: { ...aiOutput, requires_human: true,
    threshold_failure_reason:
      `Confidence ${confidence} below ${thresholds.min_confidence} for ${workerName}` } }];
}
return [{ json: aiOutput }];
```

## 4.6 Failure Philosophy

| Pipeline | Fail mode | On failure action |
|---|---|---|
| email_pipeline | **Fail open** | Classify as `fyi`, log, continue |
| invoice_pipeline | **Fail closed** | Dead letter + Telegram [!] — no partial record |
| bank_pipeline | **Fail closed** | Dead letter + Telegram [!] |
| xero_pipeline | **Fail closed** | Dead letter + Telegram [!] + mark downstream STALE |
| epos_pipeline | **Fail closed** | Dead letter + Telegram [!] — cashing_up waits |
| accommodation_pipeline | **Fail open** | Log gap, continue — next day recovers |
| cashing_up_pipeline | **Fail closed** | Wait up to 3h for EPoS data, then dead letter |
| nanny_pipeline | **Fail open** | Flag email as `requires_human`, include in digest |
| digest_pipeline | **Fail open** | Retry once, then minimal Telegram alert |
| report_ingestion | **Fail open** | Route to `needs_review` queue |
| reconciliation_pipeline | **Fail closed** | Dead letter — no partial results |
| personal_trainer_pipeline | **Fail open** | Log gap — alert only if 3+ consecutive days |
| hr_pipeline | **Fail closed** | Dead letter + Telegram [!] — compliance is legally significant |
| property_pipeline | **Fail closed** | Dead letter + Telegram [!] |
| compliance_pipeline | **Fail closed** | Dead letter + Telegram [!] |
| partition_creation | **Fail closed** | Telegram [!] immediately — missing partition → overflow |

**Retry policy (all pipelines):** Attempt 1 immediate → Attempt 2 after 1 min → Attempt 3 after 5 min → dead_letter + alert.

**Exception:** epos_pipeline and cashing_up_pipeline retry every 30 min for up to 3 hours.

**Alert fatigue rule:** Telegram alerts only for: dead letters, fail-closed failures, cashing up variances, security events, system health. Everything else goes in the digest.

**Dead letter flood detection:** Individual dead letters fire a per-event Telegram alert. A flood — ten or more dead letters from the same pipeline within a 60-minute rolling window — signals a systemic failure (API breaking change, Vault sealed, schema mismatch after a deploy) rather than an isolated data error. Individual errors need manual review; floods need the pipeline paused immediately before the queue grows further.

Two mechanisms enforce this.

**1. Prometheus alert (add to monitoring/prometheus-rules/alerts.yml):**

The custom metrics exporter (a FastAPI service Prometheus already scrapes for pipeline health) needs one additional route:

```python
# metrics-exporter/main.py — add this route
@app.get("/metrics/dead_letter_flood")
async def dead_letter_flood():
    rows = await db.fetch(
        """SELECT pipeline, COUNT(*) as count
           FROM dead_letter
           WHERE created_at > NOW() - INTERVAL '60 minutes'
             AND resolved = false
           GROUP BY pipeline
           HAVING COUNT(*) > 0"""
    )
    lines = [
        f'dead_letter_flood_count{{pipeline="{r["pipeline"]}"}} {r["count"]}'
        for r in rows
    ]
    return Response("\n".join(lines), media_type="text/plain")
```

Prometheus alert rule:

```yaml
- alert: DeadLetterFlood
  expr: dead_letter_flood_count > 10
  for: 0m
  labels:
    severity: critical
  annotations:
    summary: "Dead letter flood on {{ $labels.pipeline }} — {{ $value }} failures in 60 min"
    description: >
      Possible systemic failure: API breaking change, Vault sealed, or schema mismatch.
      Pipeline has been auto-paused. Fix root cause before reactivating in n8n UI.
```

**2. n8n auto-pause logic (add as extra Code node in Stale Lease Recovery workflow):**

```javascript
// Fetch per-pipeline thresholds from static_context
const ctx = await db.fetchOne(
  "SELECT value FROM static_context WHERE key = 'system.flood_thresholds'"
);
const thresholds = ctx.value;

const floodRows = await db.fetch(`
  SELECT pipeline, COUNT(*) as flood_count
  FROM dead_letter
  WHERE created_at > NOW() - INTERVAL '60 minutes'
    AND resolved = false
  GROUP BY pipeline
`);

for (const row of floodRows) {
  const limit = thresholds[row.pipeline] ?? thresholds.default;
  if (row.flood_count <= limit) continue;

  // Deactivate the pipeline via n8n API
  const res = await fetch(
    \`http://n8n:5678/api/v1/workflows?name=\${encodeURIComponent(row.pipeline)}\`,
    { headers: { "X-N8N-API-KEY": process.env.N8N_API_KEY } }
  );
  const { data } = await res.json();
  if (data.length > 0 && data[0].active) {
    await fetch(\`http://n8n:5678/api/v1/workflows/\${data[0].id}/deactivate\`, {
      method: "POST",
      headers: { "X-N8N-API-KEY": process.env.N8N_API_KEY }
    });
    await db.execute(
      \`INSERT INTO security_audit_log
         (event_type, source_service, pipeline, details, severity)
       VALUES ('pipeline_auto_paused', 'flood_detector', $1,
               jsonb_build_object('flood_count', $2, 'threshold', $3), 'critical')\`,
      [row.pipeline, row.flood_count, limit]
    );
    await sendTelegram(
      \`[!!] FLOOD: \${row.pipeline} auto-paused.\n\` +
      \`\${row.flood_count} dead letters in 60 min (threshold: \${limit}).\n\` +
      \`Fix root cause first. Reactivate manually in n8n UI. Do NOT replay until resolved.\`
    );
  }
}
```

**Reactivation is always manual.** Fix the root cause, reactivate in the n8n UI, then replay using the dead letter resolution procedure (Appendix F).

**Flood thresholds by pipeline (add to seed-data.sql):**

```sql
INSERT INTO static_context (key, entity_id, value) VALUES
('system.flood_thresholds', null, '{
  "default": 10,
  "email_pipeline": 20,
  "personal_trainer_pipeline": 5,
  "digest_pipeline": 3
}')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
```

Email pipeline threshold is higher (20) because Gmail API transient errors are common at volume. Digest and personal trainer thresholds are lower (3–5) — these run infrequently so any cluster of failures is anomalous.

## 4.7 The Continuous Verification Loop (Ralph Pattern)

The system currently tells you when things break (dead letter alerts, Prometheus, self-test suite). This section defines a step further: a continuous Ralph loop that notices failures, attempts safe auto-remediation, and only escalates what it cannot fix itself.

The distinction matters. A dead letter alert requires human diagnosis. A Ralph verification loop attempts the obvious fix first — restart a crashed container, reclaim a stale lease, re-validate a Vault token — and only pages you if the auto-fix fails. Over time it learns what is fixable automatically and what genuinely needs you.

**n8n Workflow G — Continuous Verification Loop (activate Phase 3):**

```
Schedule: every 30 minutes
↓
Run critical self-tests (subset — fast tests only, <2 min total):
  - Vault sealed check (GET /v1/sys/health)
  - PostgreSQL connection test (SELECT 1)
  - events_overflow count (must be 0)
  - Dead letter count in last 30 min (must be < flood threshold)
  - n8n last execution time (must be < 35 min ago)
  - Ollama hot tier responding (quick inference test)
↓
If ALL pass:
  INSERT audit_log (action='ralph_verify', result='pass')
  Sleep until next cycle — no alert

If ANY fail:
  Identify failure category → attempt safe auto-remediation:

  VAULT SEALED:
    → trigger vault-autounseal.sh via systemd
    → wait 90s, re-test
    → if still sealed: POST /webhook/system-control pause + Telegram [!!]

  EVENTS_OVERFLOW > 0:
    → identify missing partition month
    → run CREATE TABLE partition SQL (safe, idempotent)
    → re-test
    → if still > 0: Telegram [!] with months affected

  OLLAMA NOT RESPONDING:
    → docker compose restart ollama
    → wait 30s, re-test
    → if still down: Telegram [!!]

  DEAD LETTER FLOOD:
    → already handled by Workflow E per-pipeline auto-pause
    → this loop confirms pause is active, re-alerts if not

  N8N STALE (last execution > 35 min):
    → check if system_state = 'paused' (expected — no alert)
    → if running but stale: docker compose restart n8n
    → wait 60s, re-test
    → if still stale: Telegram [!!]

  POSTGRES DOWN:
    → docker compose restart postgres
    → wait 30s, re-test
    → if still down: Telegram [!!] CRITICAL — all pipelines halted

After any auto-remediation attempt:
  INSERT audit_log (action='ralph_autoheal', result='success|failed',
                    error_msg='what failed and what was tried')
  If remediation succeeded: Telegram "✓ Auto-healed: [issue] — no action needed"
  If remediation failed: Telegram "[!!] [issue] — auto-heal failed, manual required"
```

**Implementation principle — watch the loop:**

Geoffrey Huntley's Ralph pattern: *when you see a failure domain, resolve the problem so it never happens again.* Every time the verification loop triggers a Telegram alert, treat it as a signal to strengthen the auto-remediation. If Vault seals three times in a week, the auto-unseal script needs hardening. If the dead letter flood fires repeatedly on the same pipeline, the pipeline prompt needs updating. The loop's failure history in audit_log is your maintenance backlog.

**The loop is not a replacement for monitoring.** Grafana and Prometheus remain for trend analysis and slow-burn issues. The Ralph loop handles acute failures — things that are broken right now and have a known fix. The two systems complement each other: Prometheus tells you a pipeline's error rate has been climbing for three days; the Ralph loop catches the outright crash and restarts it at 3am before the morning digest fails.

---

# PART 5: DOCKER COMPOSE

## 5.1 Directory Structure

```
/home_ai/
├── SPEC.md                          ← This document (single source of truth)
├── AGENTS.md                        ← Claude Code core context (all agents read this)
├── CLAUDE.md                        ← One line: @AGENTS.md
├── CLAUDE.local.md                  ← P620-specific config (gitignored)
├── .gitignore                       ← Must include: CLAUDE.local.md *.env *secret*
├── .claude/
│   ├── commands/                    ← Slash commands (git-tracked)
│   │   ├── verify-phase1.md
│   │   ├── check-vault.md
│   │   ├── check-services.md
│   │   ├── replay-event.md
│   │   ├── check-partitions.md
│   │   ├── security-review.md
│   │   ├── pause-all.md             ← Global kill switch
│   │   ├── resume-all.md
│   │   ├── simplify.md              ← Strip over-engineering
│   │   ├── review.md                ← Claude self-review
│   │   └── retro.md                 ← End-of-session retro
│   ├── decisions/                   ← Architectural Decision Records (ADRs)
│   │   └── README.md
│   └── biography/                   ← Periodic status snapshots (git-tracked)
│       └── YYYY-MM-DD-biography.md
│   ├── skills/                      ← Domain knowledge (folders, not files)
│   │   ├── deploy-pipeline/
│   │   │   ├── SKILL.md             ← description + Gotchas section
│   │   │   └── examples/
│   │   ├── vault-secret/
│   │   │   └── SKILL.md
│   │   ├── add-partition/
│   │   │   └── SKILL.md
│   │   └── dead-letter-replay/
│   │       └── SKILL.md
│   └── agents/                      ← Subagent definitions
│       ├── db-agent.md              ← Database schema/migration specialist
│       ├── pipeline-agent.md        ← n8n workflow builder
│       ├── security-agent.md        ← Read-only security reviewer
│       └── playground-agent.md      ← Creative prototype builder (Phase 5)
├── docker-compose.yml
├── .env.public                      ← Non-secret config only (no secrets ever)
├── postgres/
│   ├── init-db.sql                  ← Section 3.2
│   ├── rls-policies.sql             ← Section 3.3
│   └── seed-data.sql                ← Section 3.4
├── services/
│   ├── garmin/
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── main.py
│   ├── postgres-mcp/                ← Phase 3: read-only Claude.ai MCP tools
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── main.py
│   ├── markitdown/                  ← Phase 3: multi-format → markdown
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── main.py
│   ├── vault-mcp/                   ← Phase 3: Obsidian vault MCP for Claude.ai
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── main.py
│   └── pdfplumber/
│       ├── Dockerfile
│       ├── requirements.txt
│       └── main.py
├── security/
│   ├── vault-policies/
│   │   ├── n8n-policy.hcl
│   │   └── services-policy.hcl
│   └── authelia/
│       └── configuration.yml
├── monitoring/
│   ├── prometheus.yml
│   └── prometheus-rules/
│       └── alerts.yml
├── storage/
│   ├── raw_emails/
│   ├── invoices/
│   ├── reports/
│   └── family_docs/
└── playground/                      ← Sandbox only — separate git repo
    ├── projects/                    ← One folder per prototype
    ├── assets/shared/               ← Brand assets, images
    └── deployments.log              ← All deploy URLs
```

## 5.2 docker-compose.yml

```yaml
version: "3.9"

networks:
  ai-internal:
    driver: bridge
    internal: true
  ai-services:
    driver: bridge
    internal: true
  ai-monitoring:
    driver: bridge

services:

  postgres:
    image: postgres:16
    container_name: homeai-postgres
    networks: [ai-internal]
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./postgres/init-db.sql:/docker-entrypoint-initdb.d/01-init.sql
      - ./postgres/rls-policies.sql:/docker-entrypoint-initdb.d/02-rls.sql
      - ./postgres/seed-data.sql:/docker-entrypoint-initdb.d/03-seed.sql
    environment:
      POSTGRES_DB: homeai
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
    secrets: [postgres_password]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d homeai"]
      interval: 10s
      retries: 5
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    container_name: homeai-redis
    networks: [ai-internal]
    command: redis-server --requirepass "${REDIS_PASSWORD}"
    restart: unless-stopped

  qdrant:
    image: qdrant/qdrant:latest
    container_name: homeai-qdrant
    networks: [ai-internal]
    volumes: [qdrant_data:/qdrant/storage]
    restart: unless-stopped

  vault:
    image: hashicorp/vault:latest
    container_name: homeai-vault
    networks: [ai-internal, ai-services]
    cap_add: [IPC_LOCK]
    volumes:
      - vault_data:/vault/data
      - ./security/vault-policies:/vault/policies
    environment:
      VAULT_ADDR: "http://0.0.0.0:8200"
    ports: ["8200:8200"]
    restart: unless-stopped

  n8n:
    image: n8nio/n8n:latest
    container_name: homeai-n8n
    networks: [ai-internal, ai-services]
    volumes:
      - n8n_data:/home/node/.n8n
      - ./storage:/data/storage
    environment:
      N8N_HOST: "0.0.0.0"
      N8N_PORT: "5678"
      DB_TYPE: "postgresdb"
      DB_POSTGRESDB_HOST: "postgres"
      DB_POSTGRESDB_DATABASE: "homeai"
      DB_POSTGRESDB_USER: "homeai_pipeline"
      DB_POSTGRESDB_PASSWORD: "${N8N_DB_PASSWORD}"
      VAULT_ADDR: "http://vault:8200"
      VAULT_TOKEN: "${VAULT_N8N_TOKEN}"
      EXECUTIONS_DATA_SAVE_ON_SUCCESS: "all"
      EXECUTIONS_DATA_SAVE_ON_ERROR: "all"
    depends_on:
      postgres: {condition: service_healthy}
    ports: ["5678:5678"]
    restart: unless-stopped

  ollama:
    image: ollama/ollama:latest
    container_name: homeai-ollama
    networks: [ai-internal]
    volumes: [ollama_data:/root/.ollama]
    deploy:
      resources:
        reservations:
          devices: [{driver: nvidia, count: 1, capabilities: [gpu]}]
    restart: unless-stopped

  metabase:
    image: metabase/metabase:latest
    container_name: homeai-metabase
    networks: [ai-internal]
    environment:
      MB_DB_TYPE: postgres
      MB_DB_HOST: postgres
      MB_DB_PORT: "5432"
      MB_DB_DBNAME: homeai
      MB_DB_USER: homeai_readonly
      MB_DB_PASS: "${METABASE_DB_PASSWORD}"
    depends_on:
      postgres: {condition: service_healthy}
    ports: ["3000:3000"]
    restart: unless-stopped

  authelia:
    image: authelia/authelia:latest
    container_name: homeai-authelia
    networks: [ai-services]
    volumes: [./security/authelia:/config]
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: homeai-grafana
    networks: [ai-monitoring]
    volumes:
      - grafana_data:/var/lib/grafana
    environment:
      GF_SECURITY_ADMIN_PASSWORD: "${GRAFANA_ADMIN_PASSWORD}"
      GF_USERS_ALLOW_SIGN_UP: "false"
    depends_on: [prometheus]
    ports: ["3001:3000"]
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:latest
    container_name: homeai-prometheus
    networks: [ai-monitoring, ai-internal]
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml
      - ./monitoring/prometheus-rules:/etc/prometheus/rules
    restart: unless-stopped

  netdata:
    image: netdata/netdata:latest
    container_name: homeai-netdata
    pid: host
    network_mode: host
    cap_add: [SYS_PTRACE]
    security_opt: [apparmor:unconfined]
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    restart: unless-stopped

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: homeai-open-webui
    networks: [ai-internal]
    volumes: [open_webui_data:/app/backend/data]
    environment:
      OLLAMA_BASE_URL: "http://ollama:11434"
      WEBUI_SECRET_KEY: "${OPEN_WEBUI_SECRET}"
      ENABLE_SIGNUP: "false"
      DEFAULT_USER_ROLE: "admin"
    depends_on: [ollama]
    ports: ["8080:8080"]
    restart: unless-stopped

  pdfplumber-service:
    build: ./services/pdfplumber
    container_name: homeai-pdfplumber
    networks: [ai-internal]
    ports: ["8003:8003"]
    restart: unless-stopped

  garmin-service:
    build: ./services/garmin
    container_name: homeai-garmin
    networks: [ai-internal, ai-services]
    environment:
      VAULT_ADDR: "http://vault:8200"
      VAULT_TOKEN: "${VAULT_SERVICES_TOKEN}"
    ports: ["8002:8002"]
    profiles: ["phase2"]
    restart: unless-stopped

  markitdown-service:
    build: ./services/markitdown
    container_name: homeai-markitdown
    networks: [ai-internal]
    ports: ["8006:8006"]
    profiles: ["phase3"]
    restart: unless-stopped

  vault-mcp:
    build: ./services/vault-mcp
    container_name: homeai-vault-mcp
    networks: [ai-internal, ai-services]
    volumes:
      - /mnt/ssd/obsidian-vault:/vault:ro
    environment:
      VAULT_PATH: "/vault"
    ports: ["8007:8007"]
    profiles: ["phase3"]
    restart: unless-stopped

  playwright-service:
    build: ./services/playwright
    container_name: homeai-playwright
    networks: [ai-internal, ai-services]
    ports: ["8001:8001"]
    profiles: ["phase3"]
    restart: unless-stopped

  model-evaluator:
    build: ./services/model-evaluator
    container_name: homeai-model-evaluator
    networks: [ai-internal]
    environment:
      OLLAMA_URL: "http://ollama:11434"
      DATABASE_URL: "postgresql://homeai_pipeline:${DB_PASSWORD}@postgres:5432/homeai"
    ports: ["8080:8080"]
    depends_on:
      postgres: {condition: service_healthy}
    restart: unless-stopped

  baileys-bridge:
    build: ./services/whatsapp
    container_name: homeai-whatsapp
    networks: [ai-internal]
    volumes: [baileys_auth:/app/auth]
    ports: ["8004:8004"]
    profiles: ["phase4"]
    restart: unless-stopped

secrets:
  postgres_password:
    external: true

volumes:
  postgres_data:
  qdrant_data:
  n8n_data:
  ollama_data:
  vault_data:
  grafana_data:
  open_webui_data:
  baileys_auth:
```

---

# PART 6: PHASE 1 BUILD — Weeks 1–6

## 6.1 Goal and Deliverables

**Goal:** A provably working event-driven backbone with all core pipelines running and validated against real data.

**Build philosophy — three gated milestones, not one long phase:**

Phase 1 is three distinct things that must be proven in sequence. Do not proceed from one milestone to the next until the gate test passes. A gate test is not optional — it is the proof that the foundation is solid enough to build on.

```
MILESTONE A — Platform Foundation
  Vault, PostgreSQL, one test event round-trips the system
  Gate: until this passes, nothing else is started

MILESTONE B — First Vertical Slice
  One real email received → classified → DB written → visible in Metabase
  Gate: until this passes, no additional pipelines are built

MILESTONE C — Full Pipeline Build
  All pipelines, full monitoring, backup
  Gate: full Phase 1 testing checklist
```

**Why this matters:** You can spend two days building a highly "complete" foundation and still not know whether the system works. The milestones ensure every hour of build time produces a provably working system, not a documented one.

**Deliverables — Milestone A:**
- P620 running Ubuntu 22.04 LTS + Docker + Tailscale + firewall
- HashiCorp Vault unsealed with all Phase 1 secrets loaded (manual unseal)
- PostgreSQL schema, RLS policies, and seed data applied
- One test event round-trips: INSERT → events table → correct partition → no overflow

**Deliverables — Milestone B:**
- Ollama hot tier model (qwen2.5:7b, 4.4GB) installed and responding
- pdfplumber microservice running
- n8n Master Router processing events
- Gmail Ingest pipeline (Pipeline 1 only)
- Metabase connected showing events table and email review queue
- One real email: received → classified → written to emails table → visible in Metabase

**Deliverables — Milestone C:**
- All Ollama models (phi4:14b, llama3.3:70b) installed, all three tiers deployed
- Model stack evaluator running (tier deployment, no benchmarks yet)
- All 13 Phase 1 pipelines built and tested
- Open WebUI accessible at Tailscale IP:8088
- Full Metabase dashboard (financial, pub, rent panels)
- Grafana + Prometheus + Netdata monitoring
- Restic backup (WD MyCloud nightly, OneDrive weekly)
- Full Phase 1 testing checklist passed

**Deferred to Phase 2 hardening (not Phase 1):**
- Vault auto-unseal (vault-autounseal.sh + systemd service) — Phase 1 uses manual unseal
- Authelia SSO — Tailscale provides sufficient access control during the build phase
- Model evaluator benchmark runs — meaningful only after real pipeline data exists

**Manual prerequisites (complete before starting):**
1. Configure TouchOffice admin to email daily Z-report to a monitored Gmail address
2. Configure Caterbook admin to email daily report to the same or another monitored Gmail
3. Create Google Sheet for cashing up (columns A–J as per Appendix C)
4. Create Anthropic API key at console.anthropic.com

## 6.2 Phase 1 Pipeline Specifications

### Pipeline Construction Rules — Outcome-Native Pattern

Every pipeline built in Milestone C must implement the OutcomeObject pattern.
This eliminates non-deterministic stopping conditions — the pipeline does not exit
an AI processing step until it has a validated outcome, not just a response.

**The OutcomeObject (required return from every AI worker Code node):**

```javascript
// Standard structure — every AI worker Code node must return this shape
const outcome = {
  status: "success" | "escalate" | "fail",
  confidence: float,        // 0.0–1.0
  reasoning: string,        // always populated — never blank
  data: object,             // extracted fields for this worker
  requires_human: boolean,
  worker: string,           // e.g. "email_classifier"
  tier_used: string         // "hot" | "medium" | "heavy" | "haiku" | "sonnet"
};
```

**Retry/escalation rule (implement in every AI pipeline — add as Code node after Ollama response):**

```javascript
// Outcome Evaluator Code node — runs after every Ollama response
const response = $input.first().json;
const thresholds = $('Fetch-Static-Context').first().json.value['ai.thresholds'];
const worker = response.worker || 'unknown';
const threshold = thresholds[worker]?.min_confidence || 0.85;
const confidence = parseFloat(response.confidence_score || 0);

if (confidence >= threshold) {
  // Outcome: success — proceed to write
  return [{ json: { ...response, status: 'success', tier_used: 'hot' } }];
}

if (confidence >= threshold * 0.85) {
  // Outcome: escalate — retry with medium tier before human review
  // Next node: HTTP Request to medium tier model (phi4:14b / qwen3:14b)
  return [{ json: { ...response, status: 'escalate', tier_used: 'hot',
    escalation_reason: `confidence ${confidence} below threshold ${threshold}` } }];
}

// Outcome: fail — flag for human review without escalation
return [{ json: { ...response, status: 'fail', requires_human: true,
  tier_used: 'hot', reasoning: response.reasoning || 'Low confidence — flagged for review' } }];
```

**Escalation routing (Master Router addition — handle `status: "escalate"`):**

```javascript
// After hot tier escalate outcome: retry with medium tier
// Medium tier endpoint: same Ollama API, model from static_context model.tiers.medium
const mediumModel = $('Fetch-Static-Context').first().json.value['model.tiers']?.medium
                    || 'qwen3:14b';

// Re-run same prompt against medium tier
// If medium tier still returns confidence < threshold: status='fail', requires_human=true
// Do NOT escalate to heavy tier for standard pipelines — too slow for batch processing
// Exception: reconciliation_explainer and digest_generator may use heavy tier
```

**Dreaming heuristic file (used by Master Router on each run — Phase 2):**

The Master Router reads `/home_ai/.claude/dreaming/heuristics.md` at session start.
This file is maintained by the nightly Dreaming workflow (Section 7.2 Phase 2).
It contains patterns learned from this week's audit_log failures — specific supplier
formats that trip up the invoice_extractor, email patterns that fool the classifier.

```javascript
// Master Router Code node — read heuristics into context at start of each batch
// (Phase 2 addition — Phase 1 the file may not exist yet, skip gracefully)
const fs = require('fs');
const heuristicsPath = '/home_ai/.claude/dreaming/heuristics.md';
let heuristics = '';
try {
  heuristics = fs.existsSync(heuristicsPath)
    ? fs.readFileSync(heuristicsPath, 'utf8').slice(0, 2000) // cap at 2k chars
    : '';
} catch (e) { heuristics = ''; }
// Append to system prompts for AI workers when heuristics exist
```

**Audit log requirement:** Every pipeline must write to `audit_log` with:
- `ai_worker`, `result` (success/escalate/fail), `ai_parsed` (full OutcomeObject as JSONB)
- `tier_used` — which model tier was ultimately used
- `confidence_score` — for drift alerting (Section 7.2)

---

### Pipeline 1 — Gmail Ingest

**Trigger:** Gmail Trigger (15-min poll, all Gmail accounts)
**Idempotency key:** `email_{gmail_message_id}`
**Fail mode:** Fail open

**n8n node sequence:**
1. Gmail Trigger → raw email object
2. Code Node: check events table for idempotency_key — if processed, stop
3. Code Node: `sanitiseForPrompt(body_text)` → `body_text_safe`
4. HTTP Request → Vault → get signing key + Anthropic key
5. HTTP Request → Ollama `http://ollama:11434/api/generate` with email_classifier prompt
6. Code Node: parse JSON, check confidence vs `ai.thresholds.email_classifier`
7. If confidence < threshold → HTTP Request → Claude Haiku with same prompt
8. Code Node: `validateAIOutput(response, ['entity','category','confidence_score'])`
9. PostgreSQL Node: INSERT into `emails` (with body_text AND body_text_safe)
10. Code Node: sign payload
11. PostgreSQL Node: INSERT `email.received` event → UPDATE to `email.classified`
12. If `has_attachment`: INSERT `document.received` event per attachment
13. If `nanny_relevant`: INSERT `child.event.detected` event
14. PostgreSQL Node: INSERT audit_log with ai_input_hash, ai_raw_output, ai_parsed
15. Error Trigger on any node → write dead_letter → Telegram HTTP request

**email_classifier system prompt:**
```
You are an email classification system for Jo, a business owner.
Jo runs: The Olde Malthouse pub (Tintagel, Cornwall), a property company (7 properties),
and manages personal and family matters.

Classify into exactly one category:
  invoice         — contains or attaches an invoice, bill, or payment request
  action-required — requires Jo to do something (respond, approve, sign, attend)
  report-attachment — contains a data report as PDF/XLSX/CSV attachment
  school-medical  — relates to children, school, or medical appointments
  property        — relates to rental properties, tenants, or letting agents
  pub             — relates to The Olde Malthouse operations
  fyi             — informational, no action needed
  junk            — spam, marketing, automated notifications

Determine entity_id: 1=Trading (pub), 2=Estates (property), 3=Personal, 4=Family

You are analysing pre-sanitised content. Return ONLY valid JSON. No markdown. No explanation.
```

**email_classifier output schema:**
```json
{
  "entity": "Trading",
  "category": "invoice",
  "confidence_score": 0.94,
  "data": { "nanny_relevant": false, "has_invoice_attachment": true, "action_deadline": null },
  "requires_human": false,
  "reasoning": "Email from St Austell Brewery with PDF attachment — invoice pattern",
  "worker": "email_classifier"
}
```

---

### Pipeline 2 — Invoice Pipeline

**Trigger:** New event `invoice.detected` (email attachment)
**Idempotency key:** `invoice_{sha256(supplier_name+gross_amount+invoice_date+entity_id)}`
**Fail mode:** Fail closed — no partial writes

> **Note on Dext:** Dext does not expose a public API. Dext continues as Jo's
> manual review tool in parallel — no system integration. Compare outputs
> manually for the first 60 days to validate extraction accuracy. Internal
> extraction (pdfplumber/MarkItDown + Haiku) is the *only* automated path.

**Node sequence:**
1. Check idempotency → stop if exists
2. Fetch attachment from Gmail via Gmail API (existing OAuth pattern — refresh access token from Vault, GET `/messages/{id}/attachments/{attachment_id}`)
3. Detect MIME type and route:
   - `application/pdf` → HTTP Request pdfplumber POST `/extract-pdf` → structured text + `content_hash`
   - `image/*`, `.docx`, `.doc`, `.html`, other → HTTP Request MarkItDown POST `/convert` → markdown text
4. Code Node: `sanitiseForPrompt(text)` → `body_text_safe` (SPEC §2.4)
5. HTTP Request → Anthropic Haiku `invoice_extractor` with body_text_safe + filename + supplier hint
6. Code Node: build OutcomeObject (status / confidence / reasoning / data / requires_human / worker / tier_used) per §6.2 Outcome-Native Pattern
7. If `outcome.status == 'escalate'` (confidence ≥ threshold × 0.85 but < threshold): retry with medium tier (`model.tiers.medium` from static_context); rebuild OutcomeObject with `tier_used='medium'`
8. If `outcome.status == 'fail'` (confidence < threshold × 0.85): set `requires_human=true`, write to invoices with `requires_human=TRUE`, emit `invoice.unmatched`, end
9. Code Node: supplier anomaly check (see below) — may set `requires_human=true`
10. Code Node: sign payload (HMAC-SHA256 over canonical JSON, key from Vault `secret/signing`)
11. PostgreSQL Node: INSERT invoices (fail closed — abort run on error, no partial state)
12. PostgreSQL Node: upsert supplier_invoice_history
13. SQL: match against xero_invoices (amount ±£0.01, date ±3 days, entity match)
14. If unmatched: INSERT reconciliation_flags
15. Emit `invoice.extracted` (or `invoice.unmatched`) event with parent_event_id chain
16. Audit_log row with `ai_worker='invoice_extractor'`, `ai_parsed=<outcome JSONB>`, `tier_used`

**invoice_extractor system prompt:**
```
You are extracting structured data from invoice text for accounting purposes.
The text has been pre-sanitised. Extract only what is explicitly stated.
Do NOT infer or calculate. Return null for any missing field.
Financial amounts must be numbers (not strings). Dates must be YYYY-MM-DD.
Return ONLY valid JSON. No markdown.
```

**invoice_extractor output schema:**
```json
{
  "entity": "Trading",
  "category": "Finance",
  "confidence_score": 0.97,
  "data": {
    "supplier_name": "St Austell Brewery",
    "invoice_number": "INV-2026-001",
    "invoice_date": "2026-04-15",
    "due_date": "2026-05-15",
    "gross_amount": 1842.50,
    "net_amount": 1535.42,
    "vat_amount": 307.08,
    "currency": "GBP",
    "category": "stock"
  },
  "requires_human": false,
  "reasoning": "Clear invoice, all fields present",
  "worker": "invoice_extractor"
}
```

**Supplier anomaly check (Code Node — after invoice write):**
```javascript
const history = $('Fetch-Supplier-History').first().json;
const gross = parseFloat($('Current-Invoice').first().json.gross_amount);
const ctx = $('Fetch-Static-Context').first().json.value['ai.anomaly'].invoice;

if (!history?.total_invoices || history.total_invoices < ctx.min_history_count)
  return [{ json: { anomaly_check: 'skipped_insufficient_history' } }];

const avg = parseFloat(history.rolling_avg);
if (gross > avg * ctx.multiplier_threshold) {
  return [{ json: { requires_human: true, anomaly_check: 'flagged',
    anomaly_reason: `£${gross} is ${(gross/avg).toFixed(1)}x the 6-month average of £${avg.toFixed(2)}` }}];
}
return [{ json: { anomaly_check: 'passed' } }];
```

---

### Pipeline 3 — Xero Sync

**Trigger:** Schedule 05:00 daily → emit `xero.sync.scheduled`
**Idempotency:** INSERT ... ON CONFLICT (xero_id) DO UPDATE
**Fail mode:** Fail closed

Node sequence: Vault → OAuth tokens → Xero API calls (per org) → upsert tables → emit `xero.sync.complete`

No AI worker. Pull: invoices (awaiting + overdue + paid 90d), bills, bank transactions (30d), contacts.

---

### Pipeline 4 — Bank CSV Import

**Trigger:** Manual file upload or Gmail Trigger (bank notification email with attachment)
**Idempotency key:** `bank_{sha256(account+date+amount+desc[:50])}`
**Fail mode:** Fail closed

Node sequence: File trigger → pdfplumber POST /parse-csv → per-row idempotency check → INSERT bank_transactions → match against xero_invoices → INSERT reconciliation_flags if unmatched → emit `bank.transaction` events

No AI in core path. Matching is arithmetic (amount ±£0.01, date ±3 days).

---

### Pipeline 5 — ICRTouch EPoS

**Trigger:** Gmail Trigger (TouchOffice sender domain detected) → emit `epos.report.received`
**Idempotency key:** `epos_{sha256(report_date+session)}`
**Fail mode:** Fail closed

Node sequence: extract PDF/HTML → pdfplumber → Haiku report_parser → validate arithmetic → INSERT epos_daily_reports → emit `epos.report.processed`

**Arithmetic validation (Code Node):**
```javascript
const r = $input.first().json.data;
if (r.net_sales && r.vat && r.gross_sales) {
  const calc = r.net_sales + r.vat;
  if (Math.abs(calc - r.gross_sales) > 0.10) {
    return [{ json: { ...r, requires_human: true,
      validation_error: `Arithmetic mismatch: net(${r.net_sales})+vat(${r.vat})=${calc} ≠ gross(${r.gross_sales})` }}];
  }
}
```

**report_parser prompt (EPoS mode):**
```
You are extracting sales data from a TouchOffice/ICRTouch daily Z-report for
The Olde Malthouse pub in Tintagel, Cornwall. Extract only values explicitly
stated. Return null for missing fields. Financial values must be positive
decimals. Covers and transactions must be integers.
Do NOT calculate or infer. Return ONLY valid JSON. No markdown.
```

---

### Pipeline 6 — Caterbook

**Trigger:** Gmail Trigger (Caterbook sender detected) → emit `accommodation.received`
**Idempotency key:** `accomm_{sha256(report_date)}`
**Fail mode:** Fail open

Same pattern as Pipeline 5. INSERT accommodation_daily_reports.

**report_parser prompt (Caterbook mode):**
```
You are extracting occupancy and revenue data from a Caterbook daily report
for The Olde Malthouse inn. Extract only explicitly stated values.
Return null for missing fields. Return ONLY valid JSON.
```

---

### Pipeline 7 — Cashing Up (entirely deterministic — no AI)

**Trigger:** Google Sheets Trigger (new row) → emit `cashing_up.entry`
**Idempotency key:** `till_{sha256(recon_date+session)}`
**Fail mode:** Fail closed

```javascript
// Code Node — all arithmetic, no AI
const { session, cash_counted, float_returned, notes } = $input.first().json;
const epos = $('Fetch-EPOS').first().json; // from epos_daily_reports

if (!epos?.z_reading) {
  // EPoS report not yet received — set waiting status, retry in 30 min
  return [{ json: { status: 'waiting_epos', retry_in_minutes: 30 } }];
}

const z_reading     = parseFloat(epos.z_reading);
const card_total    = parseFloat(epos.card_total);
const float_ret     = parseFloat(float_returned);
const cash_cnt      = parseFloat(cash_counted);

const expected_cash = z_reading - card_total - float_ret;
const variance      = cash_cnt - expected_cash;
const variance_pct  = Math.abs(variance) / z_reading * 100;
const flagged       = Math.abs(variance) > 5 || variance_pct > 0.5;

return [{ json: { z_reading, card_total, float_returned: float_ret,
  cash_counted: cash_cnt, expected_cash, variance, variance_pct,
  status: flagged ? 'flagged' : 'ok', flagged } }];
```

After calculation:
- INSERT till_reconciliation
- Update Google Sheet columns F–J
- If flagged: Telegram alert `[!] Cashing up variance: £{variance} ({variance_pct}%) — {date} {session}`

---

### Pipeline 8 — Nanny

**Trigger:** New event `child.event.detected`
**Idempotency key:** `child_{gmail_message_id}_{child_id}`
**Fail mode:** Fail open

Node sequence: Haiku nanny_classifier → threshold check (0.85) → INSERT child_events or medical_history → Google Calendar create event if appointment detected → flag if urgency >= 4

**nanny_classifier prompt:**
```
You are analysing an email for Jo's three children.
Children: Child A (age 16, secondary school), Child B (age 10, primary school),
Child C (age 8, primary school).

Identify: which child (1, 2, 3, or null), event category, dates, urgency 1-5.
If unsure which child: set child_id=null, requires_human=true.
Never guess. The email content has been pre-sanitised.
Return ONLY valid JSON.

Categories: school-event | permission-slip | medical-appointment | nhs-letter |
school-report | school-payment | action-required
```

**nanny_classifier output schema:**
```json
{
  "entity": "Family",
  "category": "permission-slip",
  "confidence_score": 0.91,
  "data": { "child_id": 2, "event_date": "2026-05-10", "deadline": "2026-04-30", "urgency": 3,
            "summary": "Year 6 residential trip permission slip due 30 April" },
  "requires_human": false,
  "reasoning": "Primary school email referencing Year 6 trip with reply-by date",
  "worker": "nanny_classifier"
}
```

---

### Pipeline 9 — Report Ingestion

**Trigger:** New event `document.received`
**Idempotency key:** `report_{sha256(email_id+filename)}`
**Fail mode:** Fail open

Node sequence: detect MIME type → route to pdfplumber endpoint (extract-pdf, parse-xlsx, parse-csv) → sanitise text → Haiku report_parser (classification mode, no type hint) → route to correct table → INSERT

**report_parser prompt (classification mode):**
```
Classify this document and extract key structured fields.
Types: bank_statement | supplier_invoice | property_agent_report | epos_report |
accommodation_report | payroll_report | analytics_report | unknown

If type cannot be determined with confidence > 0.70: return type='unknown',
requires_human=true. Content has been pre-sanitised. Return ONLY valid JSON.
```

---

### Pipeline 10 — Daily Digest

**Trigger:** Schedule 06:45 daily → emit `digest.scheduled`
**Fail mode:** Fail open

Node sequence:
1. Query all tables for last 24h (invoices overdue, bank flags, epos yesterday, accommodation yesterday, child_events urgency≥3, dead_letters unresolved, requires_human queue count)
2. Sonnet digest_generator → email format
3. Haiku digest_generator → Telegram format (≤10 bullets)
4. Gmail send to Jo's address
5. Telegram bot send
6. Emit `digest.ready`

**digest_generator prompt:**
```
You compose a daily briefing for Jo, a business owner in Cornwall.
Data comes from a structured payload — do NOT invent data.
Every claim must reference the provided payload.

Email format sections (omit sections with no data):
  [!] URGENT — action required today or overdue deadline
  FINANCIALS — outstanding invoices, bank flags, unreconciled items
  PUB — last session ICRTouch summary, cashing up status, occupancy
  PROPERTIES — rent received/outstanding, compliance alerts
  FAMILY — school/medical items (urgency >= 3)
  REVIEW QUEUE — items requiring_human approval count
  SYSTEM — dead letter count, pipeline failures

Telegram version: ≤10 bullets, plain text, [!] for urgent, no headers.
Be direct. No filler.
```

---

### Pipeline 11 — Monthly Partition Creation

**Trigger:** Schedule — 25th of every month at 09:00
**Fail mode:** Fail closed (alert immediately)

```javascript
// n8n Code Node
const now = new Date();
const target = new Date(now.getFullYear(), now.getMonth() + 2, 1);
const end    = new Date(now.getFullYear(), now.getMonth() + 3, 1);
const p = n => String(n).padStart(2,'0');
const fmt = d => `${d.getFullYear()}-${p(d.getMonth()+1)}-01`;
const suffix = `${target.getFullYear()}_${p(target.getMonth()+1)}`;

const sql = `DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname='events_${suffix}') THEN
    EXECUTE 'CREATE TABLE events_${suffix} PARTITION OF events
             FOR VALUES FROM (''${fmt(target)}'') TO (''${fmt(end)}'')';
    RAISE NOTICE 'Created events_${suffix}';
  END IF;
END $$;`;

return [{ json: { sql, partition_name: `events_${suffix}` } }];
// Follow with: PostgreSQL execute → INSERT audit_log → Telegram confirmation
```

## 6.3 Microservice Implementations

### pdfplumber Service

**services/pdfplumber/requirements.txt:**
```
pdfplumber==0.11.0
fastapi==0.111.0
uvicorn==0.30.0
pandas==2.2.0
openpyxl==3.1.2
```

**services/pdfplumber/main.py:**
```python
from fastapi import FastAPI, UploadFile, File, HTTPException
import pdfplumber, pandas as pd, io, hashlib, re

app = FastAPI()

def sanitise(text: str) -> str:
    text = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '', text)
    return text[:8000]

@app.post("/extract-pdf")
async def extract_pdf(file: UploadFile = File(...)):
    content = await file.read()
    if len(content) > 10 * 1024 * 1024:
        raise HTTPException(413, "File too large")
    with pdfplumber.open(io.BytesIO(content)) as pdf:
        text = '\n'.join(p.extract_text() or '' for p in pdf.pages)
    return {"text": sanitise(text),
            "content_hash": hashlib.sha256(content).hexdigest()}

@app.post("/parse-xlsx")
async def parse_xlsx(file: UploadFile = File(...)):
    content = await file.read()
    df = pd.read_excel(io.BytesIO(content), nrows=1000)
    df = df.where(pd.notna(df), None)
    return {"data": df.to_dict(orient='records'), "row_count": len(df)}

@app.post("/parse-csv")
async def parse_csv(file: UploadFile = File(...)):
    content = await file.read()
    df = pd.read_csv(io.BytesIO(content), nrows=1000)
    df = df.where(pd.notna(df), None)
    return {"data": df.to_dict(orient='records'), "row_count": len(df)}

@app.get("/healthcheck")
async def healthcheck():
    return {"status": "ok"}
```

**services/pdfplumber/Dockerfile:**
```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8003"]
```

### MarkItDown Service (Phase 3)

Microsoft MarkItDown converts audio, images, Word documents, YouTube transcripts, PowerPoint, and Excel to clean markdown. Supplements pdfplumber (which stays for granular table extraction from PDFs). Add in Phase 3 when Playwright and vision capabilities come online.

**services/markitdown/requirements.txt:**
```
markitdown[all]==0.1.0
fastapi==0.111.0
uvicorn==0.30.0
python-multipart==0.0.9
```

**services/markitdown/main.py:**
```python
from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import JSONResponse
from markitdown import MarkItDown
import tempfile, os, hashlib

app = FastAPI(title="Home AI MarkItDown Service")
md = MarkItDown()  # uses local Whisper for audio, OCR for images

@app.post("/convert")
async def convert_file(file: UploadFile = File(...)):
    """Convert any supported format to markdown.
    Supports: PDF, DOCX, PPTX, XLSX, images (OCR), audio (Whisper),
    YouTube URLs, HTML. Returns {text, content_hash, format_detected}
    """
    content = await file.read()
    if len(content) > 50 * 1024 * 1024:  # 50MB limit
        return JSONResponse({"error": "File too large"}, status_code=413)
    with tempfile.NamedTemporaryFile(
            suffix=os.path.splitext(file.filename)[1], delete=False) as tmp:
        tmp.write(content)
        tmp_path = tmp.name
    try:
        result = md.convert(tmp_path)
        return {
            "text": result.text_content[:20000],  # cap at 20k chars
            "content_hash": hashlib.sha256(content).hexdigest(),
            "title": result.title or file.filename,
        }
    finally:
        os.unlink(tmp_path)

@app.post("/convert-url")
async def convert_url(url: str = Form(...)):
    """Convert a URL (YouTube, web page) to markdown."""
    result = md.convert(url)
    return {"text": result.text_content[:20000], "title": result.title or url}

@app.get("/healthcheck")
async def healthcheck():
    return {"status": "ok"}
```

**Key use cases:**
- A staff member photographs a handwritten delivery note → `POST /convert` → invoice pipeline
- Voice note about a supplier issue → `POST /convert` → events table entry
- Supplier YouTube pricing announcement → `POST /convert-url` → research pipeline
- Word document contract → `POST /convert` → document control pipeline

**Routing:** The report_ingestion pipeline should try MarkItDown first for all non-PDF attachments, and for image files. Fall back to pdfplumber for table-heavy PDFs where granular column extraction matters.

## 6.4 Phase 1 Build Steps

**Each milestone has a gate test at the end. Do not proceed until the gate passes.**

---

## MILESTONE A — Platform Foundation

*Goal: Vault unsealed, PostgreSQL healthy, one test event round-trips.*
*Gate: do not start Milestone B until all three are confirmed.*

### Step 1: Ubuntu and GPU Drivers

```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y curl git wget unzip build-essential ufw
sudo apt-get install -y nvidia-driver-535
sudo reboot
# After reboot:
nvidia-smi  # Must show RTX 3060 with 12GB VRAM
```

### Step 2: Docker and NVIDIA Container Toolkit

```bash
curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh
sudo usermod -aG docker $USER && newgrp docker
sudo apt-get install -y docker-compose-plugin

# NVIDIA Container Toolkit
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | \
  sudo tee /etc/apt/sources.list.d/nvidia-docker.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo systemctl restart docker

# Verify
docker --version && docker compose version
docker run --rm --gpus all nvidia/cuda:11.0.3-base-ubuntu20.04 nvidia-smi
```

### Step 3: Tailscale and Firewall

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up  # Follow auth link in browser
tailscale ip       # Note this IP — all remote access goes through here

sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 100.64.0.0/10 to any  # Tailscale range only
sudo ufw enable
sudo ufw status
```

### Step 4: Project Structure, AGENTS.md, and .claude/

```bash
mkdir -p /home_ai/{postgres,services/{garmin,pdfplumber},security/vault-policies,monitoring/prometheus-rules,storage/{raw_emails,invoices,reports,family_docs}}
mkdir -p /home_ai/.claude/{commands,skills/{deploy-pipeline,vault-secret,add-partition,dead-letter-replay},agents}
mkdir -p /mnt/ssd/obsidian-vault
mkdir -p /mnt/hdd/archive/{emails,documents,photos}
cp SPEC.md /home_ai/SPEC.md
cd /home_ai
```

Create `/home_ai/CLAUDE.md` — one line only:
```markdown
@AGENTS.md
```

Create `/home_ai/AGENTS.md` — the single source of truth (keep under 200 lines total):
```markdown
# Home AI Administrative Engine — AGENTS.md
# Portable across all coding tools. All agents read this.

## System
Local-first event-driven data platform. P620 + Ubuntu 22.04 + Docker.
Full spec: /home_ai/SPEC.md  (read relevant section before each step)

## Architecture
Events table (partitioned by month) is the system backbone.
n8n = pipeline orchestration. AI workers = stateless enrichment only.
Vault = all secrets. PostgreSQL RLS = entity isolation.
Deterministic routing → AI enrichment → PostgreSQL write → event emit.

## Entity IDs
1=Atlantic Road Trading Ltd (pub/inn/restaurant)
2=Atlantic Road Estates Ltd (7 investment properties)
3=Personal
4=Family (3 children ages 8, 10, 16)

## Source of truth (never override these)
Xero=accounting | Email PDF=invoice extraction (Dext is manual review only, no API) | Bank=transactions | ICRTouch=EPoS | Caterbook=accommodation

## Build rules (enforced by hooks — not optional)
- NEVER write any secret to a file. Vault only. No .env with secrets.
- ALWAYS prepend SET LOCAL app.current_entity before any PostgreSQL write.
- ALWAYS use body_text_safe (sanitised), never body_text, in AI prompts.
- ALWAYS sign event payloads (HMAC-SHA256) before INSERT to events table.
- ALWAYS check idempotency_key exists in events before processing.
- NEVER commit: CLAUDE.local.md, *.env, *secret*, *credential*, *password*

## Context management
- Watch context indicator. Run /compact before 60% capacity.
- When compacting: /compact Preserve phase+step number, confirmed Vault secrets,
  confirmed running Docker services, confirmed PostgreSQL tables, idempotency key formats.
- Never let auto-compaction fire during Vault, database, or Docker steps — it is lossy.

## Parallel domain routing
Spawn parallel subagents for independent domains:
- microservices (pdfplumber, garmin, playwright) — safe to parallelise
- n8n pipeline workflows — each is independent JSON, safe to parallelise
- monitoring config — safe to parallelise
Sequential only (never parallelise): PostgreSQL schema, Vault config, docker-compose.yml

## Subagent model
For focused subagent tasks: export CLAUDE_CODE_SUBAGENT_MODEL="claude-haiku-4-5-20251001"
Main session for complex reasoning: default (Sonnet or Opus)

## Global kill switch
Check system.state before any action that writes to the database or triggers a pipeline:
  SELECT value FROM static_context WHERE key='system.state';
If state='paused': stop, log, do not process. Do not override the pause.
Pause/resume via /pause-all and /resume-all slash commands only.

## Context7 MCP (recommended — install before Phase 5 RAG work)
Context7 serves library documentation at exact versions as tool calls.
Prevents hallucinated API signatures on: n8n nodes, Qdrant Python client,
asyncpg, HashiCorp Vault API, garminconnect, FastAPI, exllamav2.
Install: npx -y @upstash/context7-mcp (or via MCP settings in Claude Code)
Use instead of asking Claude to fetch/search online docs.

## Key paths
Spec:        /home_ai/SPEC.md
Docker:      /home_ai/docker-compose.yml
Schema:      /home_ai/postgres/init-db.sql
Seed:        /home_ai/postgres/seed-data.sql
Services:    /home_ai/services/
n8n backups: /home_ai/.claude/n8n-exports/
Skills:      /home_ai/.claude/skills/
Commands:    /home_ai/.claude/commands/

## Skill gotchas (update as failures are discovered during build)
- Claude will try to name containers differently to docker-compose — always use
  docker compose ps to get the actual running container name before exec commands.
- Claude will try to write directly to events without idempotency check — hook blocks this.
- Claude will inline secrets in Code nodes — hook blocks writes to .env files.
- Claude will write SQL without SET LOCAL app.current_entity — hook enforces this.
```

Create `/home_ai/CLAUDE.local.md` — P620-specific, gitignored:
```markdown
# CLAUDE.local.md — P620 local config (never commit this file)

## Hardware
Machine: Lenovo P620, Threadripper 5945WX, 128GB RAM, RTX 3060 12GB
OS: Ubuntu 22.04 LTS

## Network
Tailscale IP: [YOUR_TAILSCALE_IP — fill in after Step 3]
Local subnet: 192.168.x.x

## Mount paths
SSD (OS/DB):  /dev/nvme0n1 → /
HDD (archive): /dev/sda → /mnt/hdd
NAS (backup):  WD MyCloud → /mnt/mycloud

## Docker container names (verify with: docker compose ps)
postgres:    homeai-postgres
n8n:         homeai-n8n
ollama:      homeai-ollama
vault:       homeai-vault
metabase:    homeai-metabase
pdfplumber:  homeai-pdfplumber
grafana:     homeai-grafana

## Current build state
Phase: 1
Last completed step: [update as you go]
```

Create `/home_ai/.gitignore`:
```
CLAUDE.local.md
*.env
.env.*
*secret*
*credential*
*password*
*.key
vault-init-output.txt
.env.runtime
```

Create slash commands in `/home_ai/.claude/commands/`:

**verify-phase1.md:**
```markdown
---
name: verify-phase1
description: Run the full Phase 1 testing checklist from SPEC.md Section 6.5
---
Read Section 6.5 of /home_ai/SPEC.md (Phase 1 Testing Checklist).
Work through every item in order. For each:
1. Run the check
2. Report pass or fail with the actual output
3. If fail, propose the fix before making any changes
Report a final summary: N passed, N failed, N skipped.
```

**check-vault.md:**
```markdown
---
name: check-vault
description: Verify all required Vault secrets are loaded and accessible
---
Check that every secret path listed in SPEC.md Section 2.1 exists in Vault.
Use: docker exec -e VAULT_TOKEN=$VAULT_TOKEN homeai-vault vault kv get [path]
Report which paths exist, which are missing, and which return auth errors.
Never print the secret values — only confirm presence.
```

**check-services.md:**
```markdown
---
name: check-services
description: Check all Phase 1 Docker services are running and healthy
---
Run: docker compose ps
For any service not showing 'running' or 'healthy': check its logs with docker compose logs [service] --tail=20
Report status of each Phase 1 service and any error messages found.
```

**replay-event.md:**
```markdown
---
name: replay-event
description: Replay a dead letter event after fixing the root cause
disable-model-invocation: true
---
Follow the dead letter resolution procedure from SPEC.md Appendix F.
Ask for the event_id to replay, then:
1. Show the current dead_letter row and its error_message
2. Confirm the root cause has been fixed before proceeding
3. Run the replay SQL (UPDATE events SET status='pending', retry_count=0...)
4. Run the resolution SQL (UPDATE dead_letter SET resolved=true...)
5. Monitor n8n for successful processing
```

**check-partitions.md:**
```markdown
---
name: check-partitions
description: Verify events table partitions and overflow count
---
Run these queries:
1. SELECT tableoid::regclass, COUNT(*) FROM events GROUP BY 1 ORDER BY 1
2. SELECT COUNT(*) FROM events_overflow
3. SELECT tablename FROM pg_tables WHERE tablename LIKE 'events_%' ORDER BY tablename
Report: which monthly partitions exist, how many rows in each, overflow count (must be 0).
If overflow > 0, identify which months are missing and propose the CREATE TABLE fix.
```

**security-review.md:**
```markdown
---
name: security-review
description: Run a security review of the current build state
---
1. Run the /security command and capture all output
2. Review each finding against SPEC.md Section 2 (Security Architecture)
3. Categorise findings: Critical (fix now) | Warning (fix before Phase 2) | Info (log only)
4. For Critical findings, propose the specific fix before implementing
5. Log the review in System/Assistant/logs/issues-fixes-log.md with date and findings summary
```

Create ADR folder for architectural decisions:
```bash
mkdir -p /home_ai/.claude/decisions
cat > /home_ai/.claude/decisions/README.md << 'MD'
# Architectural Decision Records (ADRs)
One file per significant decision made during the build.
Format: YYYY-MM-DD-topic.md
Created by end-of-session retro when Claude identifies an architectural choice.
MD
```

Add pause/resume command files in `/home_ai/.claude/commands/`:

**pause-all.md:**
```markdown
---
name: pause-all
description: Immediately pause all pipeline processing — sets system_state to paused
---
Run: curl -X POST http://localhost:5678/webhook/system-control -d '{"action":"pause","reason":"manual pause"}'
Confirm pause: SELECT value FROM static_context WHERE key='system.state';
Telegram alert will fire automatically. Resume with /resume-all after fixing root cause.
```

**resume-all.md:**
```markdown
---
name: resume-all
description: Resume all pipeline processing after a pause — confirm root cause resolved first
---
Run: curl -X POST http://localhost:5678/webhook/system-control -d '{"action":"resume","reason":"resolved"}'
Confirm: SELECT value FROM static_context WHERE key='system.state';
```

**simplify.md:**
```markdown
---
name: simplify
description: Strip over-engineering from recently written code before human review
---
Review the files written in the last step. Remove: unnecessary abstractions,
speculative error handling for problems that don't exist, defensive code beyond
what the spec requires, commented-out alternatives. Keep it simple and direct.
Report what was removed and why.
```

**review.md:**
```markdown
---
name: review
description: Claude self-reviews its own output — catch issues before human review
---
Review everything written in the last step against:
1. The relevant section of SPEC.md
2. The build rules in AGENTS.md
3. The Gotchas section in AGENTS.md
Report any discrepancies, missing error handling, or spec violations.
Fix them before reporting complete.
```

**retro.md:**
```markdown
---
name: retro
description: End-of-session retrospective — extract and file learnings
---
Answer: What did you learn during this session?
Then file each learning to the correct location:
- Build failures / fixes → append to /mnt/ssd/obsidian-vault/System/Assistant/logs/issues-fixes-log.md
- Architectural decisions → create /home_ai/.claude/decisions/YYYY-MM-DD-[topic].md
- Claude failure modes / repeated mistakes → add to Gotchas section in AGENTS.md
- General project conventions → add to AGENTS.md main body
Report what was filed and where.
```

Create subagent definitions in `/home_ai/.claude/agents/`:

**db-agent.md:**
```markdown
---
name: db-agent
description: PostgreSQL specialist — schema changes, migrations, RLS policies, query optimisation
tools: [Read, Write, Bash]
---
You are a PostgreSQL specialist for the Home AI system.
Always read /home_ai/postgres/init-db.sql before making schema changes.
Always prepend SET LOCAL app.current_entity = '[id]' before any DML.
Never DROP tables or columns without explicit confirmation.
Return a summary of changes made, not the full SQL executed.
```

**pipeline-agent.md:**
```markdown
---
name: pipeline-agent
description: n8n workflow builder — creates and tests individual pipeline workflows
tools: [Read, Write, Bash]
---
You are an n8n workflow specialist for the Home AI system.
Read /home_ai/SPEC.md Section 6.2 for pipeline specifications before building.
Every workflow must have: idempotency check, error trigger path, audit_log write.
Export completed workflows to /home_ai/.claude/n8n-exports/ as JSON.
Test each workflow with a synthetic event before reporting complete.
```

**security-agent.md:**
```markdown
---
name: security-agent
description: Read-only security reviewer — checks for exposed secrets, RLS gaps, injection risks
tools: [Read, Bash]
---
You are a read-only security reviewer. You cannot write files or run commands that modify state.
Check: no secrets in .env files, no hardcoded credentials, RLS enabled on all entity tables,
HMAC signatures on events, prompt injection sanitisation in place.
Report findings only. Never apply fixes — return findings to main session.
```

**playground-agent.md** (create in Phase 5 alongside Workflow F):
```markdown
---
name: playground-agent
description: Builds prototype websites and creative projects in /home_ai/playground/. Use for: ice cream menus, event landing pages, booking forms, pub pages, visual experiments. Never for core system work.
tools: [Read, Write, Bash]
---
You are a creative web builder working ONLY in /home_ai/playground/.
You cannot access: the database, Vault, n8n, Docker, or any path outside /home_ai/playground/.
Stack: Next.js or plain HTML/CSS/JS. Tailwind via CDN. shadcn/ui for richer components.
Images: Unsplash URLs or placeholder.co only — never embed large assets.
After building: git add . && git commit -m "prototype: [description]" && git push
Then trigger deploy: curl -X POST http://n8n:5678/webhook/playground-deploy -d '{"project":"[folder]"}'
Return the Vercel preview URL when the deploy completes.
```

### Step 5: Vault First (before any other service)

```bash
cd /home_ai
docker compose up -d vault
sleep 15

# INITIALISE — save output PERMANENTLY AND OFFLINE (print it)
docker exec homeai-vault vault operator init -key-shares=5 -key-threshold=3

# Unseal (run 3 times with 3 different keys from init output)
docker exec -it homeai-vault vault operator unseal  # Key 1
docker exec -it homeai-vault vault operator unseal  # Key 2
docker exec -it homeai-vault vault operator unseal  # Key 3

# Verify unsealed
docker exec homeai-vault vault status

# Authenticate with root token
export VAULT_TOKEN=<root_token_from_init>

# ── NOTE: Auto-unseal is a Phase 2 hardening step ──────────────────────────
# Vault auto-unseal (vault-autounseal.sh + systemd service) is NOT built here.
# Reason: the auto-unseal script adds systemd, age encryption, boot-sequence
# logic, and machine-key derivation — all of which need to be debugged before
# the system has produced a single useful result. A bug here means Vault stays
# sealed after every reboot, silently breaking all pipelines.
#
# Phase 1 uses manual unseal only (three keys at the start of each session).
# Auto-unseal is added in Phase 2 once the system is proven to work.
# Full auto-unseal implementation: see Section 7.2 Phase 2 Hardening.

# Enable KV v2
docker exec -e VAULT_TOKEN=$VAULT_TOKEN homeai-vault \
  vault secrets enable -path=secret kv-v2

# Load all Phase 1 secrets (run for each path in Section 2.1)
docker exec -e VAULT_TOKEN=$VAULT_TOKEN homeai-vault \
  vault kv put secret/anthropic api_key="sk-ant-XXXX"
docker exec -e VAULT_TOKEN=$VAULT_TOKEN homeai-vault \
  vault kv put secret/telegram bot_token="XXXX" chat_id="XXXX"
# ... (repeat for all paths)

# Load n8n policy and create limited token
docker cp security/vault-policies/n8n-policy.hcl homeai-vault:/vault/policies/
docker exec -e VAULT_TOKEN=$VAULT_TOKEN homeai-vault \
  vault policy write n8n-policy /vault/policies/n8n-policy.hcl
N8N_TOKEN=$(docker exec -e VAULT_TOKEN=$VAULT_TOKEN homeai-vault \
  vault token create -policy=n8n-policy -format=json | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])")
echo "VAULT_N8N_TOKEN=$N8N_TOKEN" >> /home_ai/.env.runtime
```

### Step 6: Start Core Services

```bash
cd /home_ai
docker compose up -d postgres redis qdrant n8n metabase grafana prometheus netdata open-webui
sleep 60
docker compose ps  # All should show 'running' or 'healthy'

# Verify Open WebUI is accessible:
curl -s http://localhost:8080/health  # Must return {"status":"ok"}
# Access at http://[tailscale-ip]:8088
# First login: create admin account, select Ollama as the model source
# Verify llama3.3:70b appears in the model list after Step 8
```

### Step 7: Initialise Database Schema

```bash
# Create SQL files from Sections 3.2, 3.3, 3.4
# Then run:
docker exec -i homeai-postgres psql -U postgres -d homeai < /home_ai/postgres/init-db.sql
docker exec -i homeai-postgres psql -U postgres -d homeai < /home_ai/postgres/rls-policies.sql
docker exec -i homeai-postgres psql -U postgres -d homeai < /home_ai/postgres/seed-data.sql

# Verify
docker exec -it homeai-postgres psql -U postgres -d homeai -c "\dt"
# Must show: events, dead_letter, audit_log, security_audit_log, emails, invoices,
#            bank_transactions, epos_daily_reports, till_reconciliation,
#            accommodation_daily_reports, children, child_events,
#            supplier_invoice_history, static_context, ...

# Verify partitioning
docker exec -it homeai-postgres psql -U postgres -d homeai -c \
  "SELECT tableoid::regclass, COUNT(*) FROM events GROUP BY 1;"
# Must show events_2026_04 (or current month) — NOT just 'events'
```

### ✓ GATE A — Platform Foundation

**Do not proceed to Milestone B until all three pass.**

```bash
# Test 1: Vault is unsealed
docker exec homeai-vault vault status | grep "Sealed.*false"
# Expected: Sealed          false

# Test 2: PostgreSQL accepts connections and schema is applied
docker exec homeai-postgres psql -U postgres -d homeai -c "\dt" | grep events
# Expected: events table listed

# Test 3: One event round-trips correctly
docker exec homeai-postgres psql -U postgres -d homeai -c "
  INSERT INTO events (event_type, source, entity_id, payload, payload_signature)
  VALUES ('system.test', 'gate_a', 1, '{"test": true}', 'test_sig_placeholder')
  RETURNING id, tableoid::regclass as partition;
"
# Expected: returns row showing events_YYYY_MM partition (NOT events_overflow)

docker exec homeai-postgres psql -U postgres -d homeai -c "
  SELECT COUNT(*) FROM events_overflow;
"
# Expected: 0

# If all three pass: proceed to Milestone B
# If any fail: fix before continuing — do not proceed
```

---

## MILESTONE B — First Vertical Slice

*Goal: one real email received → classified → written to DB → visible in Metabase.*
*Gate: do not start Milestone C until this is proven with a real email.*

### Step 8: Install Ollama Hot Tier Model

```bash
docker compose up -d ollama
# Milestone B: pull the hot tier model only (4.4GB — fast)
# The heavy tier (llama3.3:70b, 42GB) is pulled in Milestone C
# after the vertical slice is proven
docker exec -it homeai-ollama ollama pull qwen2.5:7b
docker exec homeai-ollama ollama list  # Verify qwen2.5:7b present

# Test inference with the hot tier model
curl http://localhost:11434/api/generate -d '{
  "model": "qwen2.5:7b",
  "prompt": "Return this JSON object exactly: {\"test\": true, \"status\": \"ok\"}",
  "stream": false
}' | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['response'])"
# Expected: {"test": true, "status": "ok"} — valid JSON returned
```

### Step 9: Build pdfplumber and Garmin Services

> **Parallel opportunity:** Steps 9 and 9b build independent microservices with no shared files. Spawn a subagent for one while building the other in the main session to run them simultaneously.
>
> *"Use a pipeline-agent subagent to build the pdfplumber service from SPEC.md Section 6.3 while I continue with Step 9b in this session."*

**pdfplumber service:**
```bash
# Create services/pdfplumber/ from Section 6.3
docker compose up -d --build pdfplumber-service
curl http://localhost:8003/healthcheck  # Must return {"status":"ok"}
curl -X POST http://localhost:8003/extract-pdf \
  -F "file=@/path/to/test.pdf" | python3 -m json.tool
```

### Step 9b: Build Model Stack Evaluator Service

```bash
# Create services/model-evaluator/ from Part 6a (Model Stack Evaluator)
# requirements.txt: fastapi==0.111.0 uvicorn==0.30.0 httpx==0.27.0 asyncpg==0.29.0
docker compose up -d --build model-evaluator
curl http://localhost:8080/api/models/local  # Must return installed Ollama models

# Pull the initial recommended stack (llama3.3:70b already installed in Step 8)
docker exec -it homeai-ollama ollama pull qwen2.5:7b
docker exec -it homeai-ollama ollama pull phi4:14b

# Milestone B: deploy hot tier only (qwen2.5:7b is already pulled)
# phi4:14b and llama3.3:70b are pulled and deployed in Milestone C
curl -X POST http://localhost:8080/api/models/qwen2.5%3A7b/deploy/hot

# Verify tier assignments written to static_context
docker exec -it homeai-postgres psql -U postgres -d homeai -c \
  "SELECT value FROM static_context WHERE key='model.tiers';"
# Must show: {"hot": "qwen2.5:7b", "medium": "phi4:14b", "heavy": "llama3.3:70b"}

# NOTE: Benchmark runs are deferred to Phase 2.
# Benchmarks require real pipeline data to be meaningful.
# Tier deployment is enough for Phase 1 — pipelines will use model.tiers.
```

### Step 10: Configure n8n — Master Router

Access n8n at `http://[tailscale-ip]:5678`

Create workflow: **Master Router**
- Trigger: PostgreSQL Trigger (poll events table, 30-second interval)
- Query: the `SELECT FOR UPDATE SKIP LOCKED` batch query from Section 4.3
- Switch Node: routing rules from Section 4.3
- Output: trigger appropriate pipeline via webhook call
- Error path: write dead_letter, Telegram alert

### Step 11: Gmail Ingest — The Vertical Slice

**Build Pipeline 1 (Gmail Ingest) only.** This is the single pipeline that proves the entire system works end-to-end before committing to building the remaining twelve. Every other pipeline is a variation on this proven pattern.

```
Build: Gmail Ingest workflow (Section 6.2 Pipeline 1)
Test: send one real email to the monitored Gmail account
Verify:
  - email.received event appears in events table within 15 minutes
  - email is classified (check emails table: classification field populated)
  - email.classified event emitted (events table: second row with correct type)
  - No events in events_overflow (SELECT COUNT(*) FROM events_overflow = 0)
  - HMAC signature present on both events rows
  - audit_log shows pipeline execution with ai_worker = 'email_classifier'
```

Only when this passes: proceed to Milestone B gate.

### Step 12: Minimal Metabase — Vertical Slice Visibility

Connect Metabase to PostgreSQL (host: postgres, user: homeai_readonly) and build two questions only:

1. **Events log** — `SELECT event_type, status, created_at FROM events ORDER BY created_at DESC LIMIT 20`
2. **Email review queue** — `SELECT from_address, subject, classification, requires_human FROM emails ORDER BY received_at DESC LIMIT 10`

This gives visible proof that the vertical slice is working before building anything else.

### ✓ GATE B — First Vertical Slice

**Do not proceed to Milestone C until all items pass.**

```
[ ] One real email received → events table → email.received event (correct partition)
[ ] email_classifier ran → emails.classification field populated (not null)
[ ] email.classified event emitted → second events row
[ ] events_overflow: SELECT COUNT(*) = 0
[ ] HMAC signature present on all events rows
[ ] audit_log: row with pipeline='email_pipeline', ai_worker='email_classifier'
[ ] Metabase: email visible in review queue
[ ] No dead letters from this run

If any item fails: fix it. The remaining 12 pipelines are all variations on
this pattern — if this doesn't work, nothing else will work either.
```

---

## MILESTONE C — Full Pipeline Build

*Goal: all pipelines, all models, monitoring, backup.*
*Gate: full Phase 1 testing checklist.*

### Step 13: Pull Remaining Ollama Models and Deploy All Tiers

```bash
# Now that the vertical slice is proven, pull the remaining models
# llama3.3:70b is 42GB — start this pull and work on other steps while it downloads
docker exec -it homeai-ollama ollama pull phi4:14b     # ~8GB, 15-20 min
docker exec -it homeai-ollama ollama pull llama3.3:70b # 42GB, 30-60 min

# Once pulled, deploy all three tiers:
curl -X POST http://localhost:8080/api/models/phi4%3A14b/deploy/medium
curl -X POST http://localhost:8080/api/models/llama3.3%3A70b/deploy/heavy

# Verify all three tiers assigned:
docker exec -it homeai-postgres psql -U postgres -d homeai -c   "SELECT value FROM static_context WHERE key='model.tiers';"
# Expected: {"hot": "qwen2.5:7b", "medium": "phi4:14b", "heavy": "llama3.3:70b"}
```

### Step 14: Build Remaining Pipeline Workflows

> **Parallel opportunity:** now that Pipeline 1 is proven, fan out to build the remaining pipelines simultaneously using pipeline-agent subagents.
>
> *"Spawn three pipeline-agent subagents in parallel: one for Invoice Pipeline (2), one for Xero Sync (3) + Bank CSV (4), one for EPoS (5) + Caterbook (6). Each should follow SPEC.md Section 6.2, export workflow JSON to .claude/n8n-exports/, and report back when tested."*

**Batch 1 (parallelise — independent pipelines):**
2. **Invoice Pipeline** — Pipeline 2
3. **Xero Sync** — Pipeline 3
4. **Bank CSV Import** — Pipeline 4
5. **ICRTouch EPoS** — Pipeline 5
6. **Caterbook** — Pipeline 6

**Batch 2 (after Batch 1 — depend on Batch 1 data):**
7. **Cashing Up** — Pipeline 7 (needs ICRTouch data from Pipeline 5)
8. **Nanny** — Pipeline 8 (needs Gmail Ingest from Pipeline 1)
9. **Report Ingestion** — Pipeline 9 (needs email attachments from Pipeline 1)
10. **Daily Digest** — Pipeline 10 (queries all tables — needs all above)
11. **Monthly Partition Creation** — Pipeline 11
12. **Stale Lease Recovery** — 5-minute schedule, SQL from Section 4.4
13. **Model Evaluator Webhook** — Workflow D: `POST /webhook/model-evaluator-manual`

For each workflow:
- Follow the node sequence in Section 6.2
- Add error trigger path (dead_letter + Telegram)
- Export workflow JSON to `/home_ai/.claude/n8n-exports/`
- Test with a synthetic event before marking complete

### Step 15: Update n8n AI Workers to Use model.tiers

After deploying the initial stack, update every n8n AI pipeline workflow to read the deployed model from `static_context` rather than hardcoding `llama3.3:70b`. Add this Code node at the top of every pipeline before any Ollama HTTP Request:

```javascript
// Fetch-Model-Tier node — add to every pipeline before Ollama call
const ctx = $('Fetch-Static-Context').first().json.value;
const tiers = ctx['model.tiers'];
// Each pipeline specifies its tier:
const tier = 'hot';      // email_pipeline, nanny_pipeline, report_ingestion
// const tier = 'medium'; // invoice_pipeline, epos_pipeline, accommodation_pipeline
// const tier = 'heavy';  // digest_pipeline, reconciliation_pipeline

const ollamaModel = tiers[tier];
return [{ json: { ...($input.first().json), ollama_model: ollamaModel } }];
// Use {{$json.ollama_model}} in all subsequent Ollama HTTP Request nodes
```

This means changing the deployed tier in the model evaluator automatically propagates to all pipelines — no manual workflow edits required.

### Step 16: Full Metabase Dashboard

1. Access at `http://[tailscale-ip]:3000`
2. Connect PostgreSQL (host: postgres, user: homeai_readonly, db: homeai)
3. Build these panels as Metabase questions:

**Financial Dashboard:**
- Current balances per bank account (latest row per account from bank_transactions)
- Invoices overdue (due_date < today, status != paid)
- 30/60-day payables
- Open reconciliation flags
- Manual review queue (requires_human = true, all tables, UNION ALL query)

**Pub Dashboard:**
- Last 7 days EPoS sales trend (bar chart)
- Yesterday cashing up status (variance highlight)
- Occupancy this week vs last

**Manual Review Queue (pin to top of all dashboards):**
```sql
SELECT 'invoice' as type, id, supplier_name as description,
       CONCAT('£', gross_amount) as amount, anomaly_reason as reason,
       created_at as flagged_at
FROM invoices WHERE requires_human = true AND status = 'pending'
UNION ALL
SELECT 'email', id, CONCAT(from_address, ' — ', subject), null,
       'Classification ambiguous', received_at
FROM emails WHERE requires_human = true AND processed = false
UNION ALL
SELECT 'dead_letter', event_id, pipeline, null, error_message, created_at
FROM dead_letter WHERE resolved = false
ORDER BY flagged_at DESC;
```

### Step 17: Monitoring

1. Grafana at `http://[tailscale-ip]:3001`
2. Add Prometheus data source
3. Import node-exporter dashboard (ID: 1860)
4. Build pipeline health dashboard:
   - Events processed per hour (group by event_type)
   - Failure rate per pipeline (audit_log)
   - Dead letter count (dead_letter where resolved=false)
   - events_overflow count (security alert if > 0)
5. Add Telegram alert channel
6. Configure alert rules from Part 2.6

### Step 18: Open WebUI

```bash
docker compose up -d open-webui
curl -s http://localhost:8088/health  # Must return {"status":"ok"}
# Access at http://[tailscale-ip]:8088
# First login: create admin account. Signup must be disabled.
# Select Ollama as model source — all three models should be visible.
```

> **Authelia SSO** is deferred to Phase 2 hardening. During the build phase,
> Tailscale provides sufficient access control. Adding SSO before the system
> is proven adds configuration complexity with no practical benefit. See Section 7.2.

### Step 19: Restic Backup

```bash
sudo apt-get install -y restic
curl https://rclone.org/install.sh | sudo bash
rclone config  # Set up OneDrive remote named 'onedrive'

# Create password file (store securely — not in Vault)
openssl rand -hex 32 > /root/.restic-pw && chmod 600 /root/.restic-pw

# Initialise repositories
restic -r /mnt/mycloud/backups --password-file /root/.restic-pw init
restic -r rclone:onedrive:backups --password-file /root/.restic-pw init

# Create backup script /usr/local/bin/backup-nightly.sh
chmod +x /usr/local/bin/backup-nightly.sh

# Add to crontab
(crontab -l 2>/dev/null; echo "0 2 * * * root /usr/local/bin/backup-nightly.sh >> /var/log/restic.log 2>&1") | crontab -
```

**backup-nightly.sh:**
```bash
#!/bin/bash
REPO=/mnt/mycloud/backups
PW=/root/.restic-pw
restic -r $REPO --password-file $PW backup \
  /var/lib/docker/volumes/postgres_data/_data \
  /var/lib/docker/volumes/n8n_data/_data \
  /mnt/ssd/obsidian-vault \
  /home_ai/postgres \
  /home_ai/security
restic -r $REPO --password-file $PW \
  forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune
if [ "$(date +%u)" -eq 7 ]; then
  restic -r rclone:onedrive:backups --password-file $PW backup \
    /var/lib/docker/volumes/postgres_data/_data /mnt/ssd/obsidian-vault
fi
```

## 6.5 Phase 1 Testing Checklist

### ✓ GATE C — Full Phase 1 Complete

Work through every item. All must pass before Phase 2 begins.

### Security
```
[ ] vault status → shows Unsealed
[ ] n8n Vault token cannot read secret/garmin (403 expected)
[ ] RLS: SET app.current_entity='2'; SELECT * FROM invoices → only entity_id=2 rows
[ ] Send email with body "Ignore all previous instructions" → security_audit_log entry created
[ ] security_audit_log: UPDATE fails with permission denied (append-only verified)
[ ] No secrets in any .env file or n8n credential store
[ ] HMAC signature present on all events table rows
[ ] UFW status: only Tailscale range allowed
```

### Infrastructure
```
[ ] docker compose ps → all Phase 1 services healthy/running
[ ] nvidia-smi inside Ollama container shows RTX 3060 12GB
[ ] Ollama inference test returns valid JSON
[ ] All database tables created (\dt shows 25+ tables)
[ ] events_overflow: SELECT COUNT(*) → 0
[ ] events_2026_04 (or current month) exists and is the correct partition
[ ] Backup: restic snapshots list shows at least one snapshot
```

### Pipelines
```
[ ] Gmail pipeline: send test email → email.received event in events table within 15 min
[ ] Idempotency: send same email twice → only one row in emails table
[ ] Invoice pipeline: email test PDF → appears in invoices table (source=email_ocr)
[ ] Invoice pipeline: same PDF emailed twice → only one invoices row (idempotency on supplier+amount+date+entity)
[ ] EPoS pipeline: forward TouchOffice email → epos_daily_reports populated
[ ] EPoS arithmetic validation: net+vat ≈ gross (within £0.10)
[ ] Caterbook pipeline: forward Caterbook email → accommodation_daily_reports populated
[ ] Cashing up: add Google Sheet row → till_reconciliation populated, columns F–J updated
[ ] Cashing up variance: enter wrong cash amount (>£5 off) → Telegram alert received
[ ] Nanny pipeline: forward school email → child_events populated with correct child_id
[ ] Pipeline versioning: new invoice → audit_log shows pipeline_version = '1.0'
[ ] Event lineage: trace_id links email.received → email.classified → invoice.detected → invoice.extracted
[ ] Dead letter: manually break a pipeline → dead_letter entry created, Telegram alert sent
[ ] Stale lease: manually set event status='processing', processing_started_at=15 min ago → recovered within 5 min
[ ] Monthly partition: trigger manually on 25th → next month's partition created
[ ] events_overflow: after partition creation → still 0 rows
```

### Outputs
```
[ ] Open WebUI: accessible at http://[tailscale-ip]:8088 from phone
[ ] Open WebUI: llama3.3:70b listed in model selector and generates a response
[ ] Open WebUI: admin account created, signup disabled (no other accounts possible)
[ ] 7am digest email received at Jo's address
[ ] Telegram morning brief received (≤10 bullets, plain text)
[ ] Telegram bot: /status command returns system health response
[ ] Telegram bot: /takings command returns last Z-report summary
[ ] Metabase financial dashboard shows live data
[ ] Manual review queue shows any flagged items
[ ] Grafana: pipeline health chart shows event processing activity
```

---

# PART 6a: MODEL STACK EVALUATOR

## 6a.1 Overview

The model stack evaluator is a standalone service that maintains a three-tier local model stack optimised for the RTX 3060 12GB, benchmarks models against actual production task types, scans for new compatible models weekly, and propagates tier assignments to all n8n pipelines via `static_context`.

**Dashboard route:** `/dashboard/models` (React component: `ModelStackEvaluator.jsx`)
**Backend service:** `services/model-evaluator/` (FastAPI, port 8088)
**Database tables:** `model_registry`, `benchmark_results`, `model_scores`, `model_recommendations`, `model_scan_log`

## 6a.2 Hardware Tier Structure

| Tier | Label | VRAM budget | Model size | Target speed |
|---|---|---|---|---|
| 1 — Hot | Email, routing, classification | ≤ 6 GB VRAM | 3–8B | > 60 t/s |
| 2 — Medium | Invoice extraction, report parsing | ≤ 10 GB VRAM | 9–14B | > 30 t/s |
| 3 — Heavy | Digest, reconciliation, reasoning | RAM (no VRAM limit) | 34–72B | > 8 t/s |

**VRAM residency:** The Tier 1 (hot) model stays VRAM-resident at all times via `OLLAMA_KEEP_ALIVE="-1"`. Tier 2 loads on demand (Ollama manages eviction). Tier 3 is RAM-resident.

**Ollama environment (add to docker-compose.yml ollama service):**
```yaml
  ollama:
    environment:
      OLLAMA_KEEP_ALIVE: "-1"
      OLLAMA_NUM_PARALLEL: "2"
```

**EXL2 quantization — prefer over GGUF for NVIDIA hardware:**

EXL2 uses mixed-precision quantization (per-layer rather than uniform) and the exllamav2 inference engine, which is significantly faster than GGUF on NVIDIA GPUs. For the RTX 3060, a Qwen2.5 14B at 4.0-bpw EXL2 fits comfortably in 12GB VRAM with a 32k context window, while delivering better quality-per-bit than the equivalent GGUF Q4_K_M.

Ollama does not natively serve EXL2 models — they require the exllamav2 or tabbyAPI serving layer. Use this for Tier 2 (medium) models where the VRAM constraint is tightest and the quality-per-bit benefit is most measurable.

When the model stack evaluator benchmarks Tier 2 candidates, test EXL2 variants alongside GGUF:

```bash
# Install tabbyAPI as an alternative serving layer for EXL2 models (Phase 2+):
# tabbyAPI serves on the same HTTP interface as Ollama — drop-in replacement
docker run -d --gpus all -p 5001:5001   -v /mnt/hdd/models:/models   theroyallab/tabbyapi:latest

# Pull a Qwen2.5-14B EXL2 4.0bpw model (example — check HuggingFace for current versions):
# huggingface-cli download turboderp/Qwen2.5-14B-Instruct-exl2 --local-dir /mnt/hdd/models/

# Add to model_registry with quantization='EXL2_4bpw' when benchmarking:
# The benchmark suite records quantization in benchmark_results for direct comparison
```

Add to `model_registry` seed data when EXL2 variants are pulled:
```sql
INSERT INTO model_registry (model_name, family, params_b, quantization, vram_gb)
VALUES ('qwen2.5-14b-exl2-4bpw', 'Qwen', 14.0, 'EXL2_4bpw', 8.2)
ON CONFLICT (model_name) DO NOTHING;
```

**Rule:** For Tier 2 (medium) models, benchmark GGUF Q4_K_M and EXL2 4.0bpw variants of the same model. Deploy whichever wins on composite score. The model stack evaluator handles this transparently — the serving endpoint (Ollama vs tabbyAPI) is abstracted behind the model.tiers static_context key.

## 6a.3 Recommended Initial Stack

| Tier | Model | Rationale |
|---|---|---|
| Hot (Tier 1) | `qwen2.5:7b` | 91% classification accuracy, 89 t/s, 4.4 GB VRAM — stays resident |
| Medium (Tier 2) | `phi4:14b` | 94% invoice extraction accuracy, 42 t/s, 8.5 GB — loads on demand |
| Heavy (Tier 3) | `llama3.3:70b` | 96% reasoning quality — already installed, no compelling alternative yet |

**Expected improvement over single-model stack (all 70B):**
- Email classification: ~8× faster (89 t/s vs 11 t/s) — transforms the 15-min Gmail poll
- Invoice extraction: ~4× faster (42 t/s vs 11 t/s)
- Digest generation: unchanged — 70B stays for reasoning quality
- VRAM usage: 4.4 GB resident + on-demand loading (vs 0 VRAM before, all RAM)

## 6a.4 Benchmark Task Definitions

Every benchmark task maps to a real production pipeline prompt. Same inputs, same scoring rubric as production. Full task definitions (including 10 labelled email samples, 5 invoice texts, EPoS report excerpts) are in `services/model-evaluator/benchmark_tasks.py`.

| Task ID | Tier | Weight | Scoring |
|---|---|---|---|
| email_classification | hot | 40% | Exact match — 10 labelled emails |
| json_format | hot | 25% | JSON validity — 10 extraction prompts |
| speed_hot | hot | 35% | Tokens/sec on 200-token prompt |
| invoice_extraction | medium | 40% | Per-field accuracy — 5 invoice texts |
| report_parsing | medium | 35% | Per-field accuracy — 3 EPoS/Caterbook reports |
| speed_medium | medium | 25% | Tokens/sec on 500-token prompt |
| digest_quality | heavy | 40% | Manual quality rating 1–5 + format check |
| reconciliation_reasoning | heavy | 35% | Manual quality rating 1–5 |
| speed_heavy | heavy | 25% | Tokens/sec on 1000-token prompt |

**Composite score formula:** accuracy tasks (65% weight) + speed task (35% weight). Deployment threshold: 3% composite improvement over current deployed model.

**Manual scoring (Tier 3 tasks):** After a heavy-tier benchmark run, the digest_quality and reconciliation_reasoning tasks produce outputs logged to `benchmark_results.raw_output`. Jo reviews these via the dashboard Benchmarks tab and enters a 1–5 rating. The system cannot auto-score reasoning quality.

## 6a.5 Pipeline Integration — model.tiers in static_context

After every tier deployment, the evaluator writes the active model assignments to `static_context`:

```sql
-- Written automatically by /api/models/{model}/deploy endpoint
-- Key: model.tiers
-- Value: {"hot": "qwen2.5:7b", "medium": "phi4:14b", "heavy": "llama3.3:70b"}
```

Every n8n AI worker reads this key at call time. The model used by any pipeline is the one assigned to its tier in static_context — no workflow edits needed when tiers change.

**n8n tier selection pattern (Code node at top of every AI pipeline):**

```javascript
const tiers = $('Fetch-Static-Context').first().json.value['model.tiers'];
// Each pipeline declares its tier:
const PIPELINE_TIER = 'hot';   // hot | medium | heavy
const ollamaModel = tiers[PIPELINE_TIER];
return [{ json: { ...($input.first().json), ollama_model: ollamaModel } }];
// Use {{$json.ollama_model}} in Ollama HTTP Request URL body
```

**Tier assignments by pipeline:**

| Pipeline | Tier | Reason |
|---|---|---|
| email_pipeline | hot | High frequency, simple classification |
| nanny_pipeline | hot | Classification only |
| report_ingestion | hot | Document type detection |
| invoice_pipeline | medium | Multi-field structured extraction |
| epos_pipeline | medium | Report parsing |
| accommodation_pipeline | medium | Report parsing |
| digest_pipeline | heavy | Long-form generation, reasoning |
| reconciliation_pipeline | heavy | Financial reasoning |
| personal_trainer_pipeline | heavy | Coaching narrative |

## 6a.6 Automation Workflows

Four n8n workflows. Workflows A–C activate in Phase 2. Workflow D activates in Phase 1.

**Workflow A — Weekly Scanner (Sunday 03:00):**
```
Schedule trigger → POST model-evaluator /api/scanner/run
→ Parse new_models[] → INSERT model_registry
→ If new_models > 0: POST /api/recommendations/generate
→ Telegram: "📦 {n} new Ollama models compatible with RTX 3060 — {names}. Review at /dashboard/models"
```

**Workflow B — Monthly Full Benchmark (1st of month, 04:00):**
```
Schedule trigger → SELECT installed models from model_registry
→ For each model × compatible tier: POST /api/models/{model}/benchmark?tier={tier}
→ POST /api/recommendations/generate
→ If any DEPLOY rec with delta > 5%: Telegram alert with model name, tier, delta
→ Else: INSERT audit_log (result='no_significant_improvements')
```

**Workflow C — New Model Auto-Bench (webhook, triggered by Workflow A):**
```
Webhook trigger (new model name) → POST /api/models/{model}/pull
→ POST /api/models/{model}/benchmark?tier=hot  (quick check, hot tier only)
→ Compare composite score vs current hot tier model
→ If improvement > 3%: Telegram alert for manual review
→ Else: silent — INSERT model_registry.notes = 'below threshold'
```

**Workflow D — Manual Trigger (activate in Phase 1 Step 11):**
```
POST /webhook/model-evaluator-manual
Body: { "action": "pull|benchmark|deploy|scan|rollback", "model": string, "tier": string }
→ Route to appropriate model-evaluator API endpoint
→ Telegram confirmation of action taken
```

## 6a.7 Rollback

If a newly deployed model causes pipeline issues (wrong outputs, format failures, unexpected behaviour):

```bash
# Rollback via API — restores previous model for that tier
curl -X POST "http://localhost:8080/api/models/{model}/rollback?tier={tier}"
# Automatically updates static_context.model.tiers
# n8n pipelines pick up the rollback on next execution — no restart needed
```

Rollback logic: finds the second-best scored model for that tier in `model_scores`, deploys it. If no prior benchmarked alternative: manually re-deploy the previous model via `/api/models/{model}/deploy/{tier}`.

---

# PART 7: PHASE 2 BUILD — Weeks 7–12

## 7.1 Goal and Deliverables

**Goal:** Open banking, automated reconciliation, rent tracking, fitness tracking, staff database.

**Deliverables:**
- **Phase 1 hardening: Vault auto-unseal** (vault-autounseal.sh + systemd service)
- **Phase 1 hardening: Authelia SSO** (TOTP 2FA across all web UIs)
- **Phase 1 hardening: Model evaluator benchmark runs** (meaningful now that real data exists)
- **Disaster recovery scripts** (backup-all.sh, bootstrap.sh, restore.sh — see Section 7.3)
- **Local Dreaming workflow** (nightly audit_log review → heuristics.md → Master Router context)
- **CI Auto-Fix** (GitHub Actions SQL tests + Claude Code auto-fix for init_placeholder and RLS changes)
- NatWest + RBS Open Banking API (replaces CSV import)
- Automated bank reconciliation pipeline (Xero cross-reference, discrepancy flagging)
- Reconciliation_explainer AI worker (Sonnet — advisory summaries only)
- Rent reconciliation tracker (7 properties: expected vs received, arrears alerts)
- Pub cashflow forecast pipeline (30/60/90-day model)
- B&B occupancy dashboard (Caterbook forward bookings panel)
- Garmin service deployment + personal_trainer pipeline
- Garmin weekly coaching digest (Sunday 08:00)
- HR and staff database (schema already in Phase 1 init)
- Holiday entitlement calculator (statutory pro-rata, NOT 12.07%)
- Staff compliance tracker (right-to-work, training expiry, 30/14-day alerts)
- VAT tracking alerts from Xero data
- Enhanced Metabase panels for all Phase 2 data
- **Atlas database migrations** (replaces manual init-db.sql edits from Phase 2 onward)
- **Events data tiering** (storage_tier column + quarterly HDD archival via tablespaces)
- **AI worker model drift alerting** (7-day rolling confidence + Prometheus alert at <0.80)
- **Reconciliation_explainer upgraded** (proactive hypothesis + suggested_action JSON)

## 7.2 Key Phase 2 Additions

**Phase 1 hardening (complete these at the start of Phase 2, before new features):**

These were deferred from Phase 1 to avoid debugging bootstrap complexity before the system was proven. Now that the event backbone is validated, they are safe to add.

*Vault auto-unseal:* full script in Section 2 (Vault auto-unseal block). Install age, create machine-key from CPU serial, encrypt three unseal keys, create vault-autounseal.sh, enable systemd service. Test: reboot the P620, confirm Vault unseals within 2 minutes without human input.

*Authelia SSO:* configure `security/authelia/configuration.yml`. Single user, TOTP 2FA, Telegram backup auth. Apply to n8n (5678), Metabase (3000), Grafana (3001), Vault UI (8200), Open WebUI (8088).

*Model evaluator benchmarks:* with real production emails and invoices now processed, benchmarks are meaningful. Run the three benchmark API calls and generate recommendations (see Section 6a Step 9b, benchmark commands).

**Local Dreaming Workflow (Phase 2 addition — after 30+ days of pipeline data):**

Inspired by Anthropic's Dreaming feature (shipped May 2026), this is the local implementation.
A nightly n8n workflow reads the audit_log for the past 24 hours, identifies patterns in
AI worker failures, and writes structured learnings to a heuristics file that the Master
Router reads into context at the start of each batch run.

```
Schedule: daily 02:00 (after all pipelines have run)
n8n Workflow H — Local Dreaming
↓
Query audit_log for last 24h:
  SELECT ai_worker, result, ai_parsed->'reasoning', ai_parsed->'confidence_score'
  FROM audit_log
  WHERE created_at > NOW() - INTERVAL '24 hours'
  AND result IN ('escalate', 'fail')
  ORDER BY created_at DESC
↓
Haiku generates a structured heuristics update:
  "What patterns caused failures today? What should the Master Router know tomorrow?"
  Input: failure records | Output: 3-5 bullet points max
↓
Append to /home_ai/.claude/dreaming/heuristics.md (max 3,000 chars — rotate weekly)
↓
If new high-impact pattern found: Telegram "🧠 Dreaming: new heuristic added — [summary]"
```

Example heuristic output:
```markdown
## 2026-05-15 Patterns
- St Austell invoices with handwritten corrections fail extraction at hot tier —
  escalate directly to medium when supplier_name contains "St Austell"
- Caterbook report emails from mobile app have different HTML structure —
  pdfplumber fails, use MarkItDown fallback
- Nanny emails from school.cornwall.gov.uk mis-classified as junk —
  add to email_classifier positive examples
```

**CI Auto-Fix for init_placeholder and RLS changes (Phase 2 hardening):**

Once the `/home_ai` repo has GitHub Actions CI, Claude Code's CI integration
can watch for failing SQL tests and auto-fix PRs.

Add `.github/workflows/sql-tests.yml`:
```yaml
name: SQL Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16.4
        env: { POSTGRES_PASSWORD: test }
    steps:
      - uses: actions/checkout@v4
      - name: Apply schema
        run: psql $DATABASE_URL < postgres/init-db.sql
      - name: Assert no init_placeholder signatures
        run: |
          COUNT=$(psql $DATABASE_URL -t -c \
            "SELECT COUNT(*) FROM events WHERE payload_signature='init_placeholder'")
          [ "$COUNT" -eq 0 ] || (echo "FAIL: init_placeholder found" && exit 1)
      - name: Assert RLS policies present
        run: |
          COUNT=$(psql $DATABASE_URL -t -c \
            "SELECT COUNT(*) FROM pg_policies WHERE policyname='entity_isolation'")
          [ "$COUNT" -ge 10 ] || (echo "FAIL: missing RLS policies" && exit 1)
```

With this in place, Claude Code's CI Auto-Fix will automatically open a PR with
corrected SQL when either test fails on a push. Turns the init_placeholder tech
debt from "flag and defer" to "auto-fixed on next push."

**NatWest Open Banking:**
Register at developer.natwest.com. OAuth 2.0 with 90-day consent refresh. Replace the bank CSV import pipeline with an Open Banking API pull. Store tokens in Vault at `secret/natwest/openbanking`.

**Reconciliation explainer — proactive hypotheses (upgraded):**
- Trigger: daily batch of open reconciliation_flags
- Sonnet generates explanation, hypothesis, and suggested action per flag
- Output written to reconciliation_flags.description
- Included in digest — never auto-posts to Xero

Updated `reconciliation_explainer` system prompt:
```
You are reviewing unreconciled bank transactions for Jo's businesses.
For each discrepancy produce three things:
1. EXPLAIN: describe the mismatch in plain English (amounts, dates, payee).
2. HYPOTHESISE: the single most likely cause, citing specific evidence from
   the transaction (timing, amount patterns, known supplier cycles).
3. SUGGEST: one specific action Jo can confirm or dismiss.

Return valid JSON:
{
  "explanation": "plain English mismatch description",
  "hypothesis": "most likely cause with reasoning",
  "suggested_action": "e.g. Link to Caterbook Wedding deposit ref W24-087",
  "confidence": "high | medium | low",
  "requires_human": true
}

Good hypothesis examples:
  "NatWest credit of 500 is likely the Wedding deposit for 14 June not yet
   keyed into Caterbook — amount matches standard deposit rate, timing is
   6 weeks ahead of booking date."
  "The 1842.50 debit likely matches St Austell Brewery INV-2026-0847 —
   same amount, same payee, within payment terms window."

Output is advisory only. No action is taken until Jo confirms.
```

**Atlas database migrations (Phase 2 onward):**

From Phase 2 forward all schema changes go through numbered Atlas migration files.
`init-db.sql` is the Phase 1 baseline — never edited again.

```bash
mkdir -p /home_ai/postgres/migrations

# Example V2 migration — add storage_tier column:
cat > /home_ai/postgres/migrations/V2__storage_tier.sql << 'SQL'
ALTER TABLE events ADD COLUMN IF NOT EXISTS storage_tier TEXT DEFAULT 'hot';
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_events_tier
  ON events (storage_tier, created_at);
SQL

# Apply via Atlas:
docker run --rm --network home_ai_ai-internal \
  -v /home_ai/postgres/migrations:/migrations \
  arigaio/atlas:latest migrate apply \
  --url "postgres://homeai_pipeline:PASSWORD@postgres:5432/homeai?sslmode=disable" \
  --dir "file:///migrations"
```

Rule: every schema change = a new `V{n}__description.sql` committed to git before applying.
Never ALTER tables by hand once live data exists.

**Events data tiering (PostgreSQL tablespaces):**

Events older than 90 days move from NVMe SSD to 4TB HDD transparently — queries still work.

```sql
-- Create HDD tablespace once (postgres superuser required):
CREATE TABLESPACE hdd_archive LOCATION '/mnt/hdd/pg_tablespace';

-- Quarterly archival n8n workflow (1st Jan/Apr/Jul/Oct at 05:00):
DO $arch$
DECLARE pname TEXT; cutoff DATE := CURRENT_DATE - INTERVAL '90 days';
BEGIN
  FOR pname IN
    SELECT tablename FROM pg_tables
    WHERE tablename LIKE 'events_2%' AND schemaname = 'public'
      AND tablename < 'events_' || TO_CHAR(cutoff, 'YYYY_MM')
  LOOP
    EXECUTE format('ALTER TABLE %I SET TABLESPACE hdd_archive', pname);
    EXECUTE format(
      'UPDATE %I SET storage_tier = $1 WHERE storage_tier = $2', pname)
      USING 'archive', 'hot';
    RAISE NOTICE 'Archived partition: %', pname;
  END LOOP;
END $arch$;
```

Add to seed-data.sql:
```sql
INSERT INTO static_context (key, entity_id, value) VALUES
('data.tiering', null,
 '{"hot_days":90,"archive_tablespace":"hdd_archive","archive_path":"/mnt/hdd/pg_tablespace"}')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
```

**AI worker model drift alerting:**

A 7-day rolling average confidence drop signals a prompt needs updating (supplier changed
invoice format, new email layout) rather than a pipeline failure.

Add to metrics exporter (`metrics-exporter/main.py`):
```python
@app.get("/metrics/ai_drift")
async def ai_drift_metrics():
    query = """
        SELECT ai_worker,
               ROUND(AVG((ai_parsed->>'confidence_score')::numeric), 3) AS avg_confidence,
               COUNT(*) AS sample_count
        FROM audit_log
        WHERE created_at > NOW() - INTERVAL '7 days'
          AND ai_worker IS NOT NULL
          AND ai_parsed->>'confidence_score' IS NOT NULL
          AND result != 'failure'
        GROUP BY ai_worker HAVING COUNT(*) >= 10
    """
    rows = await db.fetch(query)
    lines = []
    for r in rows:
        w = r["ai_worker"]
        lines.append(f'ai_worker_confidence_7d{{worker="{w}"}} {r["avg_confidence"]}')
        lines.append(f'ai_worker_samples_7d{{worker="{w}"}} {r["sample_count"]}')
    return Response("\n".join(lines), media_type="text/plain")
```

Add to `monitoring/prometheus-rules/alerts.yml`:
```yaml
- alert: AIWorkerDrift
  expr: ai_worker_confidence_7d < 0.80
  for: 5d
  labels:
    severity: warning
  annotations:
    summary: "AI worker {{ $labels.worker }} confidence below 0.80 for 5+ days"
    description: >
      Source document format likely changed. Review recent flagged samples in
      audit_log and update the worker prompt. Check static_context ai.thresholds
      for the configured minimum threshold for this worker.

- alert: AIWorkerSampleDrop
  expr: ai_worker_samples_7d < 5
  for: 2d
  labels:
    severity: info
  annotations:
    summary: "AI worker {{ $labels.worker }} very few samples — pipeline may have stalled"
```

**Garmin service (deploy now in Phase 2):**
```bash
docker compose --profile phase2 up -d garmin-service
```
See Garmin service implementation — deploy same pattern as pdfplumber service, using `garminconnect` Python library. Credentials from Vault at `secret/garmin`.

**Personal trainer pipeline:**
- Daily at 05:30: call Garmin service, upsert garmin_daily_summary + garmin_sleep + garmin_body_metrics
- Sunday at 08:00: query last 7 days, call Sonnet fitness_coach worker, write to digest Sunday section

**HR pipeline:**
- Daily compliance check: query staff for right_to_work_expiry < 30 days, training expiry < 14 days
- Holiday entitlement recalculation: `remaining = statutory_days - used_days` (pro-rata for part-time)
- NEVER use 12.07% accrual method

**Model Stack Evaluator automation (activate in Phase 2):**

Start the model evaluator n8n automation workflows now that the system has real operational data to benchmark against:

```bash
# Activate in n8n (set these workflows to Active):
# - Workflow A: Weekly Model Scanner (Sunday 03:00)
# - Workflow B: Monthly Full Benchmark (1st of month, 04:00)
# - Workflow C: New Model Alert (webhook, triggered by Workflow A)
```

**Workflow A — Weekly Model Scan (Sunday 03:00):**
- POST to model-evaluator `/api/scanner/run`
- Insert new discoveries into `model_registry`
- If new models found: refresh recommendations, Telegram alert: `"📦 {n} new models — {names}. Check /dashboard/models"`

**Workflow B — Monthly Full Benchmark (1st of month, 04:00):**
- For each installed model × each compatible tier: POST `/api/models/{model}/benchmark?tier={tier}`
- POST `/api/recommendations/generate`
- If any DEPLOY recommendation with composite_delta > 5%: Telegram alert with specifics
- If no improvement: silent audit_log entry only

**Workflow C — New Model Alert:**
- Triggered by Workflow A when new model detected
- Auto-pull + quick Tier 1 benchmark
- If score > current Tier 1 + 3%: Telegram alert for review
- Below threshold: logged silently, no alert

## 7.3 Structured Outputs / JSON Schema Constrained Generation

**Phase 1 hardening — sequenced ahead of §7.4–§7.7.** This is a reliability foundation: every AI worker produces guaranteed-valid JSON matching a versioned schema, instead of being prompted to "return JSON" and parsed downstream. Hallucinated field names drop to 0% by construction. Done once; every subsequent AI worker inherits it for free. Retrofitting after §7.4–§7.7 ship would be ~3× the work.

**Components:**

- New directory `/home_ai/ai_schemas/` — one JSON Schema file per AI worker, version-controlled in git. Initial set:
  - `email-classifier.schema.json` — OutcomeObject + email_category + entity_id
  - `invoice-extract.schema.json` — net/vat/gross/dates/line items
  - `nanny-classify.schema.json` — child_event fields
  - `report-parser.schema.json` — generic report fields
  - `dreaming-proposals.schema.json` — heuristic proposals
  - `reconciliation-explainer.schema.json` — hypothesis/action/confidence
- Update every n8n Code node that calls Ollama: use the `format` parameter (Ollama JSON Schema constrained generation, available since v0.5):
  ```javascript
  const response = await ollama.generate({
    model: 'qwen2.5:7b',
    prompt: systemPrompt + userContent,
    format: {
      type: 'object',
      properties: {
        status:     { type: 'string', enum: ['success', 'escalate', 'fail'] },
        confidence: { type: 'number', minimum: 0, maximum: 1 },
        reasoning:  { type: 'string' },
        supplier_name: { type: 'string' },
        gross_amount:  { type: 'number' }
      },
      required: ['status', 'confidence', 'reasoning']
    }
  });
  // response is guaranteed valid JSON matching the schema
  ```
- Update every Anthropic call site (`services/bot-responder/responder.py`, `scripts/u36-invoice-haiku-fallback.sh`, `scripts/u36-dreaming-nightly.sh`, `scripts/u36-reconciliation-explainer.sh`) to use **tool use with `input_schema`** instead of "return JSON" in the system prompt. The model output is then a schema-validated tool call, not a free-text JSON blob.
- Migration V44 adds `schema_version TEXT` to `audit_log` so we can track which workers are on which schema generation. Workers emit `schema_version = '<filename>@<git-sha>'` (e.g. `email-classifier.schema.json@1.2.0`).

**Acceptance:**

- All 6 Ollama-using Code nodes use the `format` parameter.
- All 4 Anthropic call sites use tool-use with schemas.
- `ai_schemas/` directory committed with version markers.
- Synthetic-email-suite passes 100 runs with 0 JSON parse errors.
- `audit_log.schema_version` populated for every new AI worker run.

**Sequencing:** ship §7.3 BEFORE §7.4–§7.7. The new pipelines (guest reviews, Companies House, Land Registry, VAT) should be born on this pattern, not retrofitted.

---

## 7.4 Guest Review Response Assistant ★ PRIORITY

**Highest-value Phase 2 deliverable.** Hospitality review response time directly affects star averages, which affect bookings. Manual daily checking is unreliable; full auto-posting is risky. Action Queue pattern (Sonnet drafts → Jo approves → manual post) hits the right balance.

**Goal:** catch new Google + TripAdvisor reviews for the Malthouse (pub) and the Sandwich shop within 48 hours. Sonnet pre-drafts a context-aware response. Surfaced in the Action Queue. Jo approves/edits; posting stays manual.

**Architecture:**

```
Weekly cron 09:00 Mon
  → Playwright scraper (extends competitor-watch pattern)
      → Google Business listings for both locations
      → TripAdvisor pages for both locations
    → INSERT into guest_reviews (idempotent on source+review_id)
      → Sonnet drafter (cached system prompt, location-aware tone)
        → INSERT into review_drafts
          → Action Queue card type 'guest_review'
            → Jo approves / edits / rejects in dashboard
              → manual post to Google/TripAdvisor (no auto-post)
  → Telegram alert if any review ≤3 stars (immediate, not weekly)
```

**Tables (V44 adds both):**

- `guest_reviews` (review_id TEXT, source TEXT CHECK IN ('google','tripadvisor'), location TEXT CHECK IN ('malthouse','sandwich'), rating INT, body TEXT, posted_at TIMESTAMPTZ, scraped_at TIMESTAMPTZ DEFAULT now(), raw_payload JSONB, status TEXT DEFAULT 'new' CHECK IN ('new','drafted','approved','posted','rejected'), entity_id INT, PRIMARY KEY (source, review_id))
- `review_drafts` (id BIGSERIAL PK, review_id TEXT, source TEXT, draft_text TEXT, sonnet_model TEXT, prompt_cache_hit BOOL, created_at, approved_by TEXT, approved_at TIMESTAMPTZ, posted_at TIMESTAMPTZ, rejected_at TIMESTAMPTZ, FK (source, review_id) → guest_reviews)
- RLS: entity_id scoped per the standard pattern.

**Playwright scraper** (`services/review-scraper/`): extends the existing competitor-watch container. Per location, scrape last 30 days of reviews. Use the same anti-bot patterns (random delays, real UA). Output JSON normalised to the `guest_reviews` shape.

**Sonnet drafter system prompt** (cached, ephemeral):

- Hospitality tone: warm, specific, no apologetic-doormat.
- Location-aware: pub responses differ in tone from cafe responses (pub = "see you in for a pint", cafe = "pop in for a coffee").
- Address specifics from the review — never generic "thank you for your review".
- For 1-3 star reviews: acknowledge the specific issue, offer a path forward (manager email, return visit), no defensiveness, no "I'm sorry you feel that way".
- Never invent a manager name — use "the manager" or "Jo (owner)".
- 80-150 words. No markdown formatting (review platforms strip it).

**Action Queue integration:** new card type `guest_review` in the dashboard. Renders review text on the left, draft on the right, [Approve] [Edit] [Reject] buttons. Edit opens an inline textarea. Approve marks draft `approved_at = now()` and surfaces a "copy to clipboard" + link to the review platform. Posted_at set manually when Jo confirms post.

**Telegram alert (immediate, not batched):**

- Trigger: any new `guest_reviews` row with rating ≤3.
- Body: `"⭐ {rating}★ review on {source} for {location} — {first 100 chars of body}\nResponse drafted in Action Queue."`
- Routes through `notify-telegram.sh` with source='guest-review' for `telegram_outbox` audit.

**Acceptance gates:**

- Playwright scraper successfully fetches last 7 days of reviews from Google Business + TripAdvisor for both locations (manual smoke run).
- First Sonnet draft generated for at least one new review; output reads as appropriate hospitality tone (Jo's sanity check).
- Action Queue card renders with approve/edit/reject; clicking approve advances status.
- Telegram alert fires on a synthetic 2-star test review insertion.
- Idempotency: re-running the scraper on the same day doesn't create duplicate `guest_reviews` rows.

---

## 7.5 Companies House API Integration

**Goal:** track filing deadlines for Atlantic Road Trading Ltd (ARTL) and Atlantic Road Estates Limited (AREL); on-demand company verification for any supplier/tenant. Free API, no auth needed. Catches the £150 late confirmation-statement penalty and £150–£1500 late-accounts penalties before they happen.

**Endpoint** (no auth header required for basic queries):

```
GET https://api.company-information.service.gov.uk/company/{company_number}
```

Returns: name, registered address, accounts_next_due_date, confirmation_statement_next_due_date, officers, persons_of_significant_control, filing_history.

**One-time setup:** Jo provides ARTL and AREL company numbers. `UPDATE entities SET companies_house_number = '<num>'` for entity_id=1 and 2.

**Components:**

- Weekly cron Mon 04:00 (`scripts/u37-companies-house-sync.sh`): for each entity with `companies_house_number`, hit the API; insert snapshot row; compute `days_until` for both deadlines.
- Daily digest section: "Filing deadlines in next 30 days" (auto-hidden if empty list).
- On-demand: bot-responder gets a `verify_company` tool slug. Jo emails the bot "verify company 12345678" → Sonnet replies with name, status, registered address, last filed accounts date.

**Tables (V44 adds):**

- `companies_house_log` (id, snapshot_at, company_number, name TEXT, status TEXT, registered_address JSONB, accounts_next_due_date DATE, confirmation_statement_next_due_date DATE, raw_payload JSONB)
- `companies_house_alerts` (id, entity_id, alert_type TEXT CHECK IN ('accounts_due','confirmation_due'), due_date DATE, days_until INT, status TEXT DEFAULT 'open' CHECK IN ('open','acknowledged','filed'), created_at)

**Alert rules:** insert into `companies_house_alerts` when `days_until <= 30` AND no open alert exists for that (entity, type, due_date) tuple (idempotent re-runs).

**Acceptance:**

- `companies_house_log` has at least 1 row per company after first weekly run.
- Synthetic test: temporarily set ARTL's confirmation due date to today+25 via a stub of the API response; alert row created; digest shows it.
- bot-responder `verify_company` tool returns sane JSON for the Sandercock companies (real-data smoke test).
- `bot_sender_whitelist` integration: `verify_company` is a public-style query (any whitelisted sender can ask).

---

## 7.6 Land Registry Price Paid API

**Goal:** monthly comparable-sales report for the 7 Atlantic Road Estates properties. Real market data, no manual Rightmove checking. Genuine market intelligence for insurance renewal, refinancing, and periodic valuation sanity checks. Free, no auth.

**Endpoint** (CSV response):

```
GET https://landregistry.data.gov.uk/app/ppd/ppd_data.csv?postcode={postcode}&from={date}
```

Returns: all UK property sales in a postcode area, with prices and dates.

**One-time setup:** Jo provides 7 property postcodes + acquisition prices + dates. Seed table `properties` (NEW — V44 migration). Cornwall TR-postcodes for most; 1-2 elsewhere; Jo to confirm exact list.

**Components:**

- Monthly cron 1st 04:30 (`scripts/u37-land-registry-sync.sh`): for each property in `properties`, fetch last 90 days of sales in that postcode; parse CSV; insert sale rows into log; compute average + sample count.
- Daily digest (1st of month only): "Estates market — last 90d sales by postcode" with avg price, sample size, delta vs Jo's acquisition price.

**Tables (V44 adds):**

- `properties` (id, entity_id DEFAULT 2, postcode TEXT, address TEXT, acquisition_date DATE, acquisition_price_gbp NUMERIC(12,2), notes TEXT)
- `property_market_log` (id, property_id FK, snapshot_at, sales JSONB (array of {date, price, address, type, tenure}), avg_price NUMERIC(12,2), sample_n INT)
- `v_property_comparable_summary` — view joining `properties` to most recent `property_market_log`, with delta vs acquisition price formatted.

**Acceptance:**

- `property_market_log` has 1 row per property after first monthly run.
- `v_property_comparable_summary` returns 7 rows, each with sensible `avg_price` (within plausible market range for the postcode).
- Digest renders the section on a 1st-of-month synthetic test (force-trigger via cron line in advance of the 1st).
- Failure mode: if Land Registry endpoint returns empty CSV (rural postcode with no recent sales), property_market_log row inserted with `sample_n=0` and digest renders "no recent comparable sales in this postcode".

---

## 7.7 VAT Return Preparation Workflow (DORMANT)

**Goal:** quarterly, pre-fill UK VAT return Box 1-9 figures from Xero data; flag anomalies; surface in Action Queue. Jo still files manually through Xero — this just means the figures are pre-checked and anomalies caught before submission. Reduces quarterly accountant review burden.

**Dormancy:** depends on Pipeline 3 (Xero sync) which is parked on Xero support response. Build the schema + logic now; activate when Xero unblocks.

**Gating mechanism:** new `system_state` table (V44) with rows like `(key='p3_xero', value='parked')`. The quarterly cron checks this before doing any work. When Xero comes back: `UPDATE system_state SET value='live' WHERE key='p3_xero'`.

**Components:**

- Quarterly cron 3rd Apr/Jul/Oct/Jan 06:00 (`scripts/u37-vat-return-prep.sh`):
  1. Check `system_state.p3_xero='live'`. If parked, log "p3_xero=parked, skipping" and exit 0.
  2. Pull last quarter's Xero figures via Xero API.
  3. Structure into Box 1-9 (UK VAT return format).
  4. Run anomaly rules.
  5. INSERT `vat_returns_log` row + 1 Action Queue card per anomaly.
- Anomaly rules (V44 logic):
  - Box 4 (input VAT) > 2× rolling 4-quarter average → severity 'high'
  - Any `vendor_invoice_inbox.gross_amount > 500` without matching `bank_transactions` row → severity 'medium'
  - `(Net standard-rated sales) × 0.20` vs Box 1 difference > £20 → severity 'medium'

**Tables (V44 adds):**

- `vat_returns_log` (id, entity_id, quarter_end DATE, box_1_through_9 JSONB, anomalies JSONB (array), status TEXT DEFAULT 'draft' CHECK IN ('draft','reviewed','filed'), created_at, accountant_reviewed_at, filed_at)
- `system_state` (key TEXT PK, value TEXT, updated_at). Seed `('p3_xero','parked')`.

**Action Queue card type:** `vat_review` rendering each Box 1-9 with the figure + any flags on that box. Approve = mark `status='reviewed'`. Filed = `status='filed'` + `filed_at = now()` (manual after Jo files in Xero).

**Acceptance:**

- Schema applied (V44 includes the `system_state` seed).
- Dormancy verified: `bash u37-vat-return-prep.sh` logs "p3_xero=parked, skipping" and inserts no rows.
- Activation simulation: temporarily `UPDATE system_state SET value='live' WHERE key='p3_xero'` AND populate a synthetic Xero fixture; verify Box 1-9 produced and one anomaly flagged. Revert.

---

## 7.8 Disaster Recovery Scripts

**Goal:** Fresh Ubuntu 26.04 install → fully running system with all data restored in 2-3 hours. Build at the end of Milestone C. Test on a VM before you need them on real hardware.

**Recovery time target:** ~45 minutes of active work + model download time in background.

**Three scripts — all live at `/home_ai/scripts/`:**

### backup-all.sh (run weekly via cron, end of Milestone C)

```bash
#!/bin/bash
# /home_ai/scripts/backup-all.sh — weekly cron: 0 3 * * 0
set -euo pipefail
BACKUP_DIR="/mnt/hdd/backups/homeai-$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

# PostgreSQL
docker exec homeai-postgres pg_dump -U postgres homeai | gzip > "$BACKUP_DIR/homeai.sql.gz"
docker exec homeai-postgres pg_dump -U postgres metabase_app | gzip > "$BACKUP_DIR/metabase_app.sql.gz"

# Vault snapshot
docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault \
  vault operator raft snapshot save /vault/data/snapshot.snap
docker cp homeai-vault:/vault/data/snapshot.snap "$BACKUP_DIR/vault-snapshot.snap"

# n8n workflow exports
mkdir -p "$BACKUP_DIR/n8n-workflows"
curl -s -H "X-N8N-API-KEY: $N8N_API_KEY" http://localhost:5678/api/v1/workflows \
  | jq -r '.data[] | @json' > "$BACKUP_DIR/n8n-workflows/all-workflows.jsonl"

# Git push
cd /home_ai && git add -A && \
  git commit -m "backup: $(date +%Y-%m-%d) automated snapshot" --allow-empty && \
  git push origin main

# Restic to NAS + OneDrive
restic -r /mnt/mycloud/homeai-backup backup "$BACKUP_DIR" --tag weekly-snapshot

echo "✓ Backup complete: $BACKUP_DIR"
```

Note: Vault snapshot restores encrypted data but still requires manual unseal with offline keys — correct security behaviour.

### bootstrap.sh (runs once on fresh hardware)

```bash
#!/bin/bash
# /home_ai/scripts/bootstrap.sh — prepares fresh Ubuntu 26.04 for Home AI
set -euo pipefail

sudo apt-get update && sudo apt-get install -y \
  docker.io docker-compose-v2 git curl age openssh-server ufw

sudo usermod -aG docker "$USER"
sudo apt-get install -y nvidia-container-toolkit && sudo systemctl restart docker

# Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
echo "→ Run: sudo tailscale up  (authenticate with your account)"

# Clone repo and pull images
git clone git@github.com:YOUR_USERNAME/home-ai.git /home_ai
cd /home_ai && docker compose pull

echo "✓ Bootstrap complete."
echo "  Next: run ./scripts/restore.sh BACKUP_DIR"
echo "  Or fresh start: ./start.sh → Phase 1 Milestone A"
```

### restore.sh (restores data on new hardware)

```bash
#!/bin/bash
# /home_ai/scripts/restore.sh BACKUP_DIR
# Run AFTER bootstrap.sh and AFTER ./start.sh brings services up
set -euo pipefail
BACKUP_DIR="${1:?Usage: restore.sh BACKUP_DIR}"

# PostgreSQL
docker exec -i homeai-postgres psql -U postgres -c "DROP DATABASE IF EXISTS homeai; CREATE DATABASE homeai;"
gunzip -c "$BACKUP_DIR/homeai.sql.gz" | docker exec -i homeai-postgres psql -U postgres homeai

docker exec -i homeai-postgres psql -U postgres -c "DROP DATABASE IF EXISTS metabase_app; CREATE DATABASE metabase_app;"
gunzip -c "$BACKUP_DIR/metabase_app.sql.gz" | docker exec -i homeai-postgres psql -U postgres metabase_app

# Vault
docker cp "$BACKUP_DIR/vault-snapshot.snap" homeai-vault:/tmp/snapshot.snap
docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault \
  vault operator raft snapshot restore /tmp/snapshot.snap

# n8n workflows
while IFS= read -r workflow; do
  curl -s -X POST -H "X-N8N-API-KEY: $N8N_API_KEY" \
    -H "Content-Type: application/json" -d "$workflow" \
    http://localhost:5678/api/v1/workflows
done < "$BACKUP_DIR/n8n-workflows/all-workflows.jsonl"

# Ollama models (background — large files)
docker exec homeai-ollama ollama pull qwen3:8b &
docker exec homeai-ollama ollama pull qwen3:14b &
echo "→ Models downloading. Pull llama3.3:70b separately (42GB)."

echo ""
echo "✓ Restore complete. Manual steps remaining (~45 min):"
echo "  1. sudo tailscale up"
echo "  2. Re-run OAuth flows: Gmail, Xero, Google Calendar"  
echo "  3. Unseal Vault with offline keys if needed"
echo "  4. Run /verify-phase1 to confirm system health"
```

**Manual re-authorisation after restore (~45 min total):**

| Item | Time |
|---|---|
| Tailscale re-enroll | 2 min |
| Gmail OAuth (both accounts) | 10 min |
| Xero OAuth (Trading + Estates) | 10 min |
| Google Calendar/Sheets | 5 min |
| Vault unseal (offline keys) | 5 min |
| Open WebUI login | 1 min |
| Run /verify-phase1 checklist | 15 min |

**Store the private GitHub repo URL in your password manager** — it's the single most important recovery artifact after the Vault unseal keys.

## 7.9 Phase 2 Testing Checklist

```
[ ] NatWest Open Banking: bank_transactions populated without CSV upload
[ ] Reconciliation flag raised for unmatched transaction
[ ] Reconciliation_explainer: flag has plain-English description (never blank)
[ ] Rent payment: bank transaction matching tenant name → rent_payments.status='received'
[ ] Arrears: rent not received by due_date+3 days → rent.arrears event, Telegram alert
[ ] Garmin service: curl http://localhost:8002/healthcheck → {"status":"ok","vault":"connected"}
[ ] Garmin daily: yesterday's data in garmin_daily_summary
[ ] Garmin body: weight + body_fat_pct in garmin_body_metrics (Garmin Index scale)
[ ] Sunday digest: weekly fitness coaching section present
[ ] HR: staff record with right_to_work_expiry in 25 days → compliance alert in digest
[ ] Holiday: remaining_days correctly calculated (not 12.07%)
[ ] Model evaluator: curl http://localhost:8080/api/models → returns model_registry rows
[ ] Model evaluator: model_scores populated after initial benchmark (Step 9b)
[ ] Model evaluator: static_context model.tiers correct and readable from n8n
[ ] Weekly scan workflow: activates without error, scan_log row created
[ ] Monthly benchmark: activates, benchmark_results rows created for installed models
[ ] New model alert: manually trigger Workflow C → Telegram message received if threshold met
[ ] Pipeline tier switching: update static_context model.tiers → n8n picks up new model without restart
```

---

# PART 8: PHASE 3 BUILD — Weeks 13–18

## 8.1 Goal and Deliverables

**Goal:** Calendar, tasks, property management, document control, self-test suite, custom dashboard v2.

**Deliverables:**
- Google Calendar sync (personal, work, kids — 3 calendars)
- Task engine (manual + auto-generated from email triage)
- Property database (7 properties: full schema, compliance dates, renewals)
- Document control system (versioning, expiry alerts, approval workflow)
- Scanner → Google Drive → OCR → PostgreSQL workflow
- **PostgreSQL MCP server** (read-only tools for Claude.ai live data queries — port 8005)
- **Obsidian vault MCP server** (read/write vault tools for Claude.ai — port 8007)
- **MarkItDown service** (audio, images, Word, YouTube → markdown — port 8006)
- Playwright browser automation service
- Whole-life Next.js dashboard v2 (replaces Metabase as primary)
- Self-test suite (HomeAIDiagnostics.jsx + backend API)
- Cars project folders (4 vehicles: MOT, insurance, service, V5)
- Obsidian vault setup (three-tier memory, daily notes, People graph)
- Authelia SSO fully configured across all services

## 8.1b Paperless-ngx — Document Digitisation Pipeline

**Purpose:** Intelligent batch scanning, OCR, document splitting, and auto-tagging of physical correspondence. The Brother ADS-2800W drops scans into a Samba consume folder on the P620. Paperless-ngx processes them and the Home AI system enriches and routes the results.

**Architecture:**
```
ADS-2800W (one-touch "AI BATCH" shortcut)
    ↓ SMB to /home_ai/paperless/consume
Paperless-ngx (Docker — splits, OCR, auto-tags)
    ↓ REST API webhook (document_added event)
n8n Workflow (Haiku enrichment + routing)
    ↓ routes by document type
PostgreSQL documents table + Obsidian vault
    ↓ rclone
Google Drive archive (mobile access + OneDrive backup)
```

**docker-compose.yml addition (Phase 3 profile):**
```yaml
  paperless-webserver:
    image: ghcr.io/paperless-ngx/paperless-ngx:latest
    container_name: homeai-paperless
    networks: [ai-internal, ai-services]
    depends_on:
      postgres: {condition: service_healthy}
      redis: {condition: service_started}
    volumes:
      - paperless_data:/usr/src/paperless/data
      - paperless_media:/usr/src/paperless/media
      - paperless_export:/usr/src/paperless/export
      - /home_ai/paperless/consume:/usr/src/paperless/consume
    environment:
      PAPERLESS_REDIS: "redis://redis:6379"
      PAPERLESS_DBHOST: "postgres"
      PAPERLESS_DBNAME: "paperless"
      PAPERLESS_DBUSER: "paperless_app"
      PAPERLESS_DBPASS: "${PAPERLESS_DB_PASSWORD}"
      PAPERLESS_SECRET_KEY: "${PAPERLESS_SECRET_KEY}"
      PAPERLESS_OCR_LANGUAGE: "eng"
      PAPERLESS_CONSUMER_POLLING: "30"
      PAPERLESS_CONSUMER_DELETE_DUPLICATES: "true"
      PAPERLESS_CONSUMER_RECURSIVE: "true"
      PAPERLESS_FILENAME_FORMAT: "{created_year}/{correspondent}/{title}"
      PAPERLESS_OCR_USER_ARGS: '{"optimize": 1, "pdfa_image_compression": "lossless"}'
      PAPERLESS_POST_CONSUME_SCRIPT: "/usr/src/paperless/scripts/notify-n8n.sh"
    ports: ["8011:8000"]
    profiles: ["phase3"]
    restart: unless-stopped
```

**Add Samba share for scanner consume folder:**
```bash
sudo apt install samba -y

# Add to /etc/samba/smb.conf:
cat >> /etc/samba/smb.conf << 'EOF'
[paperless-consume]
   path = /home_ai/paperless/consume
   browseable = yes
   writable = yes
   valid users = joly
   create mask = 0664
   directory mask = 0775
EOF

# Set Samba password (separate from Linux password):
sudo smbpasswd -a joly
sudo systemctl restart smbd

# Create consume directory:
mkdir -p /home_ai/paperless/consume
```

**Post-consume notification script (triggers n8n on each new document):**
```bash
# /home_ai/paperless/scripts/notify-n8n.sh
#!/bin/bash
# Called by Paperless-ngx after each document is processed
# Environment variables available: DOCUMENT_ID, DOCUMENT_FILE_NAME, DOCUMENT_CREATED
curl -s -X POST "http://n8n:5678/webhook/paperless-document-added" \
  -H "Content-Type: application/json" \
  -d "{\"document_id\": \"$DOCUMENT_ID\", \"filename\": \"$DOCUMENT_FILE_NAME\", \"created\": \"$DOCUMENT_CREATED\"}"
```

**n8n Workflow — Paperless Enrichment (Workflow I, Phase 3):**
```
Trigger: POST /webhook/paperless-document-added
↓
HTTP GET Paperless API: fetch document metadata + extracted text
  GET http://paperless:8000/api/documents/{id}/
  Authorization: Token {PAPERLESS_API_TOKEN from Vault}
↓
sanitiseForPrompt(extracted_text) → text_safe
↓
Haiku enrichment prompt:
  "Given this document text, identify:
   entity_id (1=Malthouse, 2=Estates, 3=Personal, 4=Family),
   category (invoice|contract|correspondence|statement|legal|compliance|medical|other),
   action_required (bool), action_deadline (date or null),
   correspondent (organisation or person name),
   key_dates (array of significant dates found),
   one_line_summary (max 100 chars)
   Return JSON only."
↓
OutcomeObject evaluation (confidence threshold)
↓
INSERT INTO documents (paperless_id, entity_id, category, correspondent,
  action_required, action_deadline, summary, extracted_text, created_at)
↓
If action_required=true: INSERT action_required event → Action Queue
If category='invoice': emit invoice.detected → Invoice Pipeline
If category='compliance' AND action_deadline: INSERT compliance_alert
If entity='Estates': update property compliance_dates if applicable
↓
Write to Obsidian vault:
  Significant correspondence → Resources/[correspondent]/
  Compliance docs → Areas/Estates/ or Areas/Malthouse/
  Personal → Areas/Personal/
↓
INSERT audit_log
```

**Rclone sync to Google Drive (weekly, after Restic backup):**
```bash
# Install rclone and configure Google Drive remote (run once interactively):
rclone config  # creates ~/.config/rclone/rclone.conf

# Add to cron (weekly Sunday 04:00, after Restic):
# 0 4 * * 0 rclone sync /home_ai/paperless/media/documents \
#   "gdrive:HomeAI/Documents" --transfers 4 --log-file /var/log/rclone.log

# Also sync to OneDrive for redundancy:
# rclone sync /home_ai/paperless/media/documents \
#   "onedrive:HomeAI/Documents" --transfers 4
```

**Scanner one-touch profile (configure via ADS-2800W web interface):**

| Setting | Value |
|---|---|
| Profile name | AI BATCH |
| Host address | P620 Tailscale IP (100.104.82.53) |
| Store directory | `paperless-consume` (Samba share name) |
| File type | Searchable PDF |
| Quality | 300 DPI |
| Skip Blank Page | **OFF** (blank pages = document separators) |
| 2-sided scan | ON (duplex) |
| ADF Auto Deskew | ON |

**Document separation workflow (physical):**
1. Sort correspondence into logical documents
2. Place a blank sheet between each document in the ADF stack
3. Press the "AI BATCH" one-touch button on the scanner
4. Walk away — Paperless splits at every blank page, OCRs, and auto-tags
5. Once weekly: open Paperless inbox (port 8011), spend 5 minutes verifying AI tags, click Archive

**Paperless auto-tagging rules (configure in Paperless UI after first 20 documents):**

```
Rule: "NatWest" in content → tag: banking, correspondent: NatWest
Rule: "St Austell Brewery" → tag: suppliers, entity: Trading
Rule: "Atlantic Road Estates" or "rent" → tag: property, entity: Estates  
Rule: "HMRC" or "VAT" → tag: tax, action_required: true
Rule: "EDF" or "British Gas" or "electricity" → tag: utilities
Rule: "Cornwall Council" → tag: compliance, action_required: true
```

**Vault secrets needed (add in Phase 3):**
```bash
docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault \
  vault kv put secret/paperless \
  api_token="YOUR_PAPERLESS_API_TOKEN" \
  db_password="$(openssl rand -base64 32)" \
  secret_key="$(openssl rand -base64 32)"
```

**Phase 5 stretch — AI document boundary detection:**

Once `gemma4:e4b` is in the model stack, replace blank page separators with vision-based boundary detection. The model analyses each page and identifies document starts based on: letterhead changes, date formatting, sender/recipient changes, document type changes. No physical separators needed — just load the ADF and press scan.

```python
# Phase 5 addition to the consume pipeline:
# Pre-processor that runs before Paperless-ngx sees the file
# Splits a multi-document PDF using gemma4:e4b vision analysis per page
```

## 8.2 Self-Test Suite

The self-test suite is a React component integrated into the Next.js dashboard at `/dashboard/diagnostics`.

**Component file:** `HomeAIDiagnostics.jsx` (30 tests across 8 categories: Infrastructure, Security, Database, Pipelines, Integrations, AI Layer, Backup, Data Integrity)

**Features:**
- Run All Tests button — sequential execution with real-time health score
- Category filter tabs — focus on failing categories
- Each test: severity indicator, status badge, value, expandable fix panel
- Fix panels: exact SQL, shell commands, webhook triggers, or procedures — with copy button
- Individual test re-run without full suite execution
- Amber/red visual state on failing categories

**Backend API (Next.js API routes):**
```
GET  /api/diagnostics/run-all      → SSE stream of results
GET  /api/diagnostics/run/:id      → single test result
POST /api/diagnostics/fix/:id      → apply fix (with confirmation for destructive actions)
GET  /api/diagnostics/history      → last 30 days from diagnostic_history table
```

**Test categories and severities:**
- Critical (red): PostgreSQL, Vault unsealed, Vault secrets, n8n workflows, epos partition, RLS, dead letters, Claude API, Ollama
- Warning (amber): Disk space, GPU, Xero sync, Garmin service, ICRTouch/Caterbook last report, stale leases, error rate
- Info (blue): Prompt injection count, API spend, backup integrity age

**n8n diagnostic workflow** (runs daily at 06:30, before digest):
- Execute all tests
- If any critical failure: Telegram [!] alert immediately
- If warnings only: include in digest SYSTEM section
- INSERT all results to diagnostic_history table

**Fix safety rules:**
- Auto-applicable (no confirmation): read-only SQL queries, container health checks
- Requires confirmation: any UPDATE/INSERT SQL, docker compose restart, webhook triggers
- Never automated: event replay (always requires human confirmation of root cause)
- Vault unseal: automated via vault-autounseal.service (systemd) on boot — manual only if auto-unseal fails

**Deploy Playwright service for Phase 3:**
```bash
docker compose --profile phase3 up -d playwright-service
```

## 8.3 Next.js Dashboard v2

**Build with Claude Code:** `claude` in the Next.js project directory → `"Build the whole-life dashboard from Part 8 of SPEC.md"`

### Design constraints — mobile-first, owner-centric

**Primary viewport is a phone screen.** Jo uses this at the pub, on the go. Desktop is secondary. Every design decision must pass the pub test: *can Jo approve an invoice, check last night's takings, and see what needs attention — with one hand, standing behind the bar?*

Layout rules:
- **Minimum touch target:** 44px height for all interactive elements
- **Approve button:** always thumb-reachable — bottom of screen, full-width on mobile
- **No horizontal scrolling** on any viewport
- **Swipe gestures:** left to flag, right to approve on Action Cards
- **Font size:** minimum 16px body text — readable in pub lighting
- **Contrast:** WCAG AA minimum — readable in bright sunlight outdoors

Stack: Next.js + Tailwind CSS + shadcn/ui. Responsive breakpoints: 390px (phone primary), 768px (tablet), 1280px (desktop).

### Information architecture — goals, not pipelines

The dashboard presents **what needs attention** and **what is happening**, not system internals. Jo should never need to know what a pipeline is.

**Primary route: `/` — Morning Command Center**

The home screen Jo sees every morning. One screenful of information.

```
┌──────────────────────────────────────┐
│  Good morning Jo.            08:00  │  ← Sonnet-generated narrative (3-4 sentences)
│  Sales up 10% yesterday.            │
│  1 invoice needs your attention.    │
│  Rent from Castle Rd received. ✓    │
├──────────────────────────────────────┤
│  [!] NEEDS YOU          2 items  →  │  ← Tap to open Action Queue
│  ✓  PUB            £2,847  last night│
│  ✓  RENT           All received     │
│  ○  CASHFLOW       £18.4k  30-day   │
│  ○  CHILDREN       No alerts        │
└──────────────────────────────────────┘
```

The narrative is generated by the digest_generator worker (Sonnet) at 06:45 as part of the existing digest pipeline. The home screen reads from the same `digest.ready` event payload — no separate AI call.

**Secondary route: `/action` — Kanban Goal Board**

The primary action surface. Items move through four columns as the AI processes them:

```
QUEUED          IN PROGRESS      NEEDS REVIEW     DONE
──────────       ───────────      ────────────     ────
Invoice          Invoice          Invoice          Invoice
St Austell       HMRC             EDF Energy  ✓   BT
£1,842           Extracting...    £847              £124
                                  ⚠ VAT mismatch
```

Column-to-status mapping (no backend changes required):

| Column | Record status | Event status |
|---|---|---|
| Queued | pending | invoice.detected |
| In Progress | pending + active pipeline | invoice.extracted (in progress) |
| Needs Review | requires_human = true | invoice.unmatched or anomaly |
| Done | approved / dismissed | actioned |

Cards move columns automatically via 15-second polling. The Kanban view makes it immediately clear what the AI is working on and what it has completed — without any technical knowledge required.

**Goal Card — mobile layout:**

```
┌─────────────────────────────────────────┐
│ ⚠  INVOICE  ·  TRADING                 │
│                                         │
│ St Austell Brewery                      │
│ £1,842.50  ·  Due 15 May               │
│                                         │
│ "VAT amount does not match supplier     │
│  record — 20% expected, 17.5% found."  │  ← reasoning always visible
│                                         │
│ Likely: Old VAT rate applied in error.  │  ← hypothesis (if available)
│ Try: Re-request corrected invoice.      │  ← suggested_action
│                                         │
│ [    FLAG    ]   [      APPROVE      ]  │  ← large touch targets
└─────────────────────────────────────────┘
```

Swipe right = Approve. Swipe left = Flag. Tap card body = expand detail view.

**Supporting routes:**

| Route | Content |
|---|---|
| `/pub` | EPoS trend (7 days), occupancy, cashing up status |
| `/finance` | Balances, overdue, 30/60-day payables, cashflow |
| `/properties` | 7 properties — rent, compliance, renewals |
| `/family` | Children — school, medical, urgent items |
| `/health` | Garmin yesterday + weekly coaching summary |
| `/system` | Pipeline health, dead letters, model evaluator |
| `/diagnostics` | Full self-test suite (Section 6 Phase 3) |
| `/playground` | Playground deployments log + new project trigger |

**Navigation:** Bottom tab bar on mobile (5 tabs max: Home, Action, Pub, Finance, More). Sidebar on desktop.

**Refresh:** 15-second polling on Action Queue (items move columns). 15-minute polling on all other panels. No WebSockets needed at this scale.

**Panel 12 — Action Queue (Human-in-the-Loop Inbox):**

Every `requires_human = true` record surfaces here with inline controls and on-demand AI explanation.
This is the primary action surface — not a read-only BI view.

```typescript
// /dashboard/action-queue — Next.js page
// Three controls per item:
//   Approve  — clears requires_human, updates status, writes audit_log
//   Flag     — marks disputed, adds note to reconciliation_flags
//   Explain  — calls reconciliation_explainer on demand, renders hypothesis inline

// POST /webhook/action-approve
// Body: { item_id, item_type, action: "approve"|"flag"|"dismiss" }

// POST /api/action-queue/explain
// Body: { item_id, item_type }
// Returns { hypothesis, suggested_action, confidence }
```

**Always display the reasoning field — every card shows why it was flagged:**

The `reasoning` field from every AI worker output is stored in `audit_log.ai_parsed`. Every Action Queue card must render it prominently — not hidden behind an expand or an Explain button. A non-technical user should never see a flag without an explanation.

```typescript
// Action Queue card data shape — fetch from:
// SELECT al.ai_parsed->>'reasoning' as reasoning,
//        al.ai_parsed->>'hypothesis' as hypothesis,
//        al.ai_parsed->>'suggested_action' as suggested_action,
//        al.ai_parsed->>'confidence' as confidence
// FROM audit_log al
// WHERE al.record_id = $item_id AND al.record_type = $item_type
// ORDER BY al.created_at DESC LIMIT 1

// Render on every card:
// <ReasoningBadge>                          ← always visible
//   {reasoning}                             ← e.g. "VAT amount does not match supplier record"
// </ReasoningBadge>
// {hypothesis && <HypothesisCard>           ← if reconciliation_explainer ran
//   {hypothesis}                            ← e.g. "Likely a price increase — St Austell raised rates in April"
//   <SuggestedAction>{suggested_action}</SuggestedAction>
//   <ConfidencePill>{confidence}</ConfidencePill>
// </HypothesisCard>}
```

**Reasoning display rule:** If `reasoning` is null or empty, the card is blocked from the queue — it goes to dead_letter instead. A flag without an explanation is not actionable and should not reach the user.

Keyboard shortcuts: `A` Approve | `F` Flag | `D` Dismiss | `E` Explain | `Space` Next

**Refresh:** 15-minute browser polling. No WebSockets needed at this scale.

## 8.4 Obsidian Vault

**Vault structure — PARA framework (Projects / Areas / Resources / Archives):**

The vault follows the PARA structure so both you and agents can navigate it predictably. Agents always know where to look and where to write. Inbox is where unprocessed items land. Archives is where completed things go. This maps directly onto the system's event lifecycle.

```
/mnt/ssd/obsidian-vault/
├── Inbox/                       # Unprocessed — agents write here first
│
├── Projects/                    # Active work with a defined end state
│   ├── HomeAI-Build/            # The system build itself
│   ├── Malthouse-Renovation/    # Any active pub project
│   └── [active project]/
│
├── Areas/                       # Ongoing responsibilities (no end state)
│   ├── Malthouse/               # Pub operations, staff, suppliers
│   ├── Estates/                 # 7 properties, tenants, compliance
│   ├── Personal/                # Finance, health, cars
│   │   └── Cars/Car-0N-[reg]/
│   └── Family/                  # 3 children — school, medical, milestones
│       └── Children/Child-0N-[name]/
│
├── Resources/                   # Reference material — no action required
│   ├── Suppliers/               # Terms, contacts, price lists
│   ├── Legal/                   # Lease templates, employment contracts
│   ├── Compliance/              # Licensing, food hygiene, fire safety
│   └── Research/                # Research pipeline writes here
│
├── Archives/                    # Completed projects, old tenancies, closed items
│
├── Wiki/                        # Karpathy compiled wiki articles (Phase 5)
│   ├── index.md                 # Master index — fits in one context window
│   ├── malthouse-performance.md # Auto-updated nightly from EPoS data
│   ├── estates-status.md        # Auto-updated from rent + compliance data
│   ├── staff-notes.md           # Key staff context (non-sensitive)
│   └── [topic].md               # One article per significant topic
│
├── Daily/                       # YYYY-MM-DD.md — append-only journal
│
└── System/
    └── Assistant/
        ├── MEMORY.md            # §-separated hot context (<3000 chars)
        ├── USER.md              # Jo's profile + entity map
        ├── environment.md       # P620 hardware, services, ports
        └── logs/
            └── issues-fixes-log.md
```

**PARA mapping to system concepts:**

| PARA layer | System equivalent | Agent writes here when |
|---|---|---|
| Inbox | `requires_human = true` queue | New unprocessed item arrives |
| Projects | Active phases, current initiatives | Project context needed |
| Areas | Ongoing business domains | Domain context needed |
| Resources | Reference data, compiled wiki | Research findings, supplier notes |
| Archives | Processed events > 90 days | Items completed or archived |
| Wiki | Karpathy compiled articles | Nightly wiki compilation workflow |

**MEMORY.md starter:**
```markdown
# MEMORY.md
§
HOLIDAY_CALC: Statutory pro-rata ONLY. NEVER 12.07% accrual.
§
XERO: Org 1 = Trading Ltd. Org 2 = Estates Ltd.
§
DEXT: Dext is a manual review tool (no public API). Internal extraction (pdfplumber/MarkItDown + Haiku) is the ONLY automated path.
§
CASHING_UP: Z-reading from ICRTouch ONLY. Staff enter cash+float only.
§
AI_SECURITY: Always body_text_safe — never body_text — in AI prompts.
```

**Plugins to install:** Obsidian Git, Dataview, Templater, Calendar.

## 8.5 The Obsidian → Claude Workflow

The Obsidian vault is your personal knowledge layer — the context that makes Claude.ai conversations about *your* business rather than generic advice. Here is how it connects to day-to-day use.

**MEMORY.md is your hot context.** Keep it under 3,000 characters. It contains the facts Claude should always know when talking to you about your business: entity structure, key rules, important constraints, things you have learned. Update it whenever you discover something Claude keeps getting wrong. Paste it at the start of any complex Claude.ai conversation.

**Conversation templates by use case:**

```markdown
# Template: Business analysis question
Context: [paste MEMORY.md]
Data: [paste relevant export from Metabase or SQL result]
Question: [your actual question]

# Template: Difficult staff situation
Context: [paste MEMORY.md]
Background: [paste relevant notes from Business/Malthouse/]
Situation: [describe what happened]
What I need: [advice / draft letter / talking points]

# Template: Property / tenant question
Context: [paste MEMORY.md]
Property: [paste relevant file from Properties/Property-0N/]
Question: [your question]

# Template: Research request
Context: [paste MEMORY.md]
Topic: [what you want to understand]
Save findings to: [Obsidian path for the research pipeline to write back to]
```

**What the research pipeline writes back (Phase 5):** When you ask the system to research something — a supplier, a competitor, a regulatory question — the findings are written to `/mnt/ssd/obsidian-vault/Research/YYYY-MM-DD-[topic].md` automatically. These accumulate as a private knowledge base specific to your businesses.

**Daily note template (add to Templater):**
```markdown
# {{date}}

## Today
- 

## Digest summary
[paste key items from morning Telegram]

## Decisions made
-

## For Claude tomorrow
-
```

**Keeping MEMORY.md current:** After any conversation where you correct Claude or discover something important, add it to MEMORY.md under a new § section. The end-of-session retro (Section 0.7) is the habit that keeps this current. The Obsidian Git plugin commits changes automatically — your knowledge base is version-controlled.

## 8.6 MCP Services for Claude.ai (Phase 3)

Two MCP services connect Claude.ai to live system data — one for the database, one for the Obsidian vault. Both accessible via Tailscale + SSE transport. Connect both in Claude.ai Settings → Integrations.

### PostgreSQL MCP (port 8005)

The highest-value Phase 3 addition. A lightweight MCP server that exposes safe, read-only database queries as tools to Claude.ai — enabling live data questions in this interface without copy-pasting exports.

**What it enables:**
*"What is my food GP trend over the last 3 months?"* → Claude queries your actual epos_daily_reports table and reasons about the numbers.
*"Which property has the longest rent arrears?"* → live answer from rent_payments.
*"Is my wage percentage on track this week?"* → from till_reconciliation and staff hours.

**Implementation (services/postgres-mcp/main.py):**
```python
from mcp.server.fastmcp import FastMCP
import asyncpg, os

mcp = FastMCP("homeai-postgres")
DB_URL = os.environ["DATABASE_URL"]  # read-only homeai_readonly role

# Each tool is a safe, parameterised query — no raw SQL from Claude
@mcp.tool()
async def get_epos_trend(days: int = 30) -> str:
    """Get EPoS sales trend for the last N days — gross sales, food GP, covers."""
    async with asyncpg.create_pool(DB_URL) as pool:
        rows = await pool.fetch('''
            SELECT report_date, gross_sales, food_sales,
                   ROUND(food_sales/NULLIF(gross_sales,0)*100,1) as food_gp_pct,
                   covers, session
            FROM epos_daily_reports
            WHERE report_date > CURRENT_DATE - $1
            ORDER BY report_date DESC
        ''', days)
        return str([dict(r) for r in rows])

@mcp.tool()
async def get_rent_status() -> str:
    """Get current rent payment status for all 7 properties."""
    async with asyncpg.create_pool(DB_URL) as pool:
        rows = await pool.fetch('''
            SELECT p.address_line1, t.tenant_name, t.monthly_rent,
                   rp.status, rp.expected_date, rp.received_date
            FROM rent_payments rp
            JOIN tenancies t ON rp.tenancy_id = t.id
            JOIN properties p ON t.property_id = p.id
            WHERE rp.expected_date >= date_trunc('month', NOW())
            ORDER BY rp.status, p.address_line1
        ''')
        return str([dict(r) for r in rows])

@mcp.tool()
async def get_action_queue() -> str:
    """Get all items currently requiring human review."""
    async with asyncpg.create_pool(DB_URL) as pool:
        rows = await pool.fetch('''
            SELECT 'invoice' as type, id, supplier_name as description,
                   gross_amount, anomaly_reason as reason, created_at
            FROM invoices WHERE requires_human=true AND status='pending'
            UNION ALL
            SELECT 'email', id, subject, null, 'Classification ambiguous', received_at
            FROM emails WHERE requires_human=true AND processed=false
            ORDER BY created_at DESC
        ''')
        return str([dict(r) for r in rows])

@mcp.tool()
async def get_cashflow_forecast(entity_id: int = 1) -> str:
    """Get latest 30-day cashflow forecast for Trading (1) or Estates (2)."""
    async with asyncpg.create_pool(DB_URL) as pool:
        row = await pool.fetchrow('''
            SELECT opening_balance, forecast_income, forecast_expenses,
                   forecast_closing, generated_at
            FROM cashflow_forecast
            WHERE entity_id = $1
            ORDER BY generated_at DESC LIMIT 1
        ''', entity_id)
        return str(dict(row)) if row else "No forecast available"

if __name__ == "__main__":
    mcp.run(transport="sse")  # SSE for remote MCP connection
```

**Add to docker-compose.yml (Phase 3):**
```yaml
  postgres-mcp:
    build: ./services/postgres-mcp
    container_name: homeai-postgres-mcp
    networks: [ai-internal, ai-services]
    environment:
      DATABASE_URL: "postgresql://homeai_readonly:PASSWORD@postgres:5432/homeai"
    ports: ["8005:8005"]
    profiles: ["phase3"]
    restart: unless-stopped
```

**Connect to Claude.ai:** Settings → Integrations → Add MCP Server → `http://[tailscale-ip]:8005/sse`

Tools exposed: `get_epos_trend`, `get_rent_status`, `get_action_queue`, `get_cashflow_forecast`. Add more tools as you identify recurring questions. Every tool uses the `homeai_readonly` role — Claude can never write to your database through this connection.

**Security:** The MCP server is only accessible via Tailscale. It uses the read-only database role. No raw SQL is accepted — only the defined tool functions. Claude cannot see table structures, only the data each tool returns.

### Obsidian Vault MCP (port 8007)

**What it enables:** Claude.ai can navigate your Obsidian vault directly — reading notes, writing research findings, updating MEMORY.md, checking the wiki index — without copy-pasting file contents. The vault becomes a live context source rather than a manual clipboard operation.

**Implementation (services/vault-mcp/main.py):**
```python
from mcp.server.fastmcp import FastMCP
import os, pathlib

mcp = FastMCP("homeai-vault")
VAULT = pathlib.Path(os.environ["VAULT_PATH"])  # /mnt/ssd/obsidian-vault

@mcp.tool()
def read_note(path: str) -> str:
    """Read an Obsidian note by relative path (e.g. System/Assistant/MEMORY.md)"""
    p = VAULT / path
    if not p.is_relative_to(VAULT): return "Access denied"
    return p.read_text() if p.exists() else f"Note not found: {path}"

@mcp.tool()
def write_note(path: str, content: str) -> str:
    """Write or update an Obsidian note (creates parent folders if needed)"""
    p = VAULT / path
    if not p.is_relative_to(VAULT): return "Access denied"
    # Only allow writes to: Inbox/, Wiki/, Resources/Research/, Daily/
    allowed = ["Inbox/", "Wiki/", "Resources/Research/", "Daily/"]
    if not any(str(p.relative_to(VAULT)).startswith(a) for a in allowed):
        return f"Write not permitted outside: {allowed}"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content)
    return f"Written: {path}"

@mcp.tool()
def list_notes(folder: str = "") -> str:
    """List notes in a vault folder"""
    p = VAULT / folder
    if not p.is_relative_to(VAULT) or not p.exists(): return "Folder not found"
    return "\n".join(str(f.relative_to(VAULT))
                     for f in sorted(p.rglob("*.md"))[:50])

@mcp.tool()
def read_wiki_index() -> str:
    """Read the master wiki index — always start here for business context"""
    return read_note("Wiki/index.md")

if __name__ == "__main__":
    mcp.run(transport="sse")
```

**Connect to Claude.ai:** Settings → Integrations → Add MCP Server → `http://[tailscale-ip]:8007/sse`

**Write permissions are restricted** to `Inbox/`, `Wiki/`, `Resources/Research/`, and `Daily/`. Claude cannot overwrite `Areas/`, `Projects/`, `System/`, or `Archives/` — those are yours. Read access is vault-wide.

**Typical vault-aware conversation:**
> *"Check the wiki index, then look at malthouse-performance.md and tell me if food GP has improved since we changed the Sunday menu."*
> Claude reads `Wiki/index.md` → reads `Wiki/malthouse-performance.md` → answers from compiled data.

## 8.7 Phase 3 Testing Checklist

```
[ ] Calendar sync: new Google Cal event appears in dashboard calendar panel within 15 min
[ ] Task auto-generated from email with action_required=true
[ ] Property compliance: record with expiry in 25 days → alert in digest
[ ] Document control: version bump creates document_versions row + Drive URL updated
[ ] Scanner workflow: scan → Drive → OCR extracted → documents table metadata
[ ] Playwright: simple test task (e.g. open a URL) executes and returns result
[ ] Self-test suite: Run All Tests completes with health score displayed
[ ] Self-test: dead letter test shows correct fix SQL in expandable panel
[ ] Self-test: fix SQL copy button works
[ ] Diagnostics API: GET /api/diagnostics/run/postgres_connection returns valid result
[ ] Diagnostics: daily 06:30 n8n workflow runs and inserts to diagnostic_history
[ ] Next.js dashboard: all 11 panels render with live data
[ ] Next.js: 15-minute refresh updates panels
[ ] Obsidian vault: MEMORY.md created with starter entries
[ ] Obsidian Git plugin: auto-commits on schedule
[ ] PostgreSQL MCP: curl http://localhost:8005/sse returns connection
[ ] PostgreSQL MCP: connected to Claude.ai — ask "what is my rent status?" and get live data
[ ] PostgreSQL MCP: Claude cannot modify data (homeai_readonly role confirmed)
[ ] Obsidian → Claude workflow: paste MEMORY.md into a conversation, confirm context is correct
[ ] Model evaluator dashboard: /dashboard/models renders all 4 tabs (Stack, Scanner, Benchmarks, Recommendations)
[ ] Model evaluator: VRAM bar shows correct allocation for deployed tiers
[ ] Model evaluator: Run Benchmark button triggers benchmark and updates score table
[ ] Model evaluator: Deploy button updates static_context and pipeline behaviour changes
```

---

# PART 9: PHASE 4 BUILD — Weeks 19–24

## 9.1 Goal and Deliverables

**Goal:** WhatsApp bridge, unified comms digest, pub document store, Telegram 2FA fully operational.

**Deliverables:**
- WhatsApp Baileys bridge (personal number, read-only)
- WhatsApp number blacklist (private contacts excluded from AI processing)
- Unified comms digest (Gmail + WhatsApp + Telegram in single view)
- Pub document and policies store (The Malthouse)
- Employment contracts in document control
- Telegram 2FA and alert channel fully operational

## 9.2 Key Phase 4 Notes

**WhatsApp Baileys bridge:**
```bash
docker compose --profile phase4 up -d baileys-bridge
# Scan QR code on first run to authenticate personal number
```
Risk: Meta can break the bridge on app updates. n8n monitors bridge health endpoint and sends Telegram alert if disconnected > 30 minutes. Mode: read-only. No automatic replies ever.

**Number blacklist — private contacts excluded from AI processing:**

Some conversations should never be seen by any AI worker — personal relationships, family members, sensitive contacts, or any number where AI processing is inappropriate. Blacklisted numbers are still ingested into the database as raw records (so you can search them if needed) but their message content is never passed to any AI worker, never included in the digest, and never surfaced in the Action Queue.

Add to seed-data.sql:
```sql
INSERT INTO static_context (key, entity_id, value) VALUES
('whatsapp.blacklist', null, '{
  "numbers": [
    "+447XXXXXXXXX",
    "+447XXXXXXXXX"
  ],
  "mode": "store_raw_only",
  "note": "Blacklisted numbers are stored in whatsapp_messages but content is never passed to AI workers or included in digest"
}')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
```

Add to Baileys bridge n8n workflow — as the FIRST Code node after message receipt, before any classification or storage:
```javascript
// Blacklist check — runs before any other processing
const ctx = await db.fetchOne(
  "SELECT value FROM static_context WHERE key = 'whatsapp.blacklist'"
);
const blacklist = ctx?.value?.numbers || [];
const sender = $input.first().json.from_number; // e.g. "+447123456789"

if (blacklist.includes(sender)) {
  // Store raw record only — no content, no AI, no digest
  await db.execute(
    `INSERT INTO whatsapp_messages
       (from_number, received_at, content_hash, blacklisted, content)
     VALUES ($1, NOW(), $2, true, NULL)`,
    [sender, hashContent($input.first().json.body)]
  );
  // Stop pipeline — return empty to end workflow execution
  return [];
}
// Proceed to normal classification...
```

Add `blacklisted BOOLEAN DEFAULT FALSE` and `content_hash TEXT` columns to the `whatsapp_messages` table (Phase 4 migration `V4__whatsapp_blacklist.sql`).

To add or remove numbers from the blacklist at runtime:
```sql
-- Add a number:
UPDATE static_context
SET value = jsonb_set(value, '{numbers}',
  (value->'numbers') || '["+447XXXXXXXXX"]'::jsonb)
WHERE key = 'whatsapp.blacklist';

-- Remove a number:
UPDATE static_context
SET value = jsonb_set(value, '{numbers}',
  (value->'numbers') - '+447XXXXXXXXX')
WHERE key = 'whatsapp.blacklist';
```

The static_context correction trigger fires on any update, so the Baileys pipeline picks up changes immediately without restart.

**Pub document store categories:** policies, procedures, staff_contracts, training_records, compliance, licensing, health_and_safety, menus, supplier_agreements, insurance.

---

# PART 10: PHASE 5 BUILD — Weeks 25–30

## 10.1 Goal and Deliverables

**Goal:** Research agent, coding assistant, full RAG, photo migration, industry news briefing.

**Deliverables:**
- Research pipeline (web search + Qdrant retrieval + Obsidian write)
- Coding assistant pipeline (GitHub integration)
- Full RAG across emails, invoices, documents via Qdrant (hybrid dense+sparse+RRF)
- **Qdrant reranking** — cross-encoder re-scoring after initial retrieval
- **Karpathy wiki compilation** — nightly n8n workflow compiling vault wiki articles from live data
- Hotmail/OneDrive photo migration to 4TB HDD
- Weekly industry news briefing (hospitality + property)
- **Playground Agent** — sandboxed prototype environment with Vercel auto-deploy

## 10.2 Playground Agent

**Purpose:** A sandboxed creative environment for prototyping websites, landing pages, tools, and experiments without touching the core Home AI system. Jo tells the AI what to build; it builds it and returns a live URL.

**Architecture — strict isolation:**

```
/home_ai/playground/
├── projects/
│   ├── ice-cream-flavours-2026/     ← each project gets its own folder
│   ├── tintagel-events-page/
│   └── pub-booking-form/
├── assets/
│   └── shared/                      ← images, fonts, brand assets
└── deployments.log                  ← record of all deploys with URLs
```

The playground-agent has write access ONLY to `/home_ai/playground/`. It cannot read the database, access Vault secrets, touch n8n workflows, or write anywhere else in the system. Zero blast radius.

**Add to `.claude/agents/playground-agent.md`:**

```markdown
---
name: playground-agent
description: Builds prototype websites and landing pages in the sandboxed /home_ai/playground/ directory. Use for: "I want to test a new ice cream flavour page", "build a simple booking form", "make a landing page for the pub event". Never used for core system work.
tools: [Read, Write, Bash]
allowed_paths: ["/home_ai/playground/"]
---
You are a creative web builder working in the playground sandbox.
You ONLY read from and write to /home_ai/playground/.
You do NOT have access to: the database, Vault, n8n, Docker, or any path outside /home_ai/playground/.
Stack: Next.js or plain HTML/CSS/JS depending on complexity.
Styling: Tailwind CSS via CDN for simple pages; shadcn/ui for more complex components.
Images: use Unsplash URLs or placeholder.co for prototypes — never embed large assets.
After building: run "git add . && git commit -m 'prototype: [description]' && git push" from the project folder.
Then trigger deployment via: curl -X POST http://n8n:5678/webhook/playground-deploy -d '{"project":"[folder-name]"}'
Return the Vercel preview URL when available.
```

**n8n Workflow F — Playground Deploy (activate in Phase 5):**

```
Trigger: POST /webhook/playground-deploy
Body: { "project": "ice-cream-flavours-2026" }
↓
Code Node: validate project folder exists at /home_ai/playground/projects/{project}
↓
Bash Node: cd /home_ai/playground/projects/{project} && npx vercel deploy --yes --token=$VERCEL_TOKEN
↓
Parse output → extract preview URL
↓
INSERT deployments.log (project, url, deployed_at)
↓
Telegram: "🚀 Playground deploy: {project}
Live at: {url}"
```

**One-time Vercel setup:**

```bash
# Install Vercel CLI
npm install -g vercel

# Authenticate and link playground to a Vercel project
cd /home_ai/playground
vercel login
vercel link --project playground

# Add Vercel token to Vault:
docker exec -e VAULT_TOKEN=$VAULT_TOKEN homeai-vault   vault kv put secret/vercel token="your-vercel-token"

# Add to n8n-policy.hcl:
# path "secret/data/vercel" { capabilities = ["read"] }
```

**One-time GitHub setup:**

```bash
# Create private playground repo
gh repo create home-ai-playground --private --clone
cd /home_ai/playground && git init
git remote add origin https://github.com/YOURUSERNAME/home-ai-playground.git
git push -u origin main
```

**Typical workflow:**

```
Jo: "Build a landing page for the Olde Malthouse summer events"
↓
playground-agent creates /home_ai/playground/projects/summer-events-2026/
↓
Builds Next.js page with event listings, pub branding, contact form
↓
Git commit + push → Vercel deploy → Telegram: "Live at summer-events-abc123.vercel.app"
↓
Jo opens URL on phone, reviews, makes change requests
↓
playground-agent updates → redeploy → new URL
```

**What the playground is for:** Ice cream flavour menus, event landing pages, booking forms, property listing pages, simple tools, visual experiments, anything creative.

**What the playground is NOT for:** Anything touching the core system, database queries, financial data, staff records.

## 10.3 Key Phase 5 Notes

**Qdrant indexing pipeline:** n8n watches for new rows in emails, documents, epos_daily_reports
→ extracts text → generates embeddings via Ollama (nomic-embed-text model) → upserts to Qdrant.
Enables semantic search across all system data.

**Hybrid RAG — configure when creating Qdrant collections:**

Pure vector search excels at semantic similarity. BM25/sparse search is superior for specific
identifiers — invoice numbers, tenant names, NI numbers, postcodes. Configure both from day one.

```python
from qdrant_client import QdrantClient
from qdrant_client.models import VectorParams, Distance, SparseVectorParams, SparseIndexParams

client = QdrantClient("http://qdrant:6333")

# Create each collection with dense + sparse vectors:
# Repeat for: emails, invoices, documents, garmin_notes, research_findings
client.create_collection(
    collection_name="emails",
    vectors_config={"dense": VectorParams(size=768, distance=Distance.COSINE)},
    sparse_vectors_config={
        "sparse": SparseVectorParams(index=SparseIndexParams(on_disk=False))
    }
)

# Query with RRF fusion (blends dense + sparse rankings):
results = client.query_points(
    collection_name="emails",
    prefetch=[
        models.Prefetch(query=dense_vector, using="dense", limit=20),
        models.Prefetch(query=sparse_vector, using="sparse", limit=20),
    ],
    query=models.FusionQuery(fusion=models.Fusion.RRF),
    limit=5
)
```

Query routing rule (implement in research pipeline):
- Semantic queries ("emails about pub cash flow") → dense vector only
- Queries containing invoice numbers, postcodes, NI format → hybrid (dense + sparse + RRF)
- Exact identifier lookups ("INV-2026-0847") → sparse/BM25 only

**Reranking — add cross-encoder step after initial Qdrant retrieval:**

Dense+sparse+RRF returns the top 20 candidates. A small cross-encoder model
re-scores the actual query-document pairs and returns the true top 5. Measurably
improves precision on ambiguous queries at minimal cost (~100ms on CPU).

```python
# In research pipeline — after Qdrant returns top 20 results:
from sentence_transformers import CrossEncoder

# Model: ~80MB, runs on CPU, no GPU needed
reranker = CrossEncoder("cross-encoder/ms-marco-MiniLM-L-6-v2")

def rerank(query: str, candidates: list[dict]) -> list[dict]:
    """Re-score Qdrant candidates with cross-encoder, return top 5."""
    pairs = [(query, c["payload"]["text"][:512]) for c in candidates]
    scores = reranker.predict(pairs)
    ranked = sorted(zip(scores, candidates), key=lambda x: x[0], reverse=True)
    return [c for _, c in ranked[:5]]
```

Add `sentence-transformers` to the research pipeline service requirements.
The cross-encoder model downloads once on first use (~80MB, cached in the service volume).

**Karpathy Wiki Compilation — nightly n8n workflow:**

Each night at 01:00, this workflow queries the live database and rewrites the
compiled wiki articles in `Wiki/`. The wiki is the compiled form of your business
knowledge — expensive to compile once, cheap to read in every conversation.

```
Trigger: Schedule (01:00 daily)
↓
For each wiki article:

Wiki/malthouse-performance.md:
  Query: last 30 days EPoS (gross, food GP%, covers, sessions)
  Query: last 7 days cashing up status + variance
  Query: accommodation occupancy % and RevPAR trend
  → Haiku compiles into one-page summary article
  → write_note("Wiki/malthouse-performance.md", compiled)

Wiki/estates-status.md:
  Query: all 7 properties — rent status, days arrears, compliance expiry
  → Haiku compiles into one-page property status article
  → write_note("Wiki/estates-status.md", compiled)

Wiki/cashflow-snapshot.md:
  Query: latest cashflow_forecast for both entities
  Query: overdue invoices + outstanding rent
  → Haiku compiles into financial position summary

Wiki/index.md:
  → Regenerate master index listing all wiki articles with one-line summaries
  → Must fit in <3000 tokens (the Karpathy constraint)
  → Claude reads index.md first in every vault-aware conversation
```

**The index.md pattern (Karpathy):** Every conversation that uses the vault MCP
starts with `read_wiki_index()`. This returns the compiled master index — a map
of what business knowledge exists, where it lives, and when it was last compiled.
Claude then pulls specific articles as needed. No vector search, no embeddings,
no retrieval pipeline for the vault layer — just a well-organised set of text
files that fit in context.

**Photo migration:**
```bash
rclone copy onedrive:Photos /mnt/hdd/archive/photos --progress
# Verify checksums, then optionally delete from OneDrive to free space
```

---

# PART 11b: OPERATIONAL INTELLIGENCE AGENTS

These agents extend the core system with domain-specific intelligence unique to Jo's situation. They are built using data and infrastructure already in place — no new databases, no new pipelines, just new n8n workflows reading from existing tables. Each one is independently deployable and can be added in any order from Phase 2 onward.

---

## The Beer Garden Oracle

**When to build:** Phase 2 (needs EPoS historical data to train)
**Data sources:** Met Office DataPoint API (free registration), `epos_daily_reports`
**Output:** One line in the morning briefing + a beer garden status flag on the pub dashboard

Cornwall weather is unpredictable. This agent correlates historical EPoS session data against recorded weather conditions to learn the actual footfall thresholds for The Olde Malthouse's beer garden specifically — not generic advice.

```python
# n8n Code node — runs at 07:00 as part of digest pipeline
# Met Office DataPoint API (free, no key required for basic forecasts)

async def get_beer_garden_recommendation(db, weather_api):
    # Fetch today's forecast for Tintagel (Met Office site ID: lookup once)
    forecast = await weather_api.get("https://datapoint.metoffice.gov.uk/public/data/..."
                                     "?res=3hourly&key=FREE_KEY")
    temp_c   = forecast['noon_temp']
    rain_mm  = forecast['noon_precip']
    wind_ms  = forecast['noon_wind']
    is_weekend = datetime.now().weekday() >= 5
    school_hols = await db.fetchval(
        "SELECT value->>'active' FROM static_context WHERE key='calendar.school_holidays'"
    )

    # Query historical EPoS to learn the actual threshold
    # (trains itself — no manual configuration needed)
    threshold = await db.fetchrow("""
        SELECT
            AVG(gross_sales) FILTER (WHERE weather_temp >= 16 AND weather_rain < 2) as warm_avg,
            AVG(gross_sales) FILTER (WHERE weather_temp < 14 OR weather_rain > 4)  as cold_avg
        FROM epos_daily_reports
        WHERE report_date > CURRENT_DATE - 90
    """)
    # weather_temp and weather_rain columns added to epos_daily_reports in V3 migration

    # Simple scoring model
    score = 0
    if temp_c >= 18: score += 3
    elif temp_c >= 15: score += 2
    elif temp_c >= 12: score += 1
    if rain_mm < 1: score += 2
    elif rain_mm < 4: score += 1
    if wind_ms < 5: score += 1
    if is_weekend: score += 1
    if school_hols == 'true': score += 1

    pct = min(int(score / 10 * 100), 95)
    if pct >= 70:
        return f"☀️ Beer garden: {pct}% — open from noon, expect strong afternoon trade"
    elif pct >= 40:
        return f"🌤 Beer garden: marginal ({pct}%) — open but watch the weather"
    else:
        return f"🌧 Beer garden: {pct}% — probably keep it closed today"
```

Add `weather_temp DECIMAL(4,1)` and `weather_rain DECIMAL(5,2)` columns to `epos_daily_reports` via V3 migration. Populate daily at 23:00 by fetching actual recorded weather for the day (Met Office historic API) and updating that day's row.

---

## The Ice Cream Oracle

**When to build:** Phase 2 (needs 30+ days EPoS flavour data)
**Data sources:** `epos_daily_reports` (with flavour breakdown), `static_context` for flavour registry
**Output:** Sunday evening recommendation in digest — what to push, what to retire, what's trending

The ice cream shop EPoS already tracks flavour sales (if you configure ICRTouch to ring each flavour as a separate PLU — do this now before Phase 1 build). Once you have 30 days of flavour-level sales data, this runs automatically.

```sql
-- Weekly flavour performance matrix (runs Sunday 20:00 via n8n schedule)
-- Classic menu engineering 2x2: Stars, Ploughs, Puzzles, Dogs

WITH flavour_stats AS (
    SELECT
        flavour_name,
        AVG(daily_units)    AS avg_units,
        AVG(margin_pct)     AS avg_margin,
        COUNT(*)            AS days_tracked,
        MAX(report_date)    AS last_sold
    FROM epos_flavour_daily   -- new table, populated from ICRTouch flavour PLUs
    WHERE report_date > CURRENT_DATE - 28
    GROUP BY flavour_name
),
benchmarks AS (
    SELECT
        AVG(avg_units)  AS median_units,
        AVG(avg_margin) AS median_margin
    FROM flavour_stats
)
SELECT
    f.flavour_name,
    f.avg_units,
    f.avg_margin,
    CASE
        WHEN f.avg_units >= b.median_units AND f.avg_margin >= b.median_margin THEN 'STAR'
        WHEN f.avg_units >= b.median_units AND f.avg_margin <  b.median_margin THEN 'PLOUGH'
        WHEN f.avg_units <  b.median_units AND f.avg_margin >= b.median_margin THEN 'PUZZLE'
        ELSE 'DOG'
    END AS quadrant
FROM flavour_stats f, benchmarks b
ORDER BY quadrant, f.avg_units DESC;
```

The Sonnet tier converts the matrix into a natural language recommendation:

```
Sunday digest addition:
"🍦 Ice cream this week: Cookie Dough is your star — keep it front and centre.
Salted Caramel is trending up (Puzzle → Star trajectory). Mint Choc Chip has
been dead 12 days — consider retiring it or dropping to off-menu. Suggest
moving Raspberry Ripple to position 1 for the school holiday week ahead."
```

---

## The Ghost Shift Detector

**When to build:** Phase 3 (needs 60+ days of reconciliation history per staff member)
**Data sources:** `till_reconciliation`, `epos_daily_reports`, `workforce_shifts` (from Workforce API)
**Output:** Quiet monthly flag in the digest — never accusatory, always pattern-based

Workforce holds the definitive record of who was rostered for each shift — no changes needed to ICRTouch or TouchOffice. The Workforce pipeline (Phase 2 HR module) already syncs shift assignments to a `workforce_shifts` table. The Ghost Shift Detector joins till reconciliation and EPoS data against Workforce shift records to identify which staff member was responsible for each session.

**Workforce shift sync (add to Phase 2 HR pipeline):**

```sql
-- New table populated by Workforce API sync (Phase 2 migration V3)
CREATE TABLE workforce_shifts (
    id             BIGSERIAL PRIMARY KEY,
    staff_id       INT REFERENCES staff(id),
    shift_date     DATE NOT NULL,
    session        TEXT NOT NULL,   -- 'lunch' | 'dinner' | 'all_day'
    shift_start    TIME,
    shift_end      TIME,
    role           TEXT,
    workforce_id   TEXT UNIQUE,     -- Workforce system reference ID
    synced_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_workforce_shifts_date ON workforce_shifts (shift_date, session);
```

The Workforce API sync runs nightly at 01:00 via the HR pipeline, pulling the previous day's confirmed shifts. The n8n HTTP Request node calls:
```
GET https://api.workforce.com/v1/shifts?date={date}&status=worked
Headers: Authorization: Bearer {token from Vault secret/workforce}
```

**Ghost shift detection query:**

```sql
-- Monthly pattern analysis per staff member (runs 1st of month, 06:00)
-- Source of truth for shift assignment: Workforce, not ICRTouch

SELECT
    s.first_name || ' ' || s.last_name  AS staff_member,
    COUNT(*)                             AS sessions,
    AVG(tr.variance)                     AS avg_variance,
    AVG(tr.variance_pct)                 AS avg_variance_pct,
    AVG(edr.voids)                       AS avg_voids,
    AVG(tr.variance) - team.avg_variance AS variance_vs_team
FROM till_reconciliation tr
JOIN epos_daily_reports edr
    ON tr.recon_date = edr.report_date AND tr.session = edr.session
JOIN workforce_shifts ws               -- join via Workforce shift data
    ON ws.shift_date = tr.recon_date
    AND ws.session   = tr.session
JOIN staff s
    ON ws.staff_id = s.id
CROSS JOIN (
    SELECT AVG(variance) AS avg_variance
    FROM till_reconciliation
    WHERE recon_date > CURRENT_DATE - 60
) team
WHERE tr.recon_date > CURRENT_DATE - 60
  AND s.status = 'active'
GROUP BY s.id, s.first_name, s.last_name, team.avg_variance
HAVING COUNT(*) >= 5                   -- minimum sample size
ORDER BY avg_variance DESC;
```

**Handling multi-staff sessions:** If Workforce shows two staff on the same session, the query returns both with the same variance reading. The digest flags the session rather than an individual: *"Three dinner sessions in the last 60 days show variance above threshold — two staff members were present for all three."* Jo can review the /system/staff-patterns page for the full breakdown.

Delivered quietly in the digest's SYSTEM section (not URGENT), worded carefully:

```
"📊 Staff cash pattern review (60 days): One team member shows a consistent
pattern worth reviewing — average variance 1.2% above team baseline over
8 sessions. Suggest a quiet conversation or a paired close shift to
investigate. Full data in /system/staff-patterns."
```

**Important:** The output never names the pattern as theft — it flags a statistical anomaly. The human (Jo) decides what to do with it.

**Add to Vault (Phase 2 HR pipeline setup):**
```bash
docker exec -e VAULT_TOKEN=$VAULT_TOKEN homeai-vault   vault kv put secret/workforce api_token="YOUR_WORKFORCE_TOKEN"
```

**Add to n8n-policy.hcl:**
```hcl
path "secret/data/workforce" { capabilities = ["read"] }
```

---

## The Legendary Guest Detector

**When to build:** Phase 4 (needs Caterbook guest history)
**Data sources:** `accommodation_daily_reports` + Caterbook guest API (if available) or email parsing
**Output:** Flag in morning briefing when a returning guest checks in

Caterbook's daily report includes guest names and booking references. The nanny pipeline already parses structured data from emails — a similar parser for Caterbook booking confirmation emails can extract guest names and match them against a growing guest history table.

```sql
-- New table: guest_history
CREATE TABLE guest_history (
    id            SERIAL PRIMARY KEY,
    guest_name    TEXT NOT NULL,
    guest_email   TEXT,
    stay_count    INT DEFAULT 1,
    first_stay    DATE,
    last_stay     DATE,
    notes         TEXT,       -- manually added (e.g. "prefers room 3, vegan")
    source        TEXT DEFAULT 'caterbook'
);

-- When a guest name appears in a Caterbook arrival email:
-- 1. Check guest_history for fuzzy name match (levenshtein distance <= 2)
-- 2. If match: increment stay_count, update last_stay, flag in morning briefing
-- 3. If new: insert new record

-- Morning briefing addition (if returning guest arriving today):
-- "🏠 Returning guest: Sarah Okonkwo checks in today — 3rd stay this year.
--  Notes: Room 3, extra towels, early checkout last time."
```

The `notes` field is manually maintained via a simple form on the `/properties` dashboard page — just a text area per guest. This is the inn's CRM.

---

## The Tintagel Tide Table

**When to build:** Phase 2 (trivial — pure API, no historical data needed)
**Data sources:** UKHO Easytide API (free) or Admiralty API
**Output:** One line in morning briefing — high/low tides + coastal path accessibility estimate

Tintagel footfall correlates with tide times because the coastal path and castle access are tide-dependent. Takes 30 minutes to build.

```python
# n8n HTTP Request node — fetch tide data for Tintagel Haven (UKHO station ID: 0141)
# Free via https://easytide.admiralty.co.uk/

async def get_tide_summary():
    # UKHO Easytide (no API key needed for basic tides)
    response = await fetch(
        "https://easytide.admiralty.co.uk/EASYTIDE/EasyTide/ShowPrediction"
        "?PortID=0141&DayCount=1"
    )
    # Parse HTML response for today's high/low times and heights
    # High tide > 5.5m = coastal path may be restricted
    # Afternoon high tide (12:00-18:00) = peak tourist window affected

    tides = parse_tide_table(response)
    afternoon_high = next((t for t in tides if t['type']=='HW' and 12 <= t['hour'] <= 18), None)

    if afternoon_high and afternoon_high['height_m'] > 5.5:
        return f"🌊 High tide {afternoon_high['time']} ({afternoon_high['height_m']}m) — coastal path restricted, footfall may shift to town"
    elif afternoon_high:
        return f"🌊 High tide {afternoon_high['time']} — normal coastal access"
    else:
        return f"🌊 Low tide afternoon — full coastal access, expect higher footfall"
```

---

## The St Austell Order Predictor

**When to build:** Phase 3 (needs 60+ days invoice history per product line)
**Data sources:** `invoices` (St Austell line items), `epos_daily_reports`
**Output:** Tuesday draft order in digest for Jo to approve before Thursday delivery

```sql
-- Consumption rate by product (rolling 28-day average)
SELECT
    product_name,
    SUM(quantity_ordered) / 28.0          AS daily_avg_consumption,
    SUM(quantity_ordered) / 28.0 * 10     AS reorder_qty_10_days,
    MAX(last_ordered_date)                 AS last_order,
    (MAX(last_ordered_date) + 7)           AS next_expected_order
FROM invoice_line_items   -- populated by enhanced invoice_extractor
WHERE supplier_name ILIKE '%st austell%'
  AND invoice_date > CURRENT_DATE - 28
GROUP BY product_name
ORDER BY daily_avg_consumption DESC;
```

Tuesday 07:00 digest addition:
```
"🍺 Suggested St Austell order for Thursday:
  Korev Lager ×4 kegs (running low — 3-week avg 1.8/wk)
  Tribute Ale ×2 kegs (normal stock)
  Proper Job ×1 keg (slow this month — consider 1 only)
  [Approve order] [Edit quantities] [Skip this week]"
```

Requires extracting line-item detail from St Austell invoices — the invoice_extractor currently pulls totals only. Upgrade the prompt to extract product name, quantity, and unit price per line, writing to a new `invoice_line_items` table (V5 migration).

---

## The Children's Milestone Vault

**When to build:** Phase 3 (extends nanny agent)
**Data sources:** `child_events`, school report emails, medical letters
**Output:** Private `/family/memories` dashboard page — never in main digest

A quiet accumulation of things worth keeping. School reports filed and one-paragraph summarised. Sports day results. First exam grades. GP letters that mark a milestone. Not surfaced anywhere except the private family page.

```sql
-- New table: child_milestones
CREATE TABLE child_milestones (
    id            BIGSERIAL PRIMARY KEY,
    child_id      INT REFERENCES children(id),
    milestone_date DATE,
    category      TEXT,  -- academic | medical | activity | personal
    title         TEXT,
    summary       TEXT,  -- AI-generated one paragraph from source document
    source_email_id BIGINT REFERENCES emails(id),
    document_id   BIGINT REFERENCES documents(id),
    created_at    TIMESTAMPTZ DEFAULT NOW()
);
```

Nanny agent extension — after classifying `school-report` or `nhs-letter`, Haiku generates a one-paragraph summary and writes to `child_milestones`. The `/family/memories` page renders a timeline per child: a private, permanent record that accumulates without effort.

---

## The Menu Engineering Agent

**When to build:** Phase 3 (needs 60+ days of food EPoS data at dish level)
**Data sources:** `epos_daily_reports` dish-level breakdown (requires ICRTouch PLU tracking)
**Output:** Monthly menu analysis in digest + `/pub/menu` dashboard page

Same 2x2 matrix as the Ice Cream Oracle but for the pub food menu:

| Quadrant | Characteristic | Action |
|---|---|---|
| **Stars** | High popularity, high GP | Protect — feature prominently |
| **Ploughs** | High popularity, low GP | Reprice, reformulate, or upsell sides |
| **Puzzles** | Low popularity, high GP | Promote harder — description, positioning |
| **Dogs** | Low popularity, low GP | Remove from menu |

The `reconciliation_explainer`-style prompt generates: *"Your Sunday roast is your biggest plough — you're selling 34 per week but the GP is only 58%. Either the portion size is too generous or the beef cost has risen. Worth a conversation with your supplier or a £1.50 price increase."*

---

## The Competitor Watch

**When to build:** Phase 5 (uses Playwright browser automation)
**Data sources:** Google Maps ratings (Playwright), TripAdvisor ratings (Playwright)
**Output:** Weekly flag in digest if competitor rating changes significantly

```python
# Playwright task — runs weekly via n8n schedule (Sunday 03:30)
# Targets: 3-4 nearest competitor pubs in Tintagel

COMPETITORS = [
    {"name": "The Camelot", "google_place_id": "PLACE_ID_1", "tripadvisor_url": "..."},
    {"name": "The Masons Arms", "google_place_id": "PLACE_ID_2", "tripadvisor_url": "..."},
]

# Playwright scrapes current rating for each competitor
# Stores in competitor_ratings table
# Compares to last week's reading
# Flags if: rating drops below 4.0, rating rises above 4.8, or change > 0.3 in a week

# Digest addition (only when something changes):
# "📊 Competitor watch: The Camelot dropped from 4.3 to 3.9 on Google this week
#  (12 new reviews, several negative). Potential opportunity to capture their trade."
```

```sql
CREATE TABLE competitor_ratings (
    id           BIGSERIAL PRIMARY KEY,
    competitor   TEXT NOT NULL,
    platform     TEXT NOT NULL,  -- google | tripadvisor
    rating       DECIMAL(3,1),
    review_count INT,
    checked_at   TIMESTAMPTZ DEFAULT NOW()
);
```

---

## The Biography / Status Export

**What it is:** A structured snapshot of the Home AI system at any point in time — designed to be handed to an AI reviewer, a developer, or used in a periodic PM review. Captures what's built, what's pending, key decisions made, active model stack, and open questions.

**How to generate:** Run `/biography` slash command in Claude Code. Output is a markdown file and a rendered HTML report.

**Add to `.claude/commands/biography.md`:**

```markdown
---
name: biography
description: Generate a current-state snapshot of the Home AI system for periodic review
---
Generate a Biography Report for the Home AI system. Include:

1. SYSTEM IDENTITY — version, owner, date generated, current phase
2. WHAT IS BUILT — completed phases and deliverables (tick each item in SPEC.md)
3. WHAT IS RUNNING — Docker services currently up, Vault status, active n8n workflows
4. WHAT IS PENDING — next phase and its deliverables
5. MODEL STACK — current hot/medium/heavy tier assignments and their benchmark scores
6. KEY DECISIONS — summarise the major architectural choices from .claude/decisions/
7. KNOWN ISSUES — unresolved dead letters, open reconciliation flags, stale leases
8. PERFORMANCE SNAPSHOT — last 7-day pipeline stats from audit_log
9. OPEN QUESTIONS — anything unresolved that needs a decision

Query the database for live data where possible. Read SPEC.md Section status.
Write the report to /home_ai/.claude/biography/YYYY-MM-DD-biography.md
Also output a plain-text summary for pasting into a review session.
```

**Add to `AGENTS.md`:**
```
## Biography
Periodic review document. Run /biography to generate.
Output: /home_ai/.claude/biography/YYYY-MM-DD-biography.md
Frequency: before any major review, before starting a new phase, or monthly.
```

**Add to directory structure:**
```
.claude/
├── biography/
│   └── YYYY-MM-DD-biography.md   ← generated snapshots (git-tracked)
```

The biography is the document you hand to any AI reviewer — the "what is this system, right now" that doesn't require reading 170KB of spec.

---

# PART 11: PHASE 6 BUILD — Weeks 31+

## 11.1 Goal and Deliverables

**Goal:** Multi-user access with entity guardrails.

**Deliverables:**
- Kids project sections (scoped, read-only)
- Accountant Metabase access (financial entities only, homeai_readonly role)
- Pub staff access (Malthouse entity only, limited dashboard)
- Row-level security enforced per role (already in schema — configure access)
- Entity guardrails fully operational

## 11.2 Key Phase 6 Notes

The RLS policies (Section 3.3) are already deployed in Phase 1. Phase 6 is about creating user accounts in Authelia with appropriate scope, creating scoped PostgreSQL views for each user type, and building limited Metabase dashboards pointing to those views.

**Accountant access:** Read-only homeai_readonly role, `SET app.current_entity='all'`, Metabase dashboard showing financial data only (no family, no personal health, no staff).

---

# APPENDICES

## Appendix A: Idempotency Key Construction

| Table | Key format |
|---|---|
| events | Set explicitly per pipeline |
| emails | `email_{gmail_message_id}` |
| invoices | `invoice_{sha256(supplier_name+gross_amount+invoice_date+entity_id)}` |
| bank_transactions | `bank_{sha256(account+date+amount+desc[:50])}` |
| epos_daily_reports | `epos_{sha256(report_date+session)}` |
| accommodation_daily_reports | `accomm_{sha256(report_date)}` |
| till_reconciliation | `till_{sha256(recon_date+session)}` |
| garmin_daily_summary | summary_date (UNIQUE column) |
| child_events | `child_{gmail_message_id}_{child_id}` |

SHA-256 in n8n Code Node:
```javascript
const crypto = require('crypto');
const key = crypto.createHash('sha256').update(input).digest('hex');
```

## Appendix B: Model Decision Matrix

| Task | Ollama 70B | Haiku | Sonnet | Opus |
|---|---|---|---|---|
| Email classification (clear) | ✓ primary | escalation | — | — |
| Email classification (ambiguous) | first try | ✓ escalation | — | — |
| Invoice extraction (clean PDF) | — | ✓ | — | — |
| Invoice extraction (poor scan) | — | first try | ✓ escalation | — |
| EPoS / Caterbook report parsing | — | ✓ | — | — |
| Nanny classification | — | ✓ | — | — |
| Reconciliation explanation (advisory) | — | — | ✓ | — |
| Cashflow analysis | — | — | ✓ | — |
| Weekly fitness coaching | — | — | ✓ | — |
| Digest — Telegram brief | — | ✓ | — | — |
| Digest — email (full) | — | — | ✓ | — |
| Legal document review | — | — | — | ✓ |
| High-stakes financial decisions | — | — | — | ✓ |

**Escalation rule:** Only escalate on invalid JSON, confidence below threshold, or required fields null. Never escalate speculatively.

## Appendix C: Cashing Up Sheet Template

Staff enter columns B, C, D, E only. System populates F–J.

| A: Date* | B: Session | C: Cash counted £ | D: Float returned £ | E: Notes | F: Z-reading £* | G: Card total £* | H: Expected cash £* | I: Variance £* | J: Status* |

Arithmetic (no AI):
```
H = F - G - D
I = C - H
J = "OK" if ABS(I) ≤ 5 AND ABS(I/F*100) ≤ 0.5 else "VARIANCE FLAGGED"
```

## Appendix D: Vault Secret Paths Quick Reference

| n8n usage | Vault path |
|---|---|
| Gmail OAuth | secret/gmail/account1 or account2 |
| Xero Trading | secret/xero/trading |
| Xero Estates | secret/xero/estates |
| Claude API | secret/anthropic |
| Telegram | secret/telegram |
| PostgreSQL | secret/postgres |
| Google Sheets | secret/google/sheets |
| Google Calendar | secret/google/calendar |
| Payload signing | secret/signing |

## Appendix E: Compliance and Legal

**Holiday entitlement:** Statutory pro-rata ONLY. NEVER 12.07% accrual. Minimum 5.6 weeks (28 days including bank holidays, full-time). Pro-rata for part-time.

**Right to work:** Alert at 90, 60, 30 days before expiry. Missing replacement on file = [!] critical + pipeline blocks compliance pass.

**Data protection:** NI numbers stored encrypted (pgp_sym_encrypt). Staff data accessible only to homeai_hr role. Never in digest outputs.

**Licensing:** Personal licence + DPS records in documents table (category=legal). Review date alerts required.

**Immigration (Hotel Records) Order 1972:** Non-British/Irish guests 16+ → name and nationality. Non-CTA guests → passport number and next destination. Retain 12 months. Track in documents table (category=compliance).

## Appendix F: Dead Letter Resolution Procedure

```
1. Telegram alert: [!] Dead letter: {pipeline} on event {event_id}
2. SELECT dl.*, e.* FROM dead_letter dl JOIN events e ON dl.event_id=e.id
   WHERE dl.resolved=false ORDER BY dl.created_at DESC;
3. Read error_message and payload
4. Fix the root cause
5. Log fix in System/Assistant/logs/issues-fixes-log.md (append-only)
6. Replay: UPDATE events SET status='pending', retry_count=0, error_message=null
           WHERE id={event_id};
7. Resolve: UPDATE dead_letter SET resolved=true, resolved_at=NOW(),
            resolution_notes='...' WHERE event_id={event_id};
8. Monitor n8n for successful processing of replayed event
```

## Appendix G: Security Incident Response

| Incident | Immediate action | Follow-up |
|---|---|---|
| Prompt injection confirmed | Kill pipeline, review audit_log 24h prior | Tighten sanitiser, rotate signing key |
| Signature mismatch | Quarantine event (dead_letter), do not replay | Audit who wrote the event |
| Vault sealed unexpectedly | Unseal with 3 keys, check hardware | Review security_audit_log access patterns |
| Auth failures × 3 | Authelia auto-blocks IP | Check Tailscale log, rotate TOTP if needed |
| API key in logs | Rotate immediately via Vault | Review ai_raw_output for exposure window |
| Dead letter flood (>10 in 1h) | Pause affected pipelines | Fix, replay in small batches |

## Appendix H: Version History

| Version | Changes |
|---|---|
| v1.0 | Initial specification |
| v2.0 | Event-driven architecture, deterministic routing, idempotency, dead-letter |
| v3.0 | trace_id, parent_event_id, static_context, RLS, AI output schema, deep security |
| v3.1 | Event partitioning, processing lease, pipeline versioning, config-driven thresholds, supplier anomaly, failure philosophy, manual review queue |
| v4.0 | All versions merged. Self-test suite integrated (Phase 3). Build-ready with CLAUDE.md. |
| v4.1 | Dead letter flood detection: per-pipeline thresholds, Prometheus alert, n8n auto-pause, manual reactivation enforced. |
| v4.2 | Model Stack Evaluator integrated: three-tier local model stack, benchmark suite, weekly scanner, monthly auto-bench, dynamic tier routing via static_context, Part 6a, Workflows A–D. |
| v4.3 | Claude Code workflow optimised: AGENTS.md split, Plan Mode, context discipline, parallel subagents, CLAUDE.local.md, .claude/ directory. |
| v4.4 | Atlas migrations. Events data tiering. AI worker drift alerting. Reconciliation_explainer proactive hypotheses. HITL Action Queue. Hybrid RAG. |
| v4.5 | Global Kill Switch. EXL2 quantization + tabbyAPI. /rewind, /simplify, /review, /pause-all, /resume-all, retro slash commands. ADR folder. Context7 MCP in AGENTS.md. |
| v4.6 | WhatsApp blacklist (hash-only storage, static_context, runtime SQL). Vault auto-unseal (age + CPU serial + systemd). Action Queue reasoning always visible. |
| v4.7 | Dashboard v2: mobile-first, Kanban Goal Board, Morning Command Center, Goal Cards, Playground Agent (Vercel auto-deploy + sandbox isolation). |
| v4.8 | Nine Operational Intelligence Agents (Part 11b). Biography / Status Export (/biography, .claude/biography/). Ghost Shift Detector uses Workforce not TouchOffice. |
| v4.9 | Part 0 Operational Guide. Open WebUI (port 8088). Telegram two-way commands (/takings /cashflow /rent etc). PostgreSQL MCP server (Phase 3). Obsidian workflow guide + conversation templates. |
| v5.0 | Phase 1 three-milestone gate structure. Vault auto-unseal + Authelia + benchmarks deferred to Phase 2 hardening. Vertical slice gate mandatory before all remaining pipelines. |
| v5.1 | Ralph loop, MarkItDown, vault-mcp, Karpathy wiki compilation, PARA vault, Qdrant reranking. |
| v5.2 | Disaster recovery scripts (backup-all.sh, bootstrap.sh, restore.sh). Section 7.3. |
| **v5.3** | **Outcome-Native pipeline pattern added to Section 6.2 construction rules: OutcomeObject schema (status/confidence/reasoning/tier_used), retry/escalation Code node (confidence <0.85 escalates to medium tier before requires_human), Dreaming heuristics file pattern for Master Router context. Phase 2 deliverables: Local Dreaming Workflow (Workflow H, nightly 02:00, audit_log → Haiku → heuristics.md → Master Router). CI Auto-Fix GitHub Actions (SQL tests for init_placeholder + RLS policy count). Note: Outcomes and Dreaming are patterns implemented locally in n8n/Ollama — NOT Anthropic Managed Agents platform features.** |

---

*End of Master Build Specification v5.3*
*This document supersedes all previous versions.*
*Single source of truth for the Home AI Administrative Engine build.*
