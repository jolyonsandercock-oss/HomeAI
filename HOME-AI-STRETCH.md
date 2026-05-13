# HOME AI — STRETCH & UPDATE DOCUMENT
## Future ideas and stretch goals

This document contains **future ideas only**. For current build state, read `STATUS.md`. For session rules and architecture, read `AGENTS.md`. For architectural reference, read `SPEC.md`.

Trimmed in U37 (2026-05-13): Section 1 (Build Lessons) moved to AGENTS.md + auto-memory feedback_*.md files. Section 2 (Model Stack) moved to AGENTS.md. Section 4 (Pending Decisions) moved to STATUS.md. Section 5 (Version Log) replaced by sprint files at `/home_ai/.claude/sprints/U*.md`.

---

## SECTION 3 — STRETCH GOALS & NEW IDEAS

Ideas captured during build that aren't in the main spec. Some are Phase 5+,
some are small additions that could go in any phase.

### 3.1 Operational Intelligence (discovered during build)

**Vault Health Monitor** *(Phase 2 addition)*
The vault-autounseal.sh script handles reboots, but there's no alert if Vault seals
unexpectedly mid-session (e.g. after a crash). Add to Ralph loop (Workflow G):
check Vault seal status every 30 minutes — if sealed and system_state is 'running',
trigger auto-unseal script and send Telegram: "⚠️ Vault re-sealed unexpectedly — auto-unsealing."

**Docker Service Watchdog** *(Phase 2 addition)*
The Ralph loop checks n8n, Vault, Postgres. But if a container restarts (not crashes),
`docker ps` still shows it as Up. Add a check: if any homeai container has restarted
more than 2 times in the last hour, flag it in the digest as unstable even if currently running.

**The Dead Man's Switch** *(Phase 2 addition)*
If the P620's Tailscale node is completely unreachable for more than 48 hours, the
system is orphaned — power cut, network failure, or hardware problem. No existing
check catches this because all monitoring runs ON the P620.

Solution: a secondary lightweight monitor running on a separate device (your phone
or a £4/month VPS) that pings the P620's Tailscale IP every 15 minutes and fires
a Telegram alert if it fails to respond for 48 hours.

```bash
# Simplest implementation — cron job on any always-on device:
# */15 * * * * curl -sf http://100.104.82.53:8200/v1/sys/health > /dev/null || \
#   curl -s "https://api.telegram.org/bot{TOKEN}/sendMessage" \
#   -d "chat_id={CHAT_ID}&text=⚠️ HOME AI ORPHANED: P620 unreachable for 15+ min. Check power."

# Or: use Uptime Kuma (self-hosted, Docker) on a VPS as a proper uptime monitor
# with Telegram integration — free tier VPS (Oracle Cloud always-free) works perfectly
```

**90-day Vault Rekey Automation** *(Phase 2 hardening)*
Currently rekey is manual (done once after the keys were exposed in chat). Should
be automated every 90 days as a security hygiene measure. The unseal keys in use
today were generated in May 2026 — first automated rekey due: August 2026.

Add to n8n schedule (Workflow H — Phase 2):
```
Schedule: 90 days from last rekey date (stored in static_context)
Action: Telegram alert "🔐 Vault rekey due. Run /vault-rekey when ready."
        (Never auto-rekey — always requires human with physical keys present)
Note in static_context: last_rekey_date and next_rekey_due
```

**Session Start Auto-Brief** *(Phase 1 addition, cheap)*
When you open Open WebUI or start a Claude Code session, have a Telegram message
fire automatically: *"Session started: Vault ✓ sealed=false, PostgreSQL ✓ 0 dead letters,
last pipeline: Gmail 4 mins ago, 0 items in Action Queue."*
Trigger: simple n8n webhook on a Telegram command `/start-session`.

### 3.2 Build Process Improvements

**SPEC.md compression for Claude Code sessions** *(immediate)*
The full SPEC.md is 5,500+ lines. Claude Code reads the whole thing on session start,
burning context. Consider creating a `SPEC-QUICKREF.md` — a 200-line digest of
section headers, key decisions, and port/service references. Claude reads quickref first,
pulls specific SPEC sections as needed. Similar to the Karpathy wiki index pattern.

**~~start.sh — consolidated startup script~~** ✓ DONE (May 2026)
Built at `/home_ai/start.sh`. Unseals Vault, fetches all secrets, issues n8n token, runs compose.

**Automated docker-compose YAML validation pre-commit hook** *(immediate)*
Add to `.git/hooks/pre-commit`:
```bash
#!/bin/bash
cd /home_ai
docker compose config --quiet 2>&1 | grep -v "WARN" && echo "YAML OK" || exit 1
```
This prevents committing broken YAML. The indentation error in Vault cost 30 minutes.

**Docker image version pinning** *(Phase 2 — do before Phase 2 features land)*
All services currently use `:latest` tags except Vault (already pinned to 1.15.6).
The Vault `:latest` failure proved this matters. Scan and pin all services:

```bash
# Check current tags in docker-compose.yml:
grep "image:" /home_ai/docker-compose.yml | grep ":latest"

# Pinned versions to use (verify latest stable before applying):
# postgres:latest       → postgres:16.4
# n8nio/n8n:latest      → n8nio/n8n:1.85.0  (check: hub.docker.com/r/n8nio/n8n)
# metabase/metabase:latest → metabase/metabase:v0.52.x
# grafana/grafana:latest   → grafana/grafana:11.x.x
# qdrant/qdrant:latest     → qdrant/qdrant:v1.12.x
# searxng/searxng:latest   → searxng/searxng:2024.x.x
# Add a monthly Workflow B check: alert if pinned image is > 6 months old
```

**SearXNG — Cornwall News use case** *(Phase 5, after SearXNG is deployed)*
Once SearXNG is running (Section 3.5), the research pipeline can query local
Cornwall-specific sources. Example use case to add to the digest pipeline:

> *"Check Cornwall Council's latest licensing and hospitality briefings.
>  Summarise any changes affecting pub licensing or food hygiene requirements."*

n8n weekly workflow: SearXNG query → Haiku summary → if relevant, insert
`action_required` item in digest with category `compliance`. This catches
licensing law changes before your annual review rather than after.

**Environment variable validation script** *(Phase 1 Step 6)*
Before starting any service, a quick script confirms all required env vars for that
service exist in Vault. Cheaper than debugging a service that starts but fails silently:
```bash
# scripts/check-vault-secrets.sh
REQUIRED_PATHS=(
  "secret/postgres"
  "secret/signing"
  "secret/encryption"
  "secret/anthropic"
  "secret/telegram"
)
for path in "${REQUIRED_PATHS[@]}"; do
  docker exec -e VAULT_TOKEN=$VAULT_TOKEN homeai-vault \
    vault kv get "$path" > /dev/null 2>&1 \
    && echo "✓ $path" || echo "✗ MISSING: $path"
done
```

**Build session time tracker** *(nice to have)*
A simple log entry in `AGENTS.md` after each session: date, duration, what was built,
what broke, what was fixed. Gives a running record of actual vs estimated build time.
The spec estimated 12-16 hours for Phase 1 — tracking actuals would be useful data.

### 3.3 Vault Secrets — Current State

All secrets loaded as of May 2026 session:

| Vault path | Fields | Status |
|---|---|---|
| secret/postgres | host, port, database, username, password | ✓ Loaded |
| secret/postgres-roles | homeai_pipeline, homeai_readonly, metabase_app | ✓ Loaded |
| secret/signing | payload_hmac_key | ✓ Loaded |
| secret/encryption | aes_key | ✓ Loaded |
| secret/anthropic | api_key | ✓ Loaded |
| secret/telegram | bot_token, chat_id | ✓ Loaded |
| secret/redis | password | ✓ Loaded (May 2026) |
| secret/grafana | admin_password | ✓ Loaded (May 2026) |
| secret/open-webui | secret_key | ✓ Loaded (May 2026) |
| secret/gmail/account1 | oauth_client_id, oauth_client_secret, refresh_token | ⏳ Needs OAuth flow |
| secret/gmail/account2 | oauth_client_id, oauth_client_secret, refresh_token | ⏳ Needs OAuth flow |
| secret/xero/trading | client_id, client_secret, refresh_token, org_id | ⏳ Needs OAuth flow |
| secret/xero/estates | client_id, client_secret, refresh_token, org_id | ⏳ Needs OAuth flow |
| secret/natwest/openbanking | client_id, client_secret, access_token, consent_id | ⏳ Phase 2 |
| secret/rbs/openbanking | client_id, client_secret, access_token, consent_id | ⏳ Phase 2 |
| secret/garmin | email, password | ⏳ Phase 2 |
| ~~secret/dext~~ | ~~api_key~~ | ❌ **Removed 2026-05-08** — Dext has no public API; manual review tool only |
| secret/github | personal_access_token | ⏳ Phase 5 |
| secret/google/calendar | oauth credentials | ⏳ Phase 3 |
| secret/google/sheets | oauth credentials | ⏳ Phase 3 |
| secret/google/drive | oauth credentials | ⏳ Phase 3 |

### 3.4 Phase 1 Additions (before moving to Phase 2)

**Vault backup on init** *(do immediately after Vault init)*
As soon as Vault is initialised and unsealed, back up the vault_data volume:
```bash
docker run --rm -v home_ai_vault_data:/vault/data \
  -v /mnt/mycloud/backups:/backup alpine \
  tar czf /backup/vault-init-$(date +%Y%m%d).tar.gz /vault/data
```
The encrypted vault data is useless without the unseal keys, but having it backed up
means a hardware failure doesn't require re-configuring all secrets from scratch.

**n8n webhook URL documentation** *(Phase 1 Step 11)*
Every n8n webhook URL is only known after the workflow is created. Create a file
`/home_ai/.claude/n8n-webhooks.md` during Step 11 build, listing every webhook URL
as they're created. Claude Code should update this file after each workflow is built.
Without it, the webhook URLs have to be looked up in n8n each time.

**Telegram bot /help command** *(Phase 1 Step 11, 5 minutes)*
Add a `/help` command to the Telegram bot that returns the full list of available
commands with descriptions. Cheap to add during Step 11 when the bot is being built,
annoying to add later.

### 3.5 Infrastructure Improvements

**Docker image version pinning strategy** *(all services)*
The Vault :latest failure showed the risk of unpinned images. Proposed policy:
- All services use pinned versions in docker-compose.yml
- A monthly Workflow B check queries Docker Hub for newer versions of pinned images
- Telegram notification when an image is > 6 months behind latest
- Manual decision to upgrade, not automatic

Current unpinned services in docker-compose.yml to fix:
- `postgres:latest` → `postgres:16.3`
- `n8nio/n8n:latest` → pin to current version
- `metabase/metabase:latest` → pin to current version
- `hashicorp/vault:1.15.6` → already pinned ✓
- `grafana/grafana:latest` → pin to current version

**Tailscale exit node for remote access** *(Phase 2)*
Currently Tailscale provides device-to-device connectivity. Adding the P620 as a
Tailscale exit node would let you route all traffic through it when on pub WiFi —
useful for accessing internal tools from any network without exposing ports.

### 3.6 SearXNG — Self-Hosted Web Search (add Phase 1 or Phase 2)

**What it is:** A self-hosted, free, no-API-key search engine running as a Docker
container. Aggregates results from Google, Bing, DuckDuckGo etc. without sending
your queries to any external service.

**Why it matters for this build — two use cases:**

**1. Open WebUI web search (immediate value — Phase 1)**
Gives Qwen3 on Open WebUI live web search capability with zero external dependency
or cost. Jo can ask "what's the latest hospitality employment law change" and get
real answers from the web, not just training data.

**2. Phase 5 research pipeline backend**
The spec's research pipeline needs a web search API. SearXNG running locally is the
cleanest answer — no rate limits, no API key, no data leaving the P620, no monthly
cost. Replaces the need for Serper, Exa, or Google Custom Search.

**docker-compose.yml addition:**
```yaml
  searxng:
    image: searxng/searxng:latest
    container_name: homeai-searxng
    networks: [ai-internal, ai-services]
    ports: ["8010:8080"]
    volumes:
      - ./security/searxng:/etc/searxng
    restart: unless-stopped
```

**Config file — create before first run:**
```bash
mkdir -p /home_ai/security/searxng
cat > /home_ai/security/searxng/settings.yml << 'EOF'
use_default_settings: true
server:
  secret_key: "generate-with-openssl-rand-hex-32"
  limiter: false
  image_proxy: false
search:
  safe_search: 0
  default_lang: "en-GB"
engines:
  - name: google
    engine: google
    use_mobile_ui: false
  - name: bing
    engine: bing
  - name: duckduckgo
    engine: duckduckgo
EOF
```

**Connect to Open WebUI:**
Settings → Tools → Web Search → Provider: SearXNG → URL: `http://searxng:8080`

**Connect to Phase 5 research pipeline:**
In n8n HTTP Request node: `POST http://searxng:8080/search?q={query}&format=json`

**Status:** Not yet built. Add to Phase 1 or early Phase 2 — 20 minutes to deploy.

---

### 3.7 Multi-Tool Routing Guide (Claude Code vs Aider vs Open WebUI)

The harness/orchestration layer matters as much as the model. Different tools for
different jobs — route tasks to the right tool rather than doing everything in one.

| Task type | Best tool | Why |
|---|---|---|
| Complex build steps (schema, RLS, Vault, n8n) | Claude Code + Sonnet | Needs deep spec context, multi-file edits |
| Targeted code fixes (one file, one function) | Aider + DeepSeek V4 Flash | Fast, cheap, OpenAI-compatible |
| Web research questions | Open WebUI + Qwen3 + SearXNG | Free, local, live search |
| Business data questions | Claude.ai + postgres-mcp | Live DB queries + reasoning |
| Quick build questions | Claude.ai (here) | Context from full conversation history |

**Setting up Aider with DeepSeek V4 Flash (for smaller coding tasks):**
```bash
pip install aider-chat
export DEEPSEEK_API_KEY=your-key-from-platform.deepseek.com
aider --model deepseek/deepseek-chat /home_ai/services/specific-file.py
```
At ~$0.17/M tokens it's essentially free for targeted fixes.

**The key rule:** Whatever tool you use, update AGENTS.md build state after the session.
The build state is in the file, not in the tool. Any tool can pick up where another left off.

---

### 3.8 Google Colab — Overflow Compute (Fine-Tuning + Heavy Analytics)

Colab is a **batch compute environment only** — never a persistent service, never
a data store, never a security boundary. The P620 remains the source of truth.
Vault credentials never leave the network. n8n is the data air-gap.

**When to use Colab vs local:**

| Task | P620 Local | Google Colab |
|---|---|---|
| Daily administration (24/7) | ✓ Yes | ✗ No — not persistent |
| Ralph monitoring loops | ✓ Yes | ✗ No |
| Invoice/email AI workers | ✓ Yes | ✗ No — latency |
| LoRA fine-tuning (7B-14B) | Possible (12GB tight) | ✓ Better — free T4 |
| LoRA fine-tuning (70B) | ✗ No — VRAM | ✓ Yes — paid A100 |
| Heavy batch analytics | Only if P620 is idle | ✓ Better — frees P620 |
| Model benchmarking | ✓ Yes | ✗ No |

---

#### USE CASE 1 — LoRA Fine-Tuning

Train a custom adapter on your specific business data (invoice formats, 
reconciliation patterns, pub EPoS terminology) to improve extraction accuracy
beyond what the base Qwen3 models achieve out of the box.

**Step 1 — Generate training data on P620 (n8n workflow):**

Pull "Golden Records" — verified correct extractions from `audit_log` — and
convert to JSONL instruction format:

```python
# n8n Code node — export golden records from audit_log
const records = await db.fetch("""
    SELECT al.ai_parsed, e.payload->>'body_text_safe' as input_text
    FROM audit_log al
    JOIN emails e ON al.record_id = e.id
    WHERE al.ai_worker = 'invoice_extractor'
      AND al.result = 'success'
      AND al.ai_parsed->>'confidence_score' > '0.90'
    LIMIT 1000
""");

// Convert to JSONL instruction format
const jsonl = records.map(r => JSON.stringify({
    instruction: "Extract invoice fields from this text. Return JSON with total, tax, supplier, date.",
    input: r.input_text,
    output: JSON.stringify(r.ai_parsed)
})).join('\n');

// Write to /home_ai/colab-exports/training-data.jsonl
```

Target: 500–1,000 high-quality examples. Quality over quantity — only use
records where confidence_score > 0.90 and no human correction was needed.

**Step 2 — Colab notebook (Unsloth — 2x faster, 70% less VRAM than standard):**

```python
# Cell 1 — Dependencies
!pip install unsloth xformers trl peft accelerate bitsandbytes -q

# Cell 2 — Load base model (upload training-data.jsonl to Colab first)
from unsloth import FastLanguageModel

model, tokenizer = FastLanguageModel.from_pretrained(
    model_name="unsloth/Qwen2.5-7B-Instruct",
    max_seq_length=2048,
    load_in_4bit=True,
)

model = FastLanguageModel.get_peft_model(
    model,
    r=16,
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj"],
    lora_alpha=16,
    lora_dropout=0,
    bias="none",
)

# Cell 3 — Load data and train
from datasets import load_dataset
from trl import SFTTrainer
from transformers import TrainingArguments

dataset = load_dataset("json", data_files="training-data.jsonl", split="train")

trainer = SFTTrainer(
    model=model,
    tokenizer=tokenizer,
    train_dataset=dataset,
    dataset_text_field="input",
    max_seq_length=2048,
    args=TrainingArguments(
        per_device_train_batch_size=2,
        gradient_accumulation_steps=4,
        num_train_epochs=3,
        learning_rate=2e-4,
        output_dir="./home_ai_adapter",
    ),
)
trainer.train()

# Cell 4 — Export as GGUF
model.save_pretrained_gguf(
    "home_ai_invoice_adapter",
    tokenizer,
    quantization_method="q4_k_m"
)
# Download the .gguf file from Colab Files panel
```

**Compute:** Free T4 GPU is sufficient for 7B model, 1,000 examples ≈ 1–2 hours.
Only upgrade to paid A100 if fine-tuning llama3.3:70b (unlikely to be necessary).

**Step 3 — Load adapter into Ollama on P620:**

```bash
# Copy downloaded .gguf to P620
scp home_ai_invoice_adapter.gguf joly@100.104.82.53:/home_ai/models/

# Create Ollama Modelfile
cat > /home_ai/models/Modelfile-invoice << 'EOF'
FROM qwen2.5:7b
ADAPTER /home_ai/models/home_ai_invoice_adapter.gguf
SYSTEM "You are a precise invoice extraction assistant trained on Atlantic Road Trading invoices. Extract fields as JSON."
EOF

# Load into Ollama
ollama create home-ai-invoice -f /home_ai/models/Modelfile-invoice

# Benchmark against base model before deploying:
# Add as a candidate in model evaluator, run extraction benchmark,
# compare accuracy vs qwen3:8b on your actual invoice samples
```

---

#### USE CASE 2 — Heavy Batch Analytics

Run complex ML analysis (Prophet forecasting, multi-year trend analysis) on
historical data without tying up the P620 during busy periods.

**The n8n Data Air-Gap (no credentials ever leave the P620):**

```javascript
// n8n Workflow — "Colab Data Export" (trigger manually or monthly)
// Node 1: Query PostgreSQL for sanitised historical data
const data = await db.fetch("""
    SELECT
        report_date,
        gross_sales,
        covers,
        food_sales,
        ROUND(food_sales/NULLIF(gross_sales,0)*100,1) as food_gp_pct,
        session
    FROM epos_daily_reports
    WHERE report_date > CURRENT_DATE - INTERVAL '2 years'
    ORDER BY report_date
    -- NO staff names, NO card numbers, NO personal data
""");

// Node 2: Write to temp file, upload to a private Google Drive folder
// or host briefly via n8n binary buffer endpoint
// Colab fetches via URL — no auth token, time-limited link
```

**Colab analytics notebook:**

```python
import pandas as pd
from prophet import Prophet
import requests

# Fetch sanitised data from n8n endpoint
df = pd.read_csv("YOUR_N8N_EXPORT_URL")
df['ds'] = pd.to_datetime(df['report_date'])
df['y'] = df['gross_sales']

# Prophet forecast — 90-day forward projection
model = Prophet(yearly_seasonality=True, weekly_seasonality=True)
model.fit(df)
future = model.make_future_dataframe(periods=90)
forecast = model.predict(future)

# Return results to n8n (POST to webhook, no secrets in URL)
results = {
    "forecast_id": "epos_prophet_90d",
    "generated_at": str(pd.Timestamp.now()),
    "predictions": forecast[['ds','yhat','yhat_lower','yhat_upper']].tail(90).to_dict('records')
}
requests.post("http://YOUR_TAILSCALE_IP:5678/webhook/colab-results", json=results)
```

n8n Colab Results webhook validates schema and writes to `analytics_results`
table in PostgreSQL. Ralph loop (Section 4.7) verifies schema before the
insert hits production tables — add to its check list.

---

#### Phased Implementation

| Phase | Task | When |
|---|---|---|
| **Phase 1** | Build n8n data export workflow — 12 months sanitised EPoS + Caterbook | Phase 2 (after pipelines running) |
| **Phase 2** | LoRA fine-tuning pilot — 100 invoices, free T4, test accuracy improvement | Phase 3 (after 60+ days of invoice data) |
| **Phase 3** | If pilot improves accuracy: full 1,000-example run, load adapter to Ollama, benchmark | Phase 3 |
| **Phase 4** | Prophet batch analytics for 7 properties — occupancy + cashflow forecasting | Phase 4 |

**Security checklist before any Colab session:**
- ✓ Export contains only sanitised data (no PII, no credentials, no Vault tokens)
- ✓ n8n webhook URL is Tailscale-internal (not public internet)
- ✓ Colab notebook does not contain any API keys or passwords
- ✓ Results validated by Ralph loop before hitting production tables
- ✓ Colab session terminated after use (not left running)

---

### 3.9 AI/Model Layer Improvements

**Thinking mode routing** *(Phase 2, small addition)*
Qwen3's `/think` mode is significantly better for complex multi-step reasoning but
slower. Add a `thinking_mode` flag to the AI worker dispatch in the Master Router:
- `reconciliation_explainer` → always `/think` (complex financial reasoning)
- `email_classifier` → never `/think` (simple classification, speed matters)
- `invoice_extractor` → `/no_think` for standard invoices, `/think` for flagged ones
- `digest_generator` → `/think` on Mondays (weekly summary), `/no_think` other days

This is a single field addition to the worker configuration in static_context.

**Prompt version control** *(Phase 2)*
Currently prompts are hardcoded in n8n Code nodes. When a prompt is updated
(because model drift alert fired, or a supplier changed invoice format), there's no
history of what changed. Add prompt versioning: store active prompts in static_context
with a `prompt_version` integer, and log every change to `audit_log` with the old
and new prompt text. Makes rollback trivial.

**Local embedding model** *(Phase 5, before Qdrant setup)*
The spec uses `nomic-embed-text` via Ollama for embeddings. As of 2026,
`mxbai-embed-large` (1.5GB, 1024-dim) benchmarks significantly better on retrieval
tasks. Pull alongside nomic-embed-text and benchmark both on a sample of your
actual emails and invoices before committing to either for the Qdrant collections.

---

### 3.10 Storyblok — Public-Facing Content (Phase 5, alongside Playground Agent)

**What it is:** An API-first, MCP-enabled headless CMS. Manages content (menus, events,
rooms, pages) in one place and delivers it anywhere via API. Free tier covers a single
site. Visual editor means you or your GM can update the pub website without touching code.

**Why it fits here:** The spec has the Playground Agent (Vercel auto-deploy) and a
Next.js frontend already planned. Storyblok is the content layer that makes those sites
editable after deployment — without requiring a developer every time the menu changes.

**Build timing:** Phase 5, alongside the Playground Agent. The infrastructure (Next.js,
Vercel, GitHub) is identical — Storyblok just adds a content API backend.

---

#### Use Case 1 — The Olde Malthouse Public Website

The spec covers the operational system (invoices, staff, EPoS) but not the pub's
public-facing presence. Storyblok solves this cleanly.

**Content managed in Storyblok:**
- Food and drinks menus (update without a developer — you or your GM)
- Events and special offers
- Room listings (B&B — link to Caterbook availability widget)
- Ice cream flavour list (updated by Ice Cream Oracle — see below)
- Opening hours, contact, location

**Architecture:**
```
Storyblok (content) → Next.js (frontend) → Vercel (hosting)
         ↑
    n8n webhook (auto-updates from operational data)
```

The frontend is a Next.js site deployed on Vercel — same pattern as the Playground
Agent. Storyblok serves the content via its delivery API. No server to manage,
no CMS to host, free tier handles the traffic of a Cornish pub website comfortably.

**One-time setup:**
```bash
# Install Storyblok CLI
npm install -g @storyblok/cli

# Scaffold a Next.js + Storyblok project in the playground
cd /home_ai/playground/projects
npx create-next-app@latest malthouse-website --typescript --tailwind
cd malthouse-website
npm install @storyblok/next

# Add Storyblok space API key to Vault (not hardcoded):
docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault \
  vault kv put secret/storyblok \
  space_id="YOUR_SPACE_ID" \
  api_token="YOUR_DELIVERY_TOKEN" \
  management_token="YOUR_MANAGEMENT_TOKEN"
```

---

#### Use Case 2 — The MCP Integration (highest value for daily use)

Storyblok is MCP-enabled — meaning Claude.ai (this interface) can read and write
pub website content directly as a tool call.

**Connect to Claude.ai (Phase 5):**
Settings → Integrations → Add MCP Server → Storyblok MCP endpoint

**What this enables:**
> *"Update the menu — remove the lamb shank and add tonight's fish special: pan-seared
> sea bass with samphire, £18.50"*
> → Claude via Storyblok MCP → pub website updated immediately

> *"Add an event: Live music Saturday 14th June, 8pm, free entry"*
> → Storyblok MCP → events page updated, no login required

This is the pub equivalent of having a marketing assistant. You describe the change
in plain English here, it appears on the website.

---

#### Use Case 3 — Automated Content Updates from Operational Data

The Home AI system already knows things the pub website should reflect. Wire them
together via n8n webhooks to the Storyblok Management API.

**Ice Cream Oracle → flavour list (two paths):**

*Path A — automated from database (weekly):*
```javascript
// n8n Code node — fires when Ice Cream Oracle weekly report is generated
// Updates the ice cream flavour list on the Storyblok website automatically

const MANAGEMENT_TOKEN = await vault.get('secret/storyblok', 'management_token');
const SPACE_ID = await vault.get('secret/storyblok', 'space_id');
const FLAVOUR_STORY_ID = 'YOUR_FLAVOUR_PAGE_ID';

// Get current Oracle recommendations from DB
const flavours = await db.fetch("""
    SELECT flavour_name, quadrant, avg_units
    FROM epos_flavour_daily
    WHERE report_date > CURRENT_DATE - 7
      AND quadrant IN ('STAR', 'PUZZLE')  -- only show active flavours
    ORDER BY quadrant, avg_units DESC
""");

// Push to Storyblok Management API
await fetch(`https://mapi.storyblok.com/v1/spaces/${SPACE_ID}/stories/${FLAVOUR_STORY_ID}`, {
    method: 'PUT',
    headers: {
        'Authorization': MANAGEMENT_TOKEN,
        'Content-Type': 'application/json'
    },
    body: JSON.stringify({
        story: {
            content: {
                component: 'flavour-list',
                flavours: flavours.map(f => ({
                    name: f.flavour_name,
                    available: true
                }))
            }
        },
        publish: 1  // publish immediately
    })
});
```

**Other automated updates to consider:**
- Opening hours change (bank holidays, events) → n8n → Storyblok
- Special menus (Sunday roast, set menu) → n8n → Storyblok
- Accommodation availability note (full / availability) → Caterbook data → Storyblok

*Path B — GM photo via Telegram (vision-powered, Phase 5):*

Your GM photographs the chalkboard or types the day's flavours into Telegram.
The vision model reads it and updates the website. No CMS login required.

```javascript
// n8n Telegram photo handler — fires when GM sends image to bot with caption "flavours"
const photoFileId = $input.first().json.message.photo.slice(-1)[0].file_id;
const photoUrl = await getTelegramFileUrl(photoFileId, TELEGRAM_TOKEN);
const photoBase64 = await fetchAsBase64(photoUrl);

// gemma4:e4b — vision capable, 4B effective params, ~5.5GB VRAM
// IMPORTANT: use gemma4:e4b — there is no gemma4:9b variant
const visionResult = await fetch('http://ollama:11434/api/generate', {
  method: 'POST',
  body: JSON.stringify({
    model: 'gemma4:e4b',
    prompt: 'Extract ice cream flavour names from this chalkboard image. Return a JSON array of strings only.',
    images: [photoBase64],
    stream: false
  })
}).then(r => r.json());

const flavours = JSON.parse(visionResult.response);

// Update Storyblok and confirm to GM
await updateStoryblokFlavourList(flavours);
await telegram.send(`✓ Updated ${flavours.length} flavours on the website: ${flavours.join(', ')}`);
```

Requires: `ollama pull gemma4:e4b` (5.5GB — fits in RTX 3060 12GB alongside hot tier).

**Ralph loop check (add to Workflow G):** Verify the Storyblok Management API
is reachable and that the last auto-update succeeded. Flag if the pub website
is more than 24 hours out of sync with what the Ice Cream Oracle recommends.

---

#### Storyblok vs Playground Agent — which for what

| Use | Playground Agent | Storyblok |
|---|---|---|
| One-off prototypes (event page, landing page) | ✓ Yes — Vercel preview URL | ✗ No |
| Permanent pub website | ✗ No — wrong tool | ✓ Yes |
| Content editable by non-developers | ✗ No | ✓ Yes |
| Automated content from operational data | ✗ No | ✓ Yes — Management API |
| Claude.ai direct content control | ✗ No | ✓ Yes — MCP |

---

#### Phased implementation

| Step | Task | When |
|---|---|---|
| 1 | Create Storyblok free account, set up Malthouse space, define content models (menu, events, rooms) | Phase 5 start |
| 2 | Build Next.js frontend in Playground, deploy to Vercel, connect Storyblok delivery API | Phase 5 |
| 3 | Connect Storyblok MCP to Claude.ai — test menu update via natural language | Phase 5 |
| 4 | Add Vault secret for Storyblok tokens | Phase 5 (alongside step 1) |
| 5 | Wire Ice Cream Oracle → Storyblok auto-update via n8n | Phase 5 (after Oracle is running) |
| 6 | Add Ralph loop check for website sync status | Phase 5 |

**Cost:** Free tier covers everything needed for a single-site pub. No infrastructure
to manage — Storyblok hosts the CMS, Vercel hosts the frontend.

### 3.11 Disaster Recovery & Self-Installing Backup (Phase 2 hardening)

**When to build:** End of Milestone C — once you have real data worth protecting.
`backup-all.sh` runs weekly via cron. `bootstrap.sh` and `restore.sh` built and
tested in Phase 2 hardening on a VM before you ever need them on real hardware.

**Recovery target:** Fresh Ubuntu 26.04 install → fully running system with all data
restored in 2-3 hours of active time (plus model download time in background).

---

#### The four layers

| Layer | What covers it | When runs |
|---|---|---|
| Code + config | Git repo (`/home_ai`) | Every commit |
| Live data snapshot | `backup-all.sh` | Weekly cron |
| Fresh machine setup | `bootstrap.sh` | On demand (new hardware) |
| Data restore | `restore.sh` | On demand (disaster recovery) |

---

#### `backup-all.sh` — weekly data snapshot

Build at end of Milestone C. Run weekly via cron alongside Restic.

```bash
#!/bin/bash
# /home_ai/scripts/backup-all.sh
# Full system snapshot: DB + Vault + n8n workflows + git push
# Runs weekly — cron: 0 3 * * 0 /home_ai/scripts/backup-all.sh

set -euo pipefail
BACKUP_DIR="/mnt/hdd/backups/homeai-$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

echo "[1/5] Exporting PostgreSQL..."
docker exec homeai-postgres pg_dump -U postgres homeai \
  | gzip > "$BACKUP_DIR/homeai.sql.gz"
docker exec homeai-postgres pg_dump -U postgres metabase_app \
  | gzip > "$BACKUP_DIR/metabase_app.sql.gz"

echo "[2/5] Vault snapshot..."
docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault \
  vault operator raft snapshot save /vault/data/snapshot.snap
docker cp homeai-vault:/vault/data/snapshot.snap \
  "$BACKUP_DIR/vault-snapshot.snap"

echo "[3/5] Exporting n8n workflows..."
mkdir -p "$BACKUP_DIR/n8n-workflows"
# Export via n8n API
curl -s -H "X-N8N-API-KEY: $N8N_API_KEY" \
  http://localhost:5678/api/v1/workflows \
  | jq -r '.data[] | @json' > "$BACKUP_DIR/n8n-workflows/all-workflows.jsonl"

echo "[4/5] Git push (code + config)..."
cd /home_ai && git add -A && \
  git commit -m "backup: $(date +%Y-%m-%d) automated snapshot" --allow-empty && \
  git push origin main

echo "[5/5] Restic to NAS + OneDrive..."
restic -r /mnt/mycloud/homeai-backup backup "$BACKUP_DIR" \
  --tag weekly-snapshot

echo "✓ Backup complete: $BACKUP_DIR"
# Telegram notification (via n8n webhook or direct API call)
```

**Note:** Vault snapshot restores data but still requires manual unseal with your
offline keys — by design. This is correct security behaviour.

---

#### `bootstrap.sh` — fresh machine setup

Runs once on a new Ubuntu 26.04 install. Idempotent — safe to re-run.

```bash
#!/bin/bash
# /home_ai/scripts/bootstrap.sh
# Prepares a fresh Ubuntu 26.04 machine for Home AI
# Run as: curl -sSL https://raw.githubusercontent.com/YOUR_REPO/bootstrap.sh | bash
# Or: git clone your-repo && ./scripts/bootstrap.sh

set -euo pipefail
REPO_URL="git@github.com:YOUR_USERNAME/home-ai.git"

echo "[1/6] System packages..."
sudo apt-get update && sudo apt-get install -y \
  docker.io docker-compose-v2 git curl age \
  openssh-server ufw python3-pip

echo "[2/6] Docker group..."
sudo usermod -aG docker "$USER"

echo "[3/6] NVIDIA drivers + Docker GPU support..."
# Ubuntu 26.04 includes NVIDIA drivers in kernel 7.0
# Verify: nvidia-smi should show RTX 3060
sudo apt-get install -y nvidia-container-toolkit
sudo systemctl restart docker

echo "[4/6] Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
echo "→ Run: sudo tailscale up  (authenticate with your account)"

echo "[5/6] Clone repo..."
git clone "$REPO_URL" /home_ai
cd /home_ai

echo "[6/6] Pull Docker images..."
docker compose pull  # pulls all pinned image versions
# Note: Ollama models are NOT pulled here — too large, pull separately:
# docker exec homeai-ollama ollama pull qwen3:8b
# docker exec homeai-ollama ollama pull qwen3:14b
# docker exec homeai-ollama ollama pull llama3.3:70b  (42GB — start overnight)

echo "✓ Bootstrap complete. Next: run ./scripts/restore.sh with your backup archive."
echo "  Or for a fresh start: run ./start.sh and follow Phase 1 Milestone A steps."
```

---

#### `restore.sh` — data restore on new hardware

Reads a backup archive created by `backup-all.sh` and restores the full system.

```bash
#!/bin/bash
# /home_ai/scripts/restore.sh BACKUP_DIR
# Restores PostgreSQL + Vault + n8n workflows from a backup-all.sh snapshot
# Run AFTER bootstrap.sh and AFTER ./start.sh brings services up

set -euo pipefail
BACKUP_DIR="${1:?Usage: restore.sh BACKUP_DIR}"

echo "[1/5] Starting core services (Vault + Postgres)..."
cd /home_ai && ./start.sh
# Note: Vault will need manual unseal with your offline keys

echo "[2/5] Restoring PostgreSQL..."
# Drop and recreate (assumes fresh install)
docker exec -i homeai-postgres psql -U postgres -c "DROP DATABASE IF EXISTS homeai;"
docker exec -i homeai-postgres psql -U postgres -c "CREATE DATABASE homeai;"
gunzip -c "$BACKUP_DIR/homeai.sql.gz" \
  | docker exec -i homeai-postgres psql -U postgres homeai

docker exec -i homeai-postgres psql -U postgres -c "DROP DATABASE IF EXISTS metabase_app;"
docker exec -i homeai-postgres psql -U postgres -c "CREATE DATABASE metabase_app;"
gunzip -c "$BACKUP_DIR/metabase_app.sql.gz" \
  | docker exec -i homeai-postgres psql -U postgres metabase_app

echo "[3/5] Restoring Vault..."
docker cp "$BACKUP_DIR/vault-snapshot.snap" homeai-vault:/tmp/snapshot.snap
docker exec -e VAULT_TOKEN="$VAULT_TOKEN" homeai-vault \
  vault operator raft snapshot restore /tmp/snapshot.snap
echo "→ Vault restored. Unseal manually with your offline keys if needed."

echo "[4/5] Importing n8n workflows..."
while IFS= read -r workflow; do
  curl -s -X POST \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$workflow" \
    http://localhost:5678/api/v1/workflows
done < "$BACKUP_DIR/n8n-workflows/all-workflows.jsonl"

echo "[5/5] Pulling Ollama models (background)..."
docker exec homeai-ollama ollama pull qwen3:8b &
docker exec homeai-ollama ollama pull qwen3:14b &
echo "→ Models downloading in background. llama3.3:70b (42GB) pull separately when ready."

echo ""
echo "✓ Restore complete. Manual steps remaining:"
echo "  1. Re-authenticate Tailscale: sudo tailscale up"
echo "  2. Re-run OAuth flows: Gmail, Xero, Google Calendar"
echo "  3. Pull llama3.3:70b: docker exec homeai-ollama ollama pull llama3.3:70b"
echo "  4. Test with Gate A checklist: /check-vault then /verify-phase1"
```

---

#### What requires manual re-authorisation after restore

| Item | Why | Time |
|---|---|---|
| Tailscale | Machine identity changes on new hardware | 2 min |
| Gmail OAuth | Tokens expire / tied to machine | 10 min per account |
| Xero OAuth | Same — both orgs | 10 min |
| Google Calendar/Sheets | Same | 5 min |
| Vault unseal | By design — offline keys required | 5 min |
| Open WebUI login | Session keys changed | 1 min |

Total manual re-authorisation time on a full hardware restore: **~45 minutes.**

---

#### Store the bootstrap in your private GitHub repo

The `/home_ai` repo should be private (it contains your docker-compose with service
structure). The scripts live at `/home_ai/scripts/`. The git remote is set up in
`bootstrap.sh`. After every significant build session, push to main:

```bash
cd /home_ai && git add -A && git commit -m "session: [what was built]" && git push
```

This means on a new machine: `git clone` → `bootstrap.sh` → `restore.sh` → running.

### 3.12 Anthropic May 2026 Features — Local Implementations

**What shipped (May 6-7, 2026):** Outcomes, Dreaming, multiagent orchestration, webhooks,
doubled rate limits, CI Auto-Fix.

**Critical distinction:** Outcomes and Dreaming are Claude Managed Agents platform features
— they require Anthropic's cloud API with `managed-agents-2026-04-01` beta header. They do
NOT run inside your local n8n/Ollama setup. Your build implements the same *patterns* locally.

| Anthropic feature | Your local implementation | Where in spec |
|---|---|---|
| Outcomes | OutcomeObject Code node pattern in every pipeline | Section 6.2 construction rules |
| Dreaming | Workflow H — nightly audit_log → Haiku → heuristics.md | Section 7.2 Phase 2 |
| CI Auto-Fix | GitHub Actions SQL tests + Claude Code PR auto-fix | Section 7.2 Phase 2 hardening |
| Multiagent orchestration | Already implemented via parallel subagents in Claude Code | AGENTS.md |
| Webhooks | n8n webhook nodes (already in use) | Throughout spec |
| Doubled rate limits | Immediate benefit — longer Claude Code sessions without throttling | No spec change needed |

**Future migration path (Phase 6 or later):**

When the system matures and volume grows, migrating the AI worker layer to Claude Managed
Agents would give you the native Outcomes grader and Dreaming without maintaining the local
implementations. But at current scale (200 emails/day, 13 pipelines) the local approach is
more appropriate — no cloud dependency for business-critical data processing.

**What not to implement from the Gemini review:**

- "Rip out audit_log and replace with Outcomes" — wrong. audit_log is your compliance trail
  and drift alerting substrate. Outcomes is an additional pattern on top of it, not a replacement.
- "Llama 4 Maverick as escalation tier" — Meta model, not available via Anthropic APIs.
- "CI Auto-Fix and M365 agents available in this environment" — CI Auto-Fix requires GitHub
  Actions, not a local environment feature. M365 add-ins are not relevant to this build.

### 3.13 Paperless-ngx — Physical Document Digitisation (Phase 3)

**What it is:** Open-source document management system. Handles scan intake, OCR,
intelligent document splitting, ML auto-tagging, full-text search, and REST API.
Runs as a Docker container on the P620. The Home AI system enriches and routes
documents downstream. Build in Phase 3 alongside document control.

**Hardware:** Brother ADS-2800W connects via SMB (Scan to Network) directly to
a Samba consume folder on the P620. One touchscreen button — no PC required.

**The document separation problem (solved three ways):**

| Approach | How | When |
|---|---|---|
| **Blank page separators** (start here) | Insert blank sheet between docs before loading ADF. Set "Skip Blank Page: OFF" | Now — simple, reliable, free |
| **Barcode separators** (upgrade) | Print Patch-T barcode pages, insert between docs | When blank pages cause false splits |
| **AI boundary detection** (Phase 5) | `gemma4:e4b` analyses each page for letterhead/date/type changes | Phase 5 — no physical separators |

**Scanner one-touch setup (ADS-2800W web interface):**
- Profile: "AI BATCH" | SMB to P620 Tailscale IP | Store to `paperless-consume`
- File type: Searchable PDF | 300 DPI | Skip Blank Page: OFF | Duplex: ON

**Weekly workflow (5 minutes of human time):**
1. Sort correspondence, insert blank separators between documents
2. Load ADF, press "AI BATCH" touchscreen button
3. Walk away — Paperless splits, OCRs, auto-tags
4. Once per week: open Paperless inbox (port 8011), verify AI tags (2 min), Archive

**Integration with Home AI (n8n Workflow I):**
- Paperless calls n8n webhook on each new document
- Haiku enriches: entity_id, category, action_required, deadline, summary
- Invoice detected? → Invoice Pipeline
- Compliance date? → compliance_alerts table
- All documents: PostgreSQL + Obsidian vault + rclone → Google Drive

**Phase 5 AI boundary detection:**
```python
# gemma4:e4b vision pre-processor (no physical separators needed)
# Analyses each page, identifies document boundaries:
# letterhead change, new sender/recipient, different document type, date jump
# Splits PDF automatically before Paperless consumes it
```

**Port:** 8011. **Vault secrets:** secret/paperless (api_token, db_password, secret_key).
**Full implementation:** SPEC v5.4 Section 8.1b.

---

### 3.14 Guest Review Response Assistant ★ PRIORITY (Phase 2 — first chunk)

Weekly Playwright scrape of Google Business + TripAdvisor for the Malthouse (pub)
and the Sandwich shop. New reviews land in the Action Queue with a Sonnet-drafted
response pre-filled. Jo approves/edits; posting stays manual (no auto-post). Telegram
alert (immediate, not weekly) if any review ≤3 stars. Cuts review-response time below
48 hours without daily manual checking — directly affects star averages and bookings.

Components: Playwright scraper (extends competitor-watch), Sonnet drafter with cached
hospitality-tone prompt, Action Queue card type `guest_review`. Tables `guest_reviews`
+ `review_drafts` (V44).

**Full implementation:** SPEC.md §7.4

---

### 3.15 Structured Outputs / JSON Schema Constrained Generation (Phase 1 hardening)

Replace "prompt says return JSON" with Ollama's `format` parameter (constrained
generation) and Anthropic tool-use with `input_schema`. Output is guaranteed
schema-valid; hallucinated field names → 0% by construction. Eliminates "parse
JSON from AI response" Code nodes entirely.

**Sequence before §3.14–§3.18** — the new Phase 2 pipelines should be born on this
pattern, not retrofitted. Updates 6 Ollama Code nodes + 4 Anthropic call sites.
New `/home_ai/ai_schemas/` directory version-controls the schemas.

**Full implementation:** SPEC.md §7.3

---

### 3.16 Companies House API Integration (Phase 2)

Free, no-auth UK Companies House API. Weekly check of ARTL + AREL filing deadlines
catches the £150 late-confirmation-statement penalty and £150–£1500 late-accounts
penalties before they happen. Bot-responder gets a `verify_company` tool slug so Jo
can email the bot "verify company 12345678" for any supplier/tenant lookup.

Endpoint: `GET https://api.company-information.service.gov.uk/company/{company_number}`.
Tables `companies_house_log` + `companies_house_alerts` (V44). One-time setup: Jo
provides ARTL + AREL company numbers.

**Full implementation:** SPEC.md §7.5

---

### 3.17 Land Registry Price Paid API (Phase 2)

Free, no-auth UK Land Registry. Monthly comparable-sales report for the 7 Atlantic
Road Estates properties. Real market data for insurance renewal, refinancing, and
periodic valuation sanity checks — no more manual Rightmove checking.

Endpoint: `GET https://landregistry.data.gov.uk/app/ppd/ppd_data.csv?postcode={pc}&from={date}`.
Tables `properties` + `property_market_log` + view `v_property_comparable_summary`
(V44). One-time setup: Jo provides 7 property postcodes + acquisition prices.

**Full implementation:** SPEC.md §7.6

---

### 3.18 VAT Return Preparation Workflow (Phase 2 — DORMANT until P3 Xero unblocks)

Quarterly Xero query → pre-filled Box 1-9 UK VAT return + anomaly flagging →
Action Queue card "VAT REVIEW DUE". Jo still files manually through Xero; this
just means figures are pre-checked and anomalies caught before submission. Reduces
quarterly accountant review burden.

**Gated on `system_state.p3_xero='live'`** — Xero sync is parked on Xero support
response. Schema + logic land in V44 but cron stays dormant. Activate later via
`UPDATE system_state SET value='live' WHERE key='p3_xero'`.

Anomaly rules: Box 4 (input VAT) > 2× rolling 4-quarter avg; vendor invoices
>£500 without matching bank transactions; (net standard sales × 0.20) vs Box 1
difference > £20.

**Full implementation:** SPEC.md §7.7

---

### 3.19 Materialized Views for Dashboard Performance (Phase 3+ optimisation — no SPEC section yet)

Stretch-only pointer. Several dashboard views aggregate large rowsets; on a busy
day Mission Control could feel slow. Candidates for materialisation with cron-based
refresh: `v_daily_unit_economics`, `v_daily_cost_vs_sales`, `v_daily_labour_by_team`,
`v_kpi_anomalies`.

Implementation deferred — revisit when a specific dashboard endpoint actually feels
slow (we'd notice via Prometheus latency metrics on `/api/economics/overview`).
Pattern: `CREATE MATERIALIZED VIEW mv_<name> AS SELECT … ; REFRESH MATERIALIZED VIEW
CONCURRENTLY mv_<name>` on a 15-min cron. Indexes carry over from base tables but
need re-creation on the materialised view explicitly.

Not in SPEC.md yet — promote to a numbered section if/when we ship it.

---

