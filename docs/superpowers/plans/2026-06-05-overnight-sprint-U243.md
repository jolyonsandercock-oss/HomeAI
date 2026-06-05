# U243 — Overnight Sprint (unattended)

**Run after** `bash /home_ai/scripts/overnight-preflight.sh` (gathers config + does the
you-present actions). The unattended executor reads **`/home_ai/.claude/overnight-config.json`**
for `sprints`, `backfill_budget_usd`, `backfill_batch`, `category_map`.

## Global guardrails (HARD — apply to every sprint)
- **Additive / reversible only.** No pipeline activation, no n8n workflow surgery, no
  RLS/role changes, no touching the live email/event flow. If a step would, **skip and log**.
- **Owner realm only** for any `/api/memory/*` call (`-H 'X-Realm: owner'`).
- **Verify before done** — each sprint has an acceptance check; run it before committing.
- **Commit per sprint** (`git -C /home_ai`), message `U243 SN: <what>` + the Opus 4.8 trailer.
- **Stop-on-unrecovered-error per sprint, not globally:** if a sprint hits an error it can't
  resolve in 2 tries, revert that sprint's partial work, log it in `audit_log`
  (`action='u243_sprint_skipped'`), and move to the next sprint. Never leave the system in a
  worse state than you found it.
- **Watch the pipeline health each loop:** if `system.state` shows `paused_at`, or
  `dead_letter` grows > 20 in 5 min, **pause the current sprint and restore** (clear pause,
  resolve DLs) before continuing — the overnight run must not let a flood persist.
- Execute sprints in the order listed; only those present in `config.sprints`.

---

## S1 — Cultural-memory dossier backfill ⭐
**Goal:** distil the remaining eager counterparties (≈862) into `counterparty_dossier` so
`/app/memory` is populated by morning. The worker + endpoint already exist (built U242).

**Safe because:** it only exercises reviewed, additive code (`POST /api/memory/distill-batch`);
financials are DB-derived; owner-realm; no live-flow impact.

**Steps (loop):**
1. Read `backfill_budget_usd` and `backfill_batch` from config. Estimate cost ≈ `$0.01 ×
   dossiers_done_this_run`; track via `ai_usage` if available, else the running count.
2. Loop until **no eager candidates remain** OR **budget reached**:
   - `curl -s -X POST -H 'X-Realm: owner' "http://100.104.82.53:8090/api/memory/distill-batch?limit=$batch"`
   - Parse `{"distilled":N,"errors":[...]}`. If `N==0` two loops running → done.
   - If `errors` length > half of batch → STOP S1, log, move on (something's wrong with the model path).
   - Between loops, sleep ~30s (don't hammer Anthropic / respect the £3-day shadow cap).
3. **Acceptance:** `select count(*) from counterparty_dossier` rose substantially (target ≈865);
   `select count(*) from counterparty_dossier d join counterparties c on c.id=d.counterparty_id
   where d.financials->>'total_invoiced' is distinct from (home_ai.counterparty_financials(d.counterparty_id)->>'total_invoiced')` = 0 (financials still DB-true); no new dead_letters; not paused.
4. No commit needed (data only); log a summary to `audit_log` (`action='u243_s1_backfill'`,
   `ai_parsed` = {distilled, errors, est_cost_usd}).

## S2 — Observability hardening
**Goal:** fix the silently-broken `audit_log` inserts so self-repairs/cron actions are actually recorded.

**Safe because:** small SQL/script edits + a test; no runtime-path change.

**Steps:**
1. `audit_log` has NO `source`/`payload` columns (real: `pipeline`,`action`,`record_type`,
   `result`,`ai_parsed`,`created_at`). Find every `INSERT INTO audit_log(...source...payload...)`:
   `grep -rn "audit_log(action,source,payload\|audit_log(.*source.*payload" /home_ai/scripts`.
   Confirmed offenders: `scripts/homeai-cron-guard.sh`, and the `audit()` helper in
   `scripts/u241-supervisor.sh` (verify). Rewrite each to real columns, e.g.
   `INSERT INTO audit_log(pipeline,action,ai_parsed) VALUES('cron-guard','self_repair', jsonb_build_object(...))`.
2. **Test:** run each touched script in a dry/no-op way (or trigger its audit branch) and confirm
   a row lands: `select count(*) from audit_log where pipeline in ('cron-guard') and created_at>now()-interval '5 min'`.
3. **Acceptance:** edited scripts `bash -n` clean; a manual audit insert via each path appears in `audit_log`.
4. **Commit:** `U243 S2: fix audit_log inserts (real columns) in cron-guard + supervisor`.

## S3 — Invoice P2: DWD design spec (RESEARCH ONLY — no build, no activation)
**Goal:** specify the account-aware attachment fetch so P2 can later handle Workspace inboxes
(`info`/`admin`, DWD) as well as consumer accounts (OAuth). Context:
`.claude/decisions/2026-06-05-invoice-pipeline-p2-diagnosis.md`.

**Safe because:** read-only investigation + a written spec. **Do not modify P2, n8n, or activate anything.**

**Steps:**
1. Read how `services/google-fetch/main.py` fetches Gmail for each account (OAuth vs DWD /
   `sa-malthouse`); see `feedback_google_identity_auth_split`. Identify whether google-fetch
   already exposes (or could cheaply expose) an "fetch attachment by gmail_message_id + account"
   endpoint that hides the auth mode.
2. Compare to P2's current fetch chain (`Vault: Gmail Creds → OAuth refresh → Gmail: Fetch
   Attachment`). Decide: (A) add account-aware branch in P2 (DWD for info/admin), or
   (B) replace P2's fetch nodes with a single call to a google-fetch attachment endpoint.
3. Write `docs/superpowers/specs/2026-06-05-invoice-p2-dwd-attachment-fetch.md`: chosen approach,
   exact node/endpoint changes, the V224 claim re-admit + reactivation steps, test plan, cost.
4. **Acceptance:** spec file exists, is placeholder-free, names concrete files/nodes.
5. **Commit:** `U243 S3: invoice-P2 DWD attachment-fetch design spec`.

## S4 — Invoice canonical-category mapping  *(only if in config.sprints)*
**Goal:** map the AI extractor's vocab to a single canonical set so invoices categorise consistently
(addresses the ~9,000 NULL `category_canonical`). Uses `config.category_map`.

**Safe because:** additive function + read-only view; no pipeline dependency.

**Steps:**
1. Migration `V233__canonical_category_map.sql` (confirm next free V-number first): create
   `home_ai.canonical_category(p text) RETURNS text` that maps via the `category_map` from config
   (embed the pairs as a CASE), and a view `v_invoice_categorised` exposing
   `coalesce(home_ai.canonical_category(category_canonical), 'Uncategorised')`. Do NOT mutate
   `vendor_invoice_inbox` rows.
2. **Acceptance:** `select home_ai.canonical_category('wet_purchase')` = 'Beverage', etc. for
   every key in `category_map`; the view returns rows.
3. **Commit:** `U243 S4: canonical category mapping (home_ai.canonical_category + view)`.

---

## Morning report (the executor writes this last)
Append to `audit_log` and print: per-sprint status (done/skipped + why), S1 dossiers distilled +
est. cost, list of commits, and any guardrail trips (pauses/floods handled). Leave the email
pipeline verified-healthy (`email.received` processing, not paused).
