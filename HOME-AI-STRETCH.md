# HOME AI — STRETCH & UPDATE DOCUMENT v2.0
## Living Amendment to SPEC v5.1
## Owner: Jo | Atlantic Road Trading Ltd / Atlantic Road Estates Limited
## Started: May 2026 | Updated as discoveries are made during build

---

**HOW THIS DOCUMENT WORKS**

This is the first document Claude Code should read at the start of every session,
alongside AGENTS.md. It captures:
- Build lessons learned (things the spec got wrong or didn't anticipate)
- Known fixes for specific errors
- Model stack updates as new releases land
- New ideas and stretch goals discovered during build
- Pre-flight checks before starting each session

When something breaks and you fix it — add it here immediately.
When a new model releases — update the model stack table.
When a new idea is worth capturing — add it to the stretch goals section.

**Session opening prompt:**
> *"Read HOME-AI-STRETCH-v1.0.md first, then AGENTS.md. Note any known issues
> or model updates before we start. We are on [Phase N, Step N]."*

---

## SECTION 1 — BUILD LESSONS LEARNED

### 1.1 Environmental Sensing Protocol (run before every Claude Code session)

**Philosophy: Sense first, then act.** Claude Code must never assume system state.
The P620 is a living system — a reboot, a Vault re-seal, a failed pull, or a kernel
update can change everything. Run the senses before touching anything.

```bash
# ── SENSE 1: OS and kernel ───────────────────────────────────────
lsb_release -a && uname -r
# Expected: Ubuntu 26.04 (Resolute Raccoon), Kernel 7.0.x
# Why: Kernel 7.0 changes Docker io_uring and memory pressure handling.
# If 26.04 confirmed: Vault must use disable_mlock=true + seccomp:unconfined
#                     (already configured — this confirms it's still needed)

# ── SENSE 2: GPU topology ────────────────────────────────────────
nvidia-smi
# Expected: RTX 3060, 12GB VRAM, driver 5xx+
# Why: VRAM dictates model offloading strategy.
# If 3060 (12GB): heavy tier stays RAM-resident (llama3.3:70b)
# If upgrade to 24GB: heavy tier can move to VRAM — update model.tiers

# ── SENSE 3: Tailscale connectivity ─────────────────────────────
ip addr show tailscale0 | grep "100\."
# Expected: 100.104.82.53
# Why: If 100.x.x.x IP is missing, all remote n8n webhooks fail silently
#      (Gmail OAuth callbacks, Xero webhooks, external triggers)

# ── SENSE 4: Vault seal state ────────────────────────────────────
docker exec homeai-vault vault status 2>/dev/null | grep "Sealed"
# Expected: Sealed          false
# If "Sealed: true" → DO NOT run docker compose up — run ./start.sh instead
# Ghost Loop warning: see Section 1.2

# ── SENSE 5: n8n pipeline health ────────────────────────────────
docker logs homeai-n8n --tail 30 2>&1 | grep -iE "error|could not find|failed"
# Expected: no output (clean)
# If errors: diagnose before adding new workflows

# ── SENSE 6: Build state ─────────────────────────────────────────
grep "Last completed step" /home_ai/AGENTS.md
cd /home_ai
```

**After senses confirm healthy — start services:**
```bash
./start.sh   # ALWAYS use start.sh — NEVER docker compose up directly
```

**Opening prompt for Claude Code (paste at start of every session):**
```
Execute environment discovery before anything else:
1. Run lsb_release -a && uname -r — confirm Ubuntu 26.04 + Kernel 7.0
2. Run nvidia-smi — report VRAM available and confirm GPU model
3. Run ip addr show tailscale0 — confirm Tailscale 100.x.x.x is active
4. Run docker exec homeai-vault vault status — report Sealed status
5. Run docker logs homeai-n8n --tail 20 | grep -i error — report any errors
6. Read AGENTS.md — report Last completed step
7. Read HOME-AI-STRETCH.md — note any pending decisions or known issues

Do not proceed until all six senses are reported. Then await my task.
```

**CRITICAL — The Ghost Loop:** If Vault is sealed and you run `docker compose up`
without `./start.sh`, compose injects blank strings for all passwords. Containers
appear to start but fail silently — Metabase can't connect to Postgres, n8n can't
write events, pipelines produce no output. The system looks alive but is dead.
Symptom: no dead letters, no audit_log entries, no errors — just silence.
Fix: `docker compose down` then `./start.sh`.

### 1.2 Known Issues and Fixes

**ISSUE: `permission denied while trying to connect to the Docker API`**
- Cause: Docker group membership not active in current shell
- Fix: `newgrp docker` (temporary, current shell only)
- Permanent fix: `sudo usermod -aG docker joly` then FULL logout and login
- Note: `newgrp docker` expires when you close the terminal — need it again each session until you do the full logout/login

**ISSUE: Vault container crash-loops with `unable to set CAP_SETFCAP effective capability`**
- Cause: Ubuntu 26.04 (Resolute) blocks CAP_SETFCAP at kernel level via AppArmor
- Fix: Use specific vault image version (NOT latest) + custom vault.hcl with `disable_mlock = true`
- vault service in docker-compose.yml must use:
  ```yaml
  image: hashicorp/vault:1.15.6   # NEVER use :latest — breaks on Ubuntu 26+
  command: vault server -config=/vault/config/vault.hcl
  cap_add: [IPC_LOCK]
  security_opt:
    - no-new-privileges:false
    - seccomp:unconfined
  volumes:
    - vault_data:/vault/data
    - ./security/vault-policies:/vault/policies
    - ./security/vault-config:/vault/config   # ADD THIS
  ```
- vault.hcl must include `disable_mlock = true` — this avoids needing CAP_SETFCAP entirely
- Full vault.hcl at: `/home_ai/security/vault-config/vault.hcl`

**ISSUE: YAML indentation error in docker-compose.yml**
- Cause: Service block accidentally lost its 2-space indent (e.g. `vault:` instead of `  vault:`)
- Fix: `sed -n '40,70p' /home_ai/docker-compose.yml` to find the broken line
- Test before restarting: `docker compose config --quiet && echo "YAML OK"`

**ISSUE: Ubuntu version mismatch**
- SPEC says Ubuntu 22.04 LTS — actual installed OS is Ubuntu 26.04 (Resolute)
- This caused the CAP_SETFCAP issue (newer AppArmor defaults)
- No action needed — the fixes above handle it
- Update AGENTS.md environment.md to reflect Ubuntu 26.04

**ISSUE: Metabase pointed at wrong database + role**
- Cause: SPEC had `MB_DB_DBNAME: homeai` and `MB_DB_USER: homeai_readonly`
- Result: Metabase tried to create Liquibase metadata tables in the application DB
  using a read-only role — correctly denied, crash-loop
- Fix: Created dedicated `metabase_app` database and role with full ownership
- Migration: `/home_ai/postgres/migrations/V2__metabase_db.sql`
- docker-compose.yml now uses `MB_DB_DBNAME: metabase_app`, `MB_DB_USER: metabase_app`,
  `MB_DB_PASS: ${METABASE_APP_PASSWORD}`
- Secret stored at: `secret/postgres-roles` field `metabase_app`
- Add homeai database as a Metabase Data Source via the UI (homeai_readonly creds)
- NEVER grant CREATE to homeai_readonly — defeats RLS/least-privilege model

**ISSUE: Vault unseal keys exposed in chat session**
- Cause: Unseal keys pasted into a chat window during a recovery session
- Fix: Vault rekey + root token rotation immediately after discovery
- Procedure: `vault operator rekey -init` then submit 3 old keys → receive 5 new keys
- Root rotation: `vault operator generate-root -init` → submit 3 new keys → decode token
- Rule: NEVER paste unseal keys or root tokens into any chat window ever

**ISSUE: start.sh not running — containers start with blank passwords**
- Cause: Running `docker compose up -d` directly instead of `./start.sh`
- Symptoms: WARN messages about blank env vars, containers crash-loop or run insecurely
- Fix: Always use `./start.sh` — it fetches all secrets from Vault before compose starts
- If start.sh fails: check VAULT_TOKEN is exported, Vault is unsealed, all secret paths exist

**ISSUE: SPEC port conflict — model-evaluator on 8080 clashes with Open WebUI**
- SPEC originally assigned port 8080 to model-evaluator
- Open WebUI also uses port 8080 (8088 on host, but internal port 8080)
- Fix applied: model-evaluator now uses port 8008
- All SPEC references to `localhost:8080/api/models/` should read `localhost:8008/api/models/`

**ISSUE: init_placeholder HMAC signature in static_context_change trigger**
- Location: `init-db.sql` — the `static_context_change` trigger
- Problem: writes `payload_signature='init_placeholder'` instead of a real HMAC-SHA256
- Build rule violated: "ALWAYS sign event payloads before INSERT to events table"
- Status: flagged as pre-existing tech debt, deferred to a separate fix step
- Do NOT fix inline during other steps — touches RLS-bypassing code paths

**ISSUE: Auto-compaction fired mid-session during file write**
- Cause: Context window exceeded 83% during a large file write (SPEC.md ~2,100 lines)
- Result: Claude lost context, had to re-orient from AGENTS.md and skill files
- Lesson: Run `/compact` before reaching 60% — especially before large file writes
- On restart, Claude correctly read AGENTS.md, skill files, and checked disk state before continuing

**ISSUE: `vault operator init` fails — container still restarting**
- Cause: Running init before the container is fully stable
- Fix: `docker ps | grep vault` must show `Up X minutes` (not `Restarting`) before running init
- Wait script: `until docker ps | grep -q "homeai-vault.*Up"; do sleep 3; done && echo "READY"`

**ISSUE: `newgrp docker` shell expired between commands**
- Cause: Opening a new terminal tab resets group membership
- Fix: Always run `newgrp docker` at the start of each terminal session
- Permanent fix: log out completely and log back in

### 1.3 Environment Facts (actual, not spec assumptions)

| Item | Spec assumed | Actual |
|---|---|---|
| Ubuntu version | 22.04 LTS | 26.04 Resolute |
| Vault image | hashicorp/vault:latest | hashicorp/vault:1.15.6 (pinned) |
| Vault config | Env-var based | vault.hcl file at /security/vault-config/ |
| Docker group | Active after usermod | Requires full logout/login or `newgrp docker` |
| Vault mlock | Enabled (IPC_LOCK) | Disabled (disable_mlock = true in vault.hcl) |
| Metabase DB | homeai (app DB) | metabase_app (dedicated DB + role) |
| Startup method | docker compose up -d | ./start.sh (fetches secrets from Vault first) |
| Model evaluator port | 8080 (SPEC typo) | 8008 (fixed — 8080 conflicts with Open WebUI) |

---

## SECTION 2 — MODEL STACK UPDATES

### 2.1 Current Recommended Tiers (as of May 2026)

The spec's original model recommendations are outdated. Qwen3 (released April 2025)
provides one tier higher quality at the same VRAM cost via architectural improvements.

**Update these values in static_context `model.tiers` once Milestone B is complete.**

| Tier | Original spec | Updated recommendation | VRAM | Notes |
|---|---|---|---|---|
| Hot | qwen2.5:7b | **qwen3:8b** | 5.2GB | Matches old qwen2.5:14B quality. Has thinking mode. |
| Medium | phi4:14b | **qwen3:14b** | 9.3GB | Matches old qwen2.5:32B quality. Fits 12GB VRAM. |
| Heavy | llama3.3:70b | llama3.3:70b (unchanged) | RAM | Unchanged until GPU upgrade |
| Cloud escalation | claude-haiku-4-5 → claude-sonnet-4-6 | unchanged | API | |

**Qwen3 key advantages over previous recommendations:**
- Thinking mode: `/think` and `/no_think` commands per-prompt — heavy reasoning when needed, fast response otherwise
- Better structured JSON output (critical for invoice_extractor and reconciliation_explainer)
- Stronger multilingual (irrelevant for this build but free improvement)
- qwen3:8b benchmarks: ~40 t/s on RTX 3060 at Q4_K_M

**Ollama pull commands:**
```bash
ollama pull qwen3:8b     # 5.2GB — hot tier
ollama pull qwen3:14b    # 9.3GB — medium tier
# Deploy via model evaluator after pulling:
curl -X POST http://localhost:8080/api/models/qwen3%3A8b/deploy/hot
curl -X POST http://localhost:8080/api/models/qwen3%3A14b/deploy/medium
```

### 2.2 Model Auto-Discovery (proposed Workflow B extension)

**Gap identified during build:** The spec benchmarks existing models but has no mechanism
to discover when new model versions are released on Ollama. This requires manual checking.

**Proposed addition to Workflow B (weekly scanner):**

Add a second check after the existing benchmark scan — query the Ollama registry API
for newer tags on monitored model families, compare against installed versions,
and send a Telegram notification if updates exist:

```javascript
// Add to Workflow B Code node — after existing benchmark checks:
const monitoredFamilies = ['qwen3', 'deepseek-r1', 'llama3.3', 'granite3.3'];
const ollamaApiBase = 'http://localhost:11434/api';

for (const family of monitoredFamilies) {
  // Get currently installed tags for this family
  const installed = await fetch(`${ollamaApiBase}/tags`).then(r => r.json());
  const installedTags = installed.models
    .filter(m => m.name.startsWith(family))
    .map(m => ({ name: m.name, modified: new Date(m.modified_at) }));

  // Compare against latest known tag in static_context
  const knownLatest = await db.fetchOne(
    "SELECT value FROM static_context WHERE key = $1",
    [`model.latest.${family}`]
  );

  // If installed tag is older than 30 days, flag for manual review
  const oldest = installedTags.reduce((min, m) =>
    m.modified < min.modified ? m : min, installedTags[0]);

  if (oldest && (Date.now() - oldest.modified) > 30 * 24 * 60 * 60 * 1000) {
    // Send Telegram alert
    await telegram.send(
      `🔄 Model check: ${family} installed version is 30+ days old.\n` +
      `Current: ${oldest.name}\n` +
      `Check https://ollama.com/library/${family} for newer releases.\n` +
      `Run /model-eval to benchmark a new candidate.`
    );
  }
}
```

**Status:** Not yet built — add to Phase 2 deliverables.

### 2.3 New Model Candidates to Watch

| Model | Status | When relevant |
|---|---|---|
| **llama4:scout** | Available now on Ollama (~10GB, 4B active/17B total MoE) | **Hot tier candidate** — multimodal, fast, human-parity triage. Benchmark against qwen3:8b |
| Qwen3:30b-a3b | Available now (19GB, 3B active) | Buy 24GB GPU — 30B quality at 3B speed |
| Qwen3.6:35b-a3b | Available (12GB, ~3B active) | Medium tier candidate once GPU upgraded |
| DeepSeek V4 Pro | Cloud API only — too large for local | Cloud escalation candidate for heavy reasoning |
| DeepSeek V4 Flash | Cloud API (~$0.17/M tokens) | Aider coding tasks, not pipeline worker |
| Kimi K2.6 | Cloud only — 1T params, 8× H100s required | Not locally runnable ever |
| IBM Granite 3.3 | Available now (8B, 5GB) | Alternative hot tier for structured extraction |
| gemma4:e4b | Available now (4B effective, 5.5GB, multimodal) | Vision tasks — photo-to-event, chalkboard reading |
| gemma4:26b | Available (18GB at Q4) | Upgrade path when 24GB GPU arrives |

**llama4:scout — the MoE hot tier candidate:**

Llama 4 Scout is a 17B total / 4B active MoE model with native multimodal support
(text + images in a single prompt). Key advantage over qwen3:8b: image understanding
built in, enabling photo-to-event workflows without a separate vision service.

```bash
ollama pull llama4:scout  # ~10GB
# Add to model evaluator benchmark queue:
# Compare against qwen3:8b on: email classification, invoice extraction,
# JSON output quality, and an image extraction test (pub receipt photo)
# Deploy whichever wins on composite score
```

**Dynamic thinking escalation (add to static_context — Phase 2):**

Rather than fixed thinking mode per worker, escalate automatically when
confidence is low. Add to `model.thresholds` in static_context:

```sql
INSERT INTO static_context (key, value) VALUES
('model.thinking', '{
  "auto_escalate_below": 0.85,
  "think_workers": ["reconciliation_explainer", "invoice_extractor"],
  "no_think_workers": ["email_classifier", "nanny_classifier"],
  "escalate_to_thinking": true
}')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
```

n8n routing logic: if `ai_parsed.confidence_score < 0.85` on any worker,
re-run the same prompt with `/think` prepended to the system message.
This doubles inference time for that item but catches borderline extractions
before they reach the Action Queue as false positives.

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

---

## SECTION 4 — PENDING DECISIONS

Items that came up during build requiring a decision before proceeding.

| Item | Context | Decision needed |
|---|---|---|
| Ubuntu version | Actually 26.04 not 22.04 | ✓ Resolved — fixes documented in Section 1.2 |
| Vault image pinning | Must stay at 1.15.6 | ✓ Resolved — pinned in docker-compose.yml |
| Metabase database | Was pointing at app DB | ✓ Resolved — metabase_app DB created, V2 migration applied |
| start.sh | Manual env var exports each session | ✓ Resolved — start.sh built at /home_ai/start.sh |
| Docker image pinning | All services currently use :latest | Pin all services before Phase 2 (risk of future breakage) |
| NatWest Open Banking | Developer registration takes 1-2 weeks | Start registration now — needed for Phase 2 |
| ICRTouch PLU tracking | Per-flavour tracking not yet configured | Configure TouchOffice before Phase 2 build — required for Ice Cream Oracle + Menu Engineering |
| ~~Dext API key~~ | ~~Not yet registered~~ | ✓ Resolved 2026-05-08 — Dext has no public API. Pipeline 2 (Invoice) now uses pdfplumber/MarkItDown + Haiku as the *only* automated extraction path. Dext stays as Jo's manual review tool — compare outputs for first 60 days. |
| WhatsApp blacklist numbers | Blacklist framework built, numbers not populated | Add actual numbers to static_context before Phase 4 |
| Garmin credentials | Stored in Vault but not yet tested | Test Garmin service connectivity before Phase 2 |
| init_placeholder HMAC bug | static_context_change trigger uses fake signature | Fix in dedicated step — do not fix inline |
| HMAC signing key | secret/signing exists but trigger not using it | Fix with init_placeholder bug above |
| Step 9b gate verification | Implemented but 5-point gate not yet run | Run on next session before Step 10 |

---

## SECTION 5 — VERSION LOG

| Date | What changed |
|---|---|
| May 2026 | v1.0 created — initial build lessons from Milestone A (Vault setup). Model stack updated to Qwen3. Pre-flight checklist added. Known issues documented: CAP_SETFCAP, Docker permissions, Ubuntu version mismatch, YAML indentation, auto-compaction mid-write. |
| May 2026 (session 2) | Hard reboot recovery documented. Metabase architectural fix (dedicated metabase_app DB). Vault rekey + root token rotation after keys exposed in chat. start.sh built and documented. Model evaluator port corrected to 8008 (was 8080, conflict with Open WebUI). init_placeholder HMAC bug flagged as tech debt. Three new Vault secrets added: secret/redis, secret/grafana, secret/open-webui. Vault secrets state table added (Section 3.3). Pre-flight checklist updated to use start.sh. Pending decisions table updated with resolved items. |
| May 2026 (session 3) | Step 9b (Model Stack Evaluator) implemented but gate not yet verified. Files: services/model-evaluator/Dockerfile + main.py + requirements.txt. docker-compose.yml updated with model-evaluator on port 8008. Verification gate pending next reboot: ./start.sh → docker compose up -d --build model-evaluator → 5 curl/psql checks → bump AGENTS.md to Last completed step: 9b. |
| May 2026 (session 4) | SearXNG self-hosted search added (Section 3.5) — Phase 1/2 addition, powers Open WebUI web search and Phase 5 research pipeline. Multi-tool routing guide added (Section 3.6) — Claude Code for complex build, Aider+DeepSeek for targeted fixes, Open WebUI+Qwen3+SearXNG for web research. Google Colab integration added (Section 3.8) — LoRA fine-tuning with Unsloth (free T4, 7B models, export GGUF to Ollama) and heavy batch analytics with Prophet via n8n data air-gap. Storyblok headless CMS added (Section 3.9) — Phase 5 addition for Olde Malthouse public website: MCP integration for natural-language content updates, Ice Cream Oracle auto-sync to website flavour list, Storyblok Management API via n8n. |
| May 2026 (session 5) | Pre-flight upgraded to full Environmental Sensing Protocol (6 senses: OS, GPU, Tailscale, Vault, n8n logs, build state) with Claude Code opening prompt. Ghost Loop failure mode documented. Dead Man's Switch added (Section 3.1) — secondary monitor for P620 offline >48hrs. 90-day Vault rekey automation added (Section 3.1). llama4:scout added as hot tier candidate (Section 2.3) — MoE, multimodal, ~10GB. Dynamic thinking escalation added (Section 2.3) — auto /think when confidence <0.85. Docker image version pinning task added (Section 3.2). SearXNG Cornwall News use case added (Section 3.2). GM photo → gemma4:e4b → Storyblok vision workflow added (Section 3.9, Path B). Corrected: no gemma4:9b variant exists, use gemma4:e4b. Filtered: DeepSeek V4 Pro, Kimi K2.6, qwen3.6:35b-a3b are cloud/API-only or need 24GB GPU — not current local candidates. |
| May 2026 (session 6) | Disaster recovery section added (Section 3.11): backup-all.sh (weekly PostgreSQL + Vault + n8n export), bootstrap.sh (fresh Ubuntu 26.04 setup), restore.sh (full data restore from backup). Target: 2-3 hours active time to fully running system on new hardware, ~45 min manual re-auth. Corresponding Section 7.3 added to SPEC v5.2. |
| May 2026 (session 7) | Outcome-Native pipeline pattern integrated into SPEC v5.3 Section 6.2 (construction rules for all Milestone C pipelines). Local Dreaming Workflow added as Phase 2 deliverable (Workflow H, nightly 02:00). CI Auto-Fix GitHub Actions added as Phase 2 hardening. Stretch doc Section 3.12 added with distinction between Anthropic platform features vs local implementations. |

---

| May 2026 (v2.0) | Merged and restructured from v1.0 and v1.0.2. Fixed duplicate section 3.4 numbering. Added proper 3.9 AI/Model Layer section header. Renumbered all sections for consistency. Storyblok moved to 3.10. |

---

*This document is updated after every build session via the `/retro` slash command.*
*It is read at the START of every Claude Code session before AGENTS.md.*
*Never delete entries — mark them resolved with a ✓ prefix if fixed.*
