# U37 — Spec additions + document consolidation
## Paste-ready Claude Code prompt

This is the opening message for a new Claude Code session. It is **documentation
work and small spec authoring**, not pipeline building. ~3-4 hour session.

Decisions baked in:
- **5 new SPEC sections** added in Phase 2 area, renumbering 7.3/7.4 → 7.8/7.9.
- **Structured outputs (§7.3) is Phase 1 hardening** — do *before* the new Phase 2 pipelines.
- **Guest Review Assistant (§7.4) is PRIORITY** — second new section, highest user value.
- **VAT Return (§7.7) is dormant** — gated on `system.state.p3_xero='live'`. Schema + logic land but cron stays off until Xero unblocks.
- **Materialized Views = §3.19 STRETCH only**, no SPEC section yet (Phase 3+ optimisation).
- **Flood Risk is OUT** — Jo declined.

Total deliverables: 5 new SPEC sections + 2 renumbered + 6 STRETCH pointers + AGENTS.md rewrite + STATUS.md (new) + STRETCH.md trim + `/retro` update + entropy-scanned commit.

---

## STEP 1 — State sync (3 commands, not 6)

Per `feedback_working_discipline.md` Rule 6. Run these first; report results before any writing.

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | grep homeai- | wc -l
ls /home_ai/postgres/migrations/ | tail -3
docker exec homeai-postgres psql -U postgres -d homeai -c \
  "SELECT id, received_at, raw_subject FROM bot_instructions WHERE status='pending' ORDER BY received_at;"
```

Expect: ~25 containers running, latest migration V43, 0 pending bot_instructions.

---

## STEP 2 — Read sources

Read in this order (full files):

1. `/home/joly/.claude/projects/-home-joly/memory/MEMORY.md` — auto-memory index
2. `/home/joly/.claude/projects/-home-joly/memory/project_homeai.md` — current build state (canonical)
3. `/home_ai/AGENTS.md` — current rule set + state mix
4. `/home_ai/HOME-AI-STRETCH.md` — current stretch doc
5. `/home_ai/.claude/sprints/U36-phase2-push.md` — most recent sprint (for context on what just shipped)

Read structure-only (table of contents):

6. `/home_ai/SPEC.md` — only the section headers via `grep -nE "^#{1,3} " /home_ai/SPEC.md | head -80`

Confirm read completion in one line before proceeding.

---

## STEP 3 — Author SPEC.md sections

5 new sections + 2 renumbered. Plan Mode (Shift+Tab) between each section. Show me the proposed structure before writing each one — get approval before inserting.

### 3a. SPEC.md §7.3 — Structured outputs / JSON Schema constrained generation (NEW)

**Position**: insert as new §7.3, after current §7.2 ("Key Phase 2 Additions").

**Why before the new Phase 2 pipelines**: this is a reliability foundation. Done once, every subsequent AI worker is guaranteed to produce valid JSON. Doing it after Phase 2 means retrofitting the new pipelines.

**Section structure to author**:

- **Goal**: eliminate "parse JSON from AI response" Code nodes. Every AI worker produces guaranteed-valid JSON matching a versioned schema. Hallucinated field names → 0% by construction.
- **Why now**: Phase 1 retrofit. Without this, the guest-review, Companies-House, Land-Registry and VAT pipelines repeat the same fragile parse-JSON pattern we already have.
- **Components**:
  - `/home_ai/ai_schemas/` — new directory with one JSON Schema per worker (`email-classifier.schema.json`, `invoice-extract.schema.json`, etc).
  - Update n8n Code nodes that call Ollama: use `format: <schema>` parameter on `/api/generate` (Ollama supports JSON Schema constrained generation since v0.5).
  - Update Anthropic call sites (`bot-responder`, `u36-invoice-haiku-fallback`, `u36-dreaming-nightly`, `u36-reconciliation-explainer`) to use **tool use with input_schema** instead of system-prompt "return JSON" — the response is then guaranteed schema-valid.
  - Migration V44 adds a `schema_version` column to `audit_log` so we can track which workers are on which schema generation.
- **Acceptance**:
  - All 6 Ollama-using Code nodes use `format` parameter.
  - All 4 Anthropic call sites use tool-use with schemas.
  - Synthetic-email-suite passes 100 runs with 0 JSON parse errors.
  - `ai_schemas/` directory committed.
- **Sequencing**: do this BEFORE §7.4-§7.7. The new pipelines should be born on this pattern.
- **Code example**: paste the Ollama format-parameter pattern from the user's earlier message verbatim.

### 3b. SPEC.md §7.4 — Guest Review Response Assistant ★ PRIORITY (NEW)

**Position**: §7.4. PRIORITY among Phase 2 deliverables — start here.

**Section structure to author**:

- **Goal**: catch new Google + TripAdvisor reviews for the Malthouse (pub) and the Sandwich shop within 48 hours. Sonnet pre-drafts a context-aware response. Surfaced in the Action Queue. Jo approves/edits; posting stays manual.
- **Why**: hospitality review response time directly affects star averages, which affects bookings. Doing this with daily manual checking is unreliable; doing it autonomously without human approval is risky. The Action Queue pattern fits perfectly.
- **Architecture**:
  ```
  Weekly cron 09:00 Mon
    → Playwright scraper (extends competitor-watch pattern)
        → Google Business listings for both locations
        → TripAdvisor pages for both locations
      → new rows in guest_reviews
        → Sonnet drafter (cached system prompt, location-aware tone)
          → new row in review_drafts
            → Action Queue card type 'guest_review'
              → Jo approves/edits/rejects in dashboard
                → manual post (no auto-post for safety)
    → Telegram alert if any review ≤3 stars
  ```
- **Tables (V44 migration adds both)**:
  - `guest_reviews`: review_id (text), source ('google'|'tripadvisor'), location ('malthouse'|'sandwich'), rating int, body text, posted_at, scraped_at, raw_payload jsonb, status text. PK on (source, review_id).
  - `review_drafts`: id, review_id (FK), draft_text, sonnet_model, prompt_cache_hit bool, created_at, approved_by, approved_at, posted_at, rejected_at.
- **Sonnet drafter system prompt** (cached):
  - Hospitality tone: warm, specific, no apologetic-doormat.
  - Location-aware: pub responses differ from cafe responses.
  - Address specifics from the review (don't write generic "thank you").
  - For 1-3 star reviews: acknowledge the specific issue, offer a path forward (manager email, return visit), no defensiveness.
  - Never invent a manager name; use "the manager" or "Jo (owner)".
  - 80-150 words.
- **Action Queue integration**: new card type `guest_review` rendering review text on left, draft on right, [Approve] [Edit] [Reject] buttons. Editing opens an inline textarea. Approve marks draft `approved_at = now()`; rejection sets `rejected_at`.
- **Telegram alert**: any new review with rating ≤3 → immediate "⭐ <rating>★ review on <source> for <location>" alert.
- **Acceptance gates**:
  - Playwright scraper successfully fetches last 7 days of reviews from Google + TripAdvisor for both locations (manual run).
  - First draft generated for at least one new review; Sonnet output reads as appropriate hospitality tone (Jo's sanity check).
  - Action Queue card renders with approve/edit/reject.
  - Telegram alert fires on a synthetic 2-star test review.

### 3c. SPEC.md §7.5 — Companies House API integration (NEW)

**Position**: §7.5.

**Section structure**:

- **Goal**: track filing deadlines for Atlantic Road Trading Ltd (ARTL) and Atlantic Road Estates Limited (AREL); add on-demand company verification for any supplier/tenant.
- **Why**: late confirmation statement = £150 penalty; late accounts = £150 to £1500. The API is free, no auth needed. Building this catches ~£300/year of avoidable cost.
- **Endpoint** (no auth): `GET https://api.company-information.service.gov.uk/company/{company_number}`
- **One-time setup**: Jo provides ARTL and AREL company numbers. UPDATE `entities` SET `companies_house_number = '<num>'` for entity_id=1 and 2.
- **Components**:
  - Weekly cron Mon 04:00 (`u37-companies-house-sync.sh`): for each entity with `companies_house_number`, hit the API; insert snapshot row; compute `days_until` for both deadlines.
  - Daily digest section: "Filing deadlines in next 30 days" (auto-hidden if empty).
  - On-demand: bot-responder gets a `verify_company` tool slug. Jo emails the bot "verify company 12345678" → Sonnet replies with name, status, registered address.
- **Tables (V44 adds)**:
  - `companies_house_log`: id, snapshot_at, company_number, name, status, registered_address jsonb, accounts_next_due_date date, confirmation_statement_next_due_date date, raw_payload jsonb.
  - `companies_house_alerts`: id, entity_id, alert_type ('accounts_due'|'confirmation_due'), due_date, days_until, status ('open'|'acknowledged'|'filed'), created_at.
- **Alert rules**: insert into `companies_house_alerts` when `days_until <= 30` AND no open alert exists for that (entity, type, due_date) tuple.
- **Acceptance**:
  - `companies_house_log` rows for both companies after first weekly run.
  - Synthetic test: temporarily set ARTL's confirmation due date to today+25; alert row created; digest shows it.
  - bot-responder `verify_company` slug returns sane JSON for a real test company number.

### 3d. SPEC.md §7.6 — Land Registry Price Paid API (NEW)

**Position**: §7.6.

**Section structure**:

- **Goal**: monthly comparable-sales report for the 7 Atlantic Road Estates properties. Real market data, no manual Rightmove checking.
- **Why**: insurance renewal conversations, refinancing decisions, periodic valuation sanity checks. Free, no auth.
- **Endpoint**: `GET https://landregistry.data.gov.uk/app/ppd/ppd_data.csv?postcode={postcode}&from={date}` returns CSV of sales.
- **One-time setup**: Jo provides 7 property postcodes + acquisition prices + dates. Seed table `properties` (NEW — V44 migration).
- **Components**:
  - Monthly cron 1st 04:30 (`u37-land-registry-sync.sh`): for each property, fetch last 90 days of sales in that postcode; parse CSV; insert sale rows; compute average.
  - Daily digest (1st of month only): "Estates market — last 90d sales by postcode" with avg price, sample size, vs Jo's acquisition price.
- **Tables (V44 adds)**:
  - `properties`: id, entity_id (=2), postcode, address, acquisition_date, acquisition_price_gbp, notes.
  - `property_market_log`: id, property_id (FK), snapshot_at, sales jsonb (array of {date, price, address, type}), avg_price, sample_n.
  - `v_property_comparable_summary`: view joining properties to most recent market log, with delta vs acquisition.
- **Acceptance**:
  - `property_market_log` row per property after first monthly run.
  - View returns 7 rows, each with sensible avg_price.
  - Digest renders the section on a 1st-of-month synthetic test.

### 3e. SPEC.md §7.7 — VAT Return Preparation Workflow (NEW, DORMANT)

**Position**: §7.7. Built but cron stays disabled.

**Section structure**:

- **Goal**: quarterly, pre-fill UK VAT return Box 1-9 figures from Xero data; flag anomalies; surface in Action Queue. Jo still files manually through Xero — this just makes the figures pre-checked.
- **Why dormant**: depends on Pipeline 3 (Xero sync) which is parked on Xero support response. Build the schema + logic now; activate when Xero unblocks.
- **Gating**: cron exists but checks `SELECT value FROM system_state WHERE key='p3_xero'` — bails unless `'live'`.
- **Components**:
  - Quarterly cron 3rd Apr/Jul/Oct/Jan 06:00 (`u37-vat-return-prep.sh`): pull last quarter's Xero figures; structure into Box 1-9; run anomaly rules; insert row; queue Action Queue card.
  - Anomaly rules:
    - Box 4 (input VAT) > 2× rolling 4-quarter average → high
    - Any vendor_invoice_inbox row >£500 without matching bank_transaction → medium
    - (Net standard-rated sales) × 0.20 vs Box 1 difference > £20 → medium
- **Tables (V44 adds)**:
  - `vat_returns_log`: id, entity_id, quarter_end date, box_1_through_9 jsonb, anomalies jsonb, status ('draft'|'reviewed'|'filed'), created_at, accountant_reviewed_at, filed_at.
  - `system_state`: key text PK, value text, updated_at. Seed `('p3_xero','parked')`.
- **Action Queue card type**: `vat_review` rendering each box with figure + any flags on that box.
- **Acceptance**:
  - Schema applied.
  - Dormancy verified: manual run logs "p3_xero=parked, skipping" and inserts no rows.
  - When Xero unblocks, set `UPDATE system_state SET value='live' WHERE key='p3_xero'`; next run pulls real figures.

### 3f. Renumber existing sections

After authoring §7.3-§7.7:

- Move current `## 7.3 Disaster Recovery Scripts` → `## 7.8 Disaster Recovery Scripts`
- Move current `## 7.4 Phase 2 Testing Checklist` → `## 7.9 Phase 2 Testing Checklist` (update content to include the 5 new sections' acceptance gates)

Use search-replace for the section markers; preserve content verbatim.

---

## STEP 4 — Update HOME-AI-STRETCH.md

Add 6 new stretch entries (5-10 lines each, summary + SPEC pointer). Place them after the existing §3.13.

Each entry follows this template:

```markdown
### 3.NN <Title> [★ PRIORITY where applicable]

<2-3 sentence summary of what it does and why it matters>

<1-2 sentence on prerequisites or sequencing if non-obvious>

Full implementation: SPEC.md §7.<N>
```

The six entries (priority order, top to bottom):

- **§3.14 Guest Review Response Assistant ★ PRIORITY** → SPEC §7.4
- **§3.15 Structured outputs / JSON Schema constrained generation** (Phase 1 hardening — do before §3.14) → SPEC §7.3
- **§3.16 Companies House API integration** → SPEC §7.5
- **§3.17 Land Registry Price Paid API** → SPEC §7.6
- **§3.18 VAT Return Preparation** (dormant — needs P3 Xero unblock) → SPEC §7.7
- **§3.19 Materialized Views for dashboard performance** (no SPEC section yet — Phase 3+ optimisation) → "Implementation deferred; revisit when a specific dashboard endpoint feels slow. Candidates: `v_daily_unit_economics`, `v_daily_cost_vs_sales`, `v_daily_labour_by_team`."

---

## STEP 5 — AGENTS.md rewrite

Target: ~150 lines (current 497). Plan Mode first; show structure before writing.

**Must include (synthesised from memory + SPEC + current AGENTS.md)**:

- **System identity**: owner Jo, 4 entities (ARTL pub/restaurant/inn/ice-cream; AREL 7 properties; Personal; Family), JolyBox host on Tailscale, Ubuntu 26.04, ~25 docker containers.
- **Authoritative state source**: `/home/joly/.claude/projects/-home-joly/memory/` is the canonical state store; this AGENTS.md is the rule set; `STATUS.md` is the human mirror.
- **Architecture rules (non-negotiable)** — verbatim from existing AGENTS.md / memory, deduplicated:
  - NEVER `docker compose up` directly — always `./start.sh` (handles Vault unseal + secret injection)
  - NEVER write secrets to files — Vault only
  - ALWAYS `SET LOCAL app.current_entity` before Postgres writes (RLS)
  - ALWAYS use `body_text_safe` (sanitised) in AI prompts (prompt-injection guard)
  - ALWAYS sign event payloads (HMAC-SHA256) before INSERT to `events`
  - ALWAYS check idempotency_key before processing
  - Holiday entitlement: statutory pro-rata only, NEVER 12.07%
  - After `secret/postgres-roles` rotation: run `sync-n8n-postgres-credential.sh`
  - `events.idempotency_key` has NO unique constraint — use `WHERE NOT EXISTS`, NOT `ON CONFLICT`
  - JSONB columns into IF nodes: coerce in SQL with `->>`
  - n8n stores 2 copies of workflows: edit `workflow_history` (active versionId), not just `workflow_entity.nodes`
  - For third-party tools with own password hashing: use their API/CLI, never INSERT/UPDATE the user table
  - To start/recreate a single compose service without `start.sh`: harvest env vars from the running container, then `docker compose up -d <service>` — see `feedback_dashboard_image_rebuild.md`
  - Grafana `GF_SECURITY_ADMIN_PASSWORD` only applies on first init
  - Pre-push entropy scan before any `git push` (entropy-scan staged tree) — see `feedback_homeai_pre_push_scan.md`
- **Environment facts (real, not spec)**:
  - Ubuntu 26.04 Resolute Raccoon, kernel 7.0.x
  - Postgres 16.13 (was 15 in earlier spec; updated)
  - Vault hashicorp/vault:1.15.6 (STALE — flagged for update; needs in-person)
  - All images pinned (no `:latest`)
  - PreToolUse hooks installed at `~/.claude/settings.json`
  - selftest at `/home_ai/scripts/selftest.sh` — 51/52 expected (Gmail Ingest workflow pre-existing FAIL)
- **Model stack (CURRENT, verified 2026-05-13 from `model_inventory_log`)**:
  - Hot (T1): qwen2.5:7b — 4.36GB, email classification & routing (per `project_qwen_u7_optimisation`)
  - Medium (T2): phi4:14b — 8.43GB
  - Heavy (T3): NOT currently loaded (was llama3.3:70b in earlier spec — removed)
  - Cloud: claude-haiku-4-5 (escalation, invoice extraction); claude-sonnet-4-6 (reasoning, dreaming, reconciliation); claude-opus-4-7 (this session, high-stakes only)
- **Working discipline rules** — pointer to `feedback_working_discipline.md` (7 rules); do NOT inline them. Brief mention only.
- **Memory rules** — at session start, check `bot_instructions` pending; read `MEMORY.md` index.
- **Slash commands** — list of the most-used: `/simplify`, `/review`, `/retro`, `/ultrareview`, `/compact`, `/init`.
- **Session opening prompt** (verbatim):
  > "Read STATUS.md and AGENTS.md. We are on [phase/step]. Run state sync, then proceed."
- **Key paths** (one block):
  ```
  Spec:        /home_ai/SPEC.md
  Status:      /home_ai/STATUS.md
  Stretch:     /home_ai/HOME-AI-STRETCH.md
  Memory:      /home/joly/.claude/projects/-home-joly/memory/
  Sprints:     /home_ai/.claude/sprints/U*.md
  Migrations:  /home_ai/postgres/migrations/V*.sql
  Skills:      /home_ai/.claude/skills/
  Commands:    /home_ai/.claude/commands/
  ```
- **Gotchas section**: link to the 9 `feedback_*.md` memory files; do not inline their content. One-line summary each. The full content stays in memory and gets auto-loaded.

---

## STEP 6 — STATUS.md create

Target: ~80 lines. Plan Mode first.

**Header**: "STATUS.md is the human-readable mirror of `/home/joly/.claude/projects/-home-joly/memory/project_homeai.md`. The memory is canonical; this file is regenerated by `/retro`."

**Sections (lift from project_homeai.md)**:

- **Build State** — Phase, milestone, last completed sprint (U36), gate status
- **Running Services** — count + key services (~25 containers)
- **Vault Secrets Loaded** — bullet list (from memory)
- **Model Stack** — current tiers
- **Pending — Jo's input** — explicit list:
  - `bash /home_ai/scripts/u36-jo-input-batch.sh` (café vendors, statements, dept→team)
  - Dreaming proposal promotion (3 high-severity unparseable rules to accept/reject)
  - Investigate caterbook+EPOS 1365/96 unparseable surge
  - In-person: Vault auto-unseal bootstrap, 3 stale image updates, Authelia full forward_auth
  - External: Xero support reply (P3), Storyblok account, Garmin OAuth, GitHub repo for CI Auto-Fix
- **Pending — next build steps** — top 5 from latest sprint plan
- **Known Issues (unresolved)**:
  - n8n Dreaming workflow `QMKzaCFrKBS4ewWm` erroring 2 days running
  - 3 stale Docker images (Vault 1.15.6, alertmanager v0.27, postgres-exporter v0.15)
  - Authelia forward_auth deferred (needs tailscale cert)
  - Vault auto-unseal not yet bootstrapped (needs sudo + unseal keys)
- **Recently Completed (last 3 sprints)** — one line each: U34, U35, U36
- **Document Versions**: SPEC v5.2 → v5.3 (this session bumps it), STRETCH (existing), AGENTS (rewritten this session), STATUS (this file)

---

## STEP 7 — STRETCH.md trim

**REMOVE**:
- Section 1 (Pre-Flight + Known Issues + Environment Facts) → moved to AGENTS.md / memory
- Section 2 (Model Stack tiers + candidates) → moved to AGENTS.md
- Section 4 (Pending Decisions table) → moved to STATUS.md
- Section 5 (Version Log entries older than 6 months) → move into STATUS.md "Recently Completed"

**KEEP**:
- §3.1 through §3.13 untouched (all stretch goals)
- The 6 new §3.14-§3.19 entries from STEP 4
- The header rewritten: "This document contains future ideas only. Current state: STATUS.md. Session rules: AGENTS.md. Architectural reference: SPEC.md."

---

## STEP 8 — `/retro` slash command update

Update `/home_ai/.claude/commands/retro.md` to make STATUS.md update **mandatory**, alongside the existing memory + sprint-file update behaviour.

```markdown
---
name: retro
description: End-of-session retrospective — extract learnings and update STATUS.md, memory, and AGENTS.md
---

Answer: What did you learn during this session?

File each learning to the correct location:
1. Build failures/fixes → /home_ai/System/Assistant/logs/issues-fixes-log.md
2. Architectural decisions → /home_ai/.claude/decisions/YYYY-MM-DD-[topic].md
3. Claude failure modes / repeated mistakes → new `feedback_*.md` in /home/joly/.claude/projects/-home-joly/memory/
4. General project conventions → AGENTS.md main body

Then update STATUS.md (MANDATORY):
- Update "Last updated" date
- Update "Last completed step" / latest sprint reference
- Update "Recently Completed" with this session's work (one line)
- Update any "Pending — Jo's input" items resolved
- Update "Known Issues" if any were fixed or added

Then update the canonical memory at /home/joly/.claude/projects/-home-joly/memory/project_homeai.md:
- Build state line
- Migration list (if any new)
- Cron table (if any added)
- Next candidates section

Then update AGENTS.md:
- "Last completed step" reference

Report what was filed and where. Do not end the session without updating STATUS.md and project_homeai.md.
```

---

## STEP 9 — Cleanup old files

Delete (if present):
- `/home_ai/SPRINT-*.md`
- `/home_ai/CLAUDE-CODE-*.md`
- `/home_ai/HOME-AI-STRETCH-v*.md` (versioned copies)
- Other one-off prompt files at `/home_ai/` root

Sprint plans at `/home_ai/.claude/sprints/U*.md` stay — they're the authoritative sprint history.

---

## STEP 10 — Pre-push entropy scan + git commit + push

**MANDATORY ORDER** (per `feedback_homeai_pre_push_scan.md`):

1. `cd /home_ai`
2. `git status` — confirm what's staged
3. `git diff --staged` — eyeball the diff
4. **Entropy scan** on the staged tree:
   ```bash
   git diff --staged --name-only | xargs -I{} sh -c '
     if [ -f "{}" ]; then
       grep -EH "([a-f0-9]{32,}|hvs\.[a-zA-Z0-9]{20,}|sk-[a-zA-Z0-9-]{30,}|ghp_[a-zA-Z0-9]{30,}|argon2id)" "{}" || true
     fi
   '
   ```
   If any hits → STOP. Show me before doing anything else. Common false positives: AGENTS.md mentioning Vault paths, SPEC.md mentioning argon2id as a hashing scheme. Real positives: any actual hex secret in a config or script.
5. **CONFIRM with Jo before commit** — show me the commit summary. Get explicit "go".
6. `git commit -m "U37: spec additions (guest reviews, Companies House, Land Registry, VAT, structured outputs) + doc consolidation"`
7. **CONFIRM with Jo before push** — `git push origin main` is irreversible.
8. `git push origin main`

---

## COMPLETION CRITERIA

- [ ] SPEC.md §7.3-§7.7 authored, §7.3/§7.4 renumbered to §7.8/§7.9
- [ ] STRETCH.md §3.14-§3.19 added (with §3.14 marked PRIORITY, §3.15 marked Phase 1 hardening)
- [ ] AGENTS.md rewritten <200 lines, points at auto-memory as canonical
- [ ] STATUS.md created ~80 lines, mirrors memory
- [ ] STRETCH.md trimmed (Section 1, 2, 4, old 5 removed)
- [ ] `/retro` command updated with mandatory STATUS.md + memory update
- [ ] Old sprint prompt files at `/home_ai/` root deleted (sprints in `.claude/sprints/` retained)
- [ ] Entropy scan run; no secrets staged
- [ ] Committed and pushed
- [ ] Updated `project_homeai.md` memory with U37 wrap

---

## ANTI-SCOPE

- **No pipeline building.** This is documentation + small spec authoring only.
- **No JSON Schema implementation.** §7.3 is the SPEC text; actual Code-node updates are a follow-up sprint.
- **No Playwright scraper.** §7.4 is the SPEC text; scraper is a follow-up.
- **No new tables created in this session.** The V44 migration is spec'd, not applied. Created in the next sprint.
- **No new cron jobs.** Same reason.
- **No Authelia / Vault auto-unseal work** — needs in-person sudo.
- **No image updates** — defer to in-person sprint.

---

## FINAL NOTE

After this session, the opening prompt for every future Claude Code session in /home_ai is:

> "Read STATUS.md and AGENTS.md. Run state sync (3 commands). We are on [phase/step]. Proceed."

`MEMORY.md` (auto-memory) is loaded automatically by the harness. STRETCH.md is read only when explicitly needed for future-idea questions. SPEC.md is the architectural reference — section-by-section, never end-to-end.
