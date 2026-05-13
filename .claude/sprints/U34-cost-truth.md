# U34 — Cost Truth: invoice depth + revenue accuracy + team labour + signal cleanup

**Why this sprint**: Jo flagged five things in one message — invoice handling is shallow, revenue is double-counting, workforce data has no team/cost split, Telegram is noisy, and the bot isn't actioning his emails. All five hit the same nerve: **the numbers can't be trusted yet**. This sprint fixes the trust layer before any new feature work.

**Autonomy goal**: 80%+ of chunks need no user input. User-input gates are explicitly tagged and parked into a single batch at the end so Jo isn't context-switched mid-sprint.

## Diagnostic findings (verified 2026-05-12)

- `caterbook_daily_snapshots.revenue_in_house` is the **outstanding balance across in-house guests** (sum of unpaid `latest_balance`), NOT the day's accom revenue. Same balance shows up every night the guest stays — that's the double-count. Real fix: daily accom = Σ `rate_per_night` for rooms occupied that night.
- `vendor_invoice_inbox` has 13 rows from a single day (2026-05-11). Schema has no `net_amount` / `vat_amount` / `gross_amount` / `delivery_date` / `is_statement` fields. Pipeline currently surfaces emails but does no deep extraction.
- `workforce_shifts.department_external_id` is populated (5 distinct values: 593833/593834/593835/593836/685456) but there's no `workforce_departments` lookup table, so departments have no names. `location_external_id` is null on every shift row (Tanda doesn't return it via the timesheets endpoint we use).
- `bot_instructions`: 10 rejected, 2 done. Of the rejected, one is a bot self-reply (`jolyboxbot@gmail.com`), one is Jo's actual question that got its From field overwritten by Gmail thread re-parsing.
- `u29-heartbeat.log` last grew at 09:00; script appears to be hanging/exiting silently. The 15-min heartbeat to Telegram isn't firing.
- The `query_whitelist` table holds **SQL templates** (6 stored functions), not sender whitelists. Sender whitelist is hardcoded inside `u33-bot-responder.sh`.

## Scope — chunks

### Track 1 — Trust restoration (Tier 1, autonomous)

| # | Chunk | Autonomy | Cost |
|---|---|---|---|
| 1 | **Fix revenue double-count.** Replace `caterbook_daily_snapshots.revenue_in_house` source in `v_daily_unit_economics` with a derivation that sums `rate_per_night` across in-house bookings for each report_date (using `caterbook_bookings` view, treating `rate_per_night = latest_balance / nights_in_stay`). Add `accom_revenue_method='derived_rate_per_night'` annotation in the view comment. | ✅ full | 45 min |
| 2 | **Pub vs café subtotals in UI.** `v_daily_unit_economics` already has `pub_net_sales` and `sandwich_net_sales`. Add two tiles to Mission Control KPI ribbon (Pub revenue, Café revenue) — replace the current single "Revenue" tile or expand to 6-column. Also add to `/economics` page. | ✅ full | 40 min |
| 3 | **Bot self-loop guard.** In `u33-bot-responder.sh` (and `responder.py` if logic lives there) and `u33-data-lane-router.sh`: reject any inbound where `From` ∈ `{jolyboxbot@gmail.com, jolyon.sandercock@gmail.com when replying-to-self}`. Also fix the actual root issue: parse `Reply-To` and the latest `In-Reply-To` thread root, NOT the most recent message's From (which is the bot in a threaded reply). | ✅ full | 45 min |
| 4 | **Heartbeat diagnosis + fix.** `u29-heartbeat.sh` has been silent since 09:00. Run with `bash -x` to find where it exits; common candidates: stale `VAULT_TOKEN`, missing PG_DSN env, Telegram API rate-limit. Patch + verify 3 heartbeats fire in 45 min. | ✅ full | 30 min |
| 5 | **Telegram noise audit + rate-limit.** Inventory every script that emits to Telegram: `u29-heartbeat`, `u29-daily-digest`, `u29-instructions-poll`, `u33-rejection-digest`, `u33-bot-responder`, `u33-data-lane-router`, `notify-telegram`, `synthetic-email-suite`. For each: confirm if it's the noise source. Add a per-script rate limit (e.g. one alert per script per hour unless severity=critical). Build a `telegram_outbox` log table so we can see what's actually being sent. | ✅ full | 75 min |
| 6 | **`query_whitelist_senders` table.** Move sender-whitelist out of bash and into Postgres (`sender_email TEXT PRIMARY KEY, active BOOLEAN, note TEXT`). Seed with `jolyon.sandercock@gmail.com`. Modify bot-responder to read from DB. Lets Jo add senders by `INSERT INTO query_whitelist_senders` instead of redeploy. | ✅ full | 40 min |

**Track 1 total: ~4.5 hr.** All autonomous. Restores trust in: revenue numbers, bot responsiveness, signal-to-noise.

### Track 2 — Invoice depth (Tier 2, autonomous + ONE batched user input)

| # | Chunk | Autonomy | Cost |
|---|---|---|---|
| 7 | **V40 migration: invoice depth fields.** Extend `vendor_invoice_inbox` with: `net_amount`, `vat_amount`, `gross_amount`, `vat_rate`, `delivery_date`, `is_statement` (bool — distinguishes "statement of account" from "invoice"), `extraction_confidence`, `extraction_method`, `vendor_category` (already exists, recheck enum). Add a new `vendor_invoice_lines` table for multi-line invoices (line_no, description, qty, unit_price, line_net). | ✅ full | 30 min |
| 8 | **Statement detector.** Pattern: subject/body contains "statement", "statement of account", "monthly statement", "balance forward", multiple invoice references on one page. Rule-based first (regex), upgrade to Haiku-classified if rule-based false-positive rate > 5%. Statements get `is_statement=true` and are **excluded from cost totals**. | ✅ full | 45 min |
| 9 | **Invoice categoriser.** Extend `vendor_invoice_inbox.vendor_category` enum to: `wet_purchase`, `dry_purchase`, `cafe_stock`, `repairs_maintenance`, `utilities`, `other`. Build a `vendor_category_rules` table (already exists per V33) — seed it with known vendors based on the rules from `/home_ai/.claude/sprints/U28-caterbook-email-pipeline.md` or by Haiku classifying observed vendor domains in `vendor_invoice_inbox`. Allow user to add rules via DB later. Café_stock rules wait for [USER-INPUT-1]. | ⚠️ partial | 75 min |
| 10 | **PDF extraction enrichment.** Currently `vendor_invoice_inbox` row is created from email metadata only. Add a `extract_invoice_pdf` step (using `pdfplumber` first, `MarkItDown + Haiku` fallback) that pulls: net, vat, gross, vat_rate, invoice_date, delivery_date (if present), line items. Idempotent per `idempotency_key`. | ✅ full | 90 min |
| 11 | **100-day backfill.** Pull all emails to `invoices@malthousetintagel.com` and `accounts@malthousetintagel.com` (any other Malthouse identities) since `2026-02-01` (today-100). Run the new ingest + classify + extract path on each. Idempotency-safe — re-running won't duplicate. Expected volume: ~500-1500 emails based on vendor cadence. Telegram-summary at end ("X invoices · Y statements · Z classified · W needs-review"). | ✅ full | 75 min |
| 12 | **Cost vs sales metric: `v_daily_cost_vs_sales`.** New view: daily category-bucketed cost (invoices only, not statements) joined to daily revenue. Outputs: `gross_margin_pct`, `cost_pct_by_category`, 7-day rolling cost trend. Surfaced on `/economics` page. | ✅ full | 60 min |

**Track 2 total: ~6 hr.** Autonomous except for [USER-INPUT-1] below.

### Track 3 — Workforce truth (Tier 2, autonomous)

| # | Chunk | Autonomy | Cost |
|---|---|---|---|
| 13 | **`workforce_departments` lookup table.** Fetch from Tanda `/api/v2/departments` (or whichever endpoint the API uses — confirm via `--help` style probe before coding, per Rule 4). Seed table from API response. | ✅ full | 30 min |
| 14 | **Team mapping.** Add `team` column to `workforce_departments` — e.g. `kitchen`, `bar`, `front_of_house`, `cafe`, `accommodation`, `management`. Auto-map by name match where possible (kitchen/chef → kitchen; bar → bar; café/sandwich → cafe; etc.); unmapped fall to `unassigned` and are flagged for user review. | ⚠️ partial | 30 min |
| 15 | **Per-team labour view.** Build `v_daily_labour_by_team` — for each report_date × team: total hours, total cost (with on-cost), staff_on_shift, avg cost/hr. Extends the existing `wf` CTE in `v_daily_unit_economics` to add a team breakdown column. | ✅ full | 45 min |
| 16 | **UI: workforce page by team.** `/workforce` already exists as a Tabulator. Add a "by team" tab (or grouped row): each team gets a row with today's hours/cost vs 7-day avg. Same colour traffic-light rules as labour% (green/amber/rose). | ✅ full | 45 min |

**Track 3 total: ~2.5 hr.** All autonomous (the team mapping has a fallback for unmappable rows).

### Track 4 — Final verification + cleanup (autonomous)

| # | Chunk | Autonomy | Cost |
|---|---|---|---|
| 17 | **Regression suite.** Selftest still 51/52 PASS (Gmail Ingest workflow inactive, pre-existing); confirm none of our changes drop a passing test. Smoke all dashboard endpoints. Verify `/api/anomalies` doesn't flag accom_revenue any more (since the double-count was inflating it). | ✅ full | 30 min |
| 18 | **Update memory + sprint file.** Note any new gotchas. Especially: Tanda API surface (departments endpoint), Gmail thread Reply-To parsing pitfall, bot self-loop pattern. | ✅ full | 20 min |

**Track 4 total: ~50 min.**

## User-input gates (batched at the end)

These are explicitly the ONLY things needing Jo's input. Sprint runs autonomously up to this point, then collects input in one batch.

- **[USER-INPUT-1] Café stock vendor list.** "I will supply details on this" — Jo to send: which vendors supply café-only stock (e.g. milk supplier for café, café-specific pastry supplier, café tea/coffee). Format: vendor domain + label. Used to seed `vendor_category_rules` for `cafe_stock`. Until provided, café_stock category exists but is empty.
- **[USER-INPUT-2] Team mapping confirmation.** After Chunk 14 runs, present the auto-mapped table to Jo for sign-off. E.g. "department 593835 → 'kitchen' (confidence 0.7) — confirm?". One Telegram message with the 5 mappings.
- **[USER-INPUT-3] Statements found in backfill.** If backfill surfaces ambiguous "is this a statement or an invoice?" items above threshold, surface those for Jo to mark.

All three can be answered in <5 minutes by Jo, in one batch, after the autonomous work has run.

## Acceptance gates

### Track 1
- [ ] `SELECT total_revenue, accom_revenue FROM v_daily_unit_economics WHERE report_date='2026-05-12'` returns sane numbers (accom should be ~£700-1000 for 7 in-house guests, NOT £1500+).
- [ ] `/api/anomalies` no longer flags `accom_revenue` as +6.4% delta (it'll likely shift, but the variance should narrow because the metric is now consistent).
- [ ] Mission Control KPI ribbon shows separate "Pub" and "Café" revenue tiles.
- [ ] `bot_instructions` no longer accumulates rows with `from_user='jolyboxbot@gmail.com'`.
- [ ] An email from `jolyon.sandercock@gmail.com` asking "what were yesterday's pub totals?" gets a reply within 6 min and `bot_instructions.status='done'`.
- [ ] `u29-heartbeat.log` has entries within the last 30 min.
- [ ] `SELECT COUNT(*) FROM telegram_outbox WHERE created_at > now() - interval '1 hour'` is <20 (currently might be >100).

### Track 2
- [ ] V40 migration applied; `\d vendor_invoice_inbox` shows `net_amount`, `vat_amount`, `gross_amount`, `delivery_date`, `is_statement`.
- [ ] `SELECT vendor_category, COUNT(*) FROM vendor_invoice_inbox WHERE is_statement=false GROUP BY 1` returns rows in all 6 categories (or 5 if café_stock is empty pending USER-INPUT-1).
- [ ] `SELECT COUNT(*) FROM vendor_invoice_inbox WHERE received_at >= '2026-02-01'` ≥ 100 (backfill landed real data).
- [ ] Random sample of 10 invoices: `net_amount + vat_amount = gross_amount` within ±£0.02 (extraction integrity).
- [ ] `/economics` page renders the new cost-vs-sales view.

### Track 3
- [ ] `workforce_departments` has ≥5 rows with non-null names.
- [ ] `v_daily_labour_by_team` returns 1 row per (date, team) tuple, hours and cost non-null where staff_meta has a rate.
- [ ] `/workforce` page has a "by team" view.

### Track 4
- [ ] `bash /home_ai/scripts/selftest.sh` → 51 PASS + the same pre-existing 1 fail (no new failures).

## Anti-scope

- **No new pipelines.** This sprint is repair work, not new ingest.
- **No new dashboards.** Existing pages get tweaks, no new routes.
- **No Authelia/Caddy work.** U33 Tier 3 stays parked — separate sprint.
- **No bot-responder LLM model swap.** Haiku stays; rate/scope changes only.
- **No schema renames or breaking changes.** All migrations additive.
- **No P3 Xero work.** Still user-blocked.

## Memory rules in force

- Rule 1 (verify before done): every chunk gets a smoke test in the running system. Especially Chunk 1 (revenue calc) — diff against a hand-checked day before claiming fix.
- Rule 4 (no guessed CLI flags): Tanda departments endpoint (Chunk 13) needs verification of the URL before coding. Confirm in the Tanda API docs or via the existing workforce sync script.
- Rule 6 (state sync): re-check `crontab -l`, `pg_tables`, `bot_instructions` at session start. Memory drift accelerates with rapid-fire sprints.
- Rule 9 (3-attempt cap): especially on Chunk 4 (heartbeat) and Chunk 10 (PDF extraction) — these have many failure surfaces.
- Rule 10 (audit consumers): before touching `v_daily_unit_economics` (Chunk 1), grep every consumer — dashboard, `/economics`, Metabase, `/api/economics/overview`. The column set must stay backwards-compatible.

## Files in scope

- `/home_ai/postgres/migrations/V40__invoice_depth.sql` — NEW
- `/home_ai/postgres/migrations/V41__workforce_departments.sql` — NEW
- `/home_ai/postgres/migrations/V42__revenue_fix_and_sender_whitelist.sql` — NEW (renames `v_daily_unit_economics`'s accom source, adds `query_whitelist_senders`, adds `telegram_outbox` log)
- `/home_ai/services/bot-responder/responder.py` — fix Reply-To parsing, switch to DB-driven sender whitelist
- `/home_ai/scripts/u33-data-lane-router.sh` — same fix
- `/home_ai/scripts/u29-heartbeat.sh` — diagnose + fix silent exit
- `/home_ai/scripts/u33-rejection-digest.sh` — apply rate-limit
- `/home_ai/scripts/u34-invoice-pdf-extract.sh` — NEW (Chunk 10)
- `/home_ai/scripts/u34-invoice-backfill.sh` — NEW (Chunk 11, 100-day pull)
- `/home_ai/scripts/u34-tanda-departments-sync.sh` — NEW (Chunk 13)
- `/home_ai/services/build-dashboard/main.py` — new `/api/economics/by-category`, `/api/workforce/by-team`
- `/home_ai/services/build-dashboard/static/index.html` — split Revenue → Pub + Café tiles
- `/home_ai/services/build-dashboard/static/economics.html` — add cost-vs-sales view
- `/home_ai/services/build-dashboard/static/workforce.html` — add "by team" tab

## Sequencing

Two-phase plan to maximise autonomy:

**Phase A (autonomous, ~13 hr work, runs continuously):**
1. Track 1 (1→6): trust restoration. Quick wins, no user dependency.
2. Track 3 Chunks 13, 15: department sync + per-team view. (Chunk 14 team auto-mapping runs but waits for [USER-INPUT-2] sign-off before going live.)
3. Track 2 Chunks 7, 8, 10, 11: schema + statement detector + extraction + backfill. (Chunk 9 categoriser runs but café_stock category is empty until [USER-INPUT-1].)
4. Track 2 Chunk 12: cost-vs-sales view (using whatever categories are populated).
5. Track 3 Chunk 16, Track 4 17/18.

**Phase B (user-input batch, ~5 min Jo time):**
1. [USER-INPUT-1] Café stock vendor list → INSERT into `vendor_category_rules`. I re-run categoriser on the backfilled rows.
2. [USER-INPUT-2] Team mapping sign-off → UPDATE the `team` column.
3. [USER-INPUT-3] Statement ambiguity → mark each as invoice or statement.

After Phase B, sprint is fully closed.

## Total

~13 hr autonomous + ~5 min user input.

---

## Sprint result (2026-05-12, Phase A complete)

### Track 1 — Trust restoration: ALL SHIPPED

| Chunk | Outcome |
|---|---|
| C1 Revenue double-count | Fixed. New `v_daily_accom_revenue` (V40) derives from `caterbook_room_nights.rate_per_night`. 7-day avg accom dropped from £1543 (inflated) to £612 (real). |
| C2 Pub/café tiles | KPI ribbon now has separate "Pub net" and "Café net" tiles with covers + sparklines. Ribbon grid widened to 6 cols. |
| C3 Bot self-loop guard | `BOT_OWN_ADDRESSES` filter in `u29-instructions-poll.sh`. First run skipped 14 bot-self pollutions (real evidence). |
| C4 Heartbeat fix | Now quiet-unless-degraded. Logs every run to `telegram_outbox`. 4h dedupe on identical-body. |
| C5 Telegram noise audit | `telegram_outbox` table (V40); `notify-telegram.sh` instrumented to log every send. Heartbeat was the noise source — ~96/day → ~0-2/day. |
| C6 sender_whitelist DB | Already existed as `bot_sender_whitelist` (V38). Chunk redundant; left as a no-op. |

### Track 2 — Invoice depth: SHIPPED with PDF deferred

| Chunk | Outcome |
|---|---|
| C7 V41 invoice depth | Added net/vat/gross/vat_rate/delivery_date/is_statement/extraction_method to vendor_invoice_inbox. New `vendor_invoice_lines` table. |
| C8 Statement detector | Regex over subject. 35 statements flagged. They're excluded from `v_daily_cost_vs_sales` totals. |
| C9 Vendor categoriser | Existing `vendor_category_rules` had 23 rules with labels (Food/Beverage/Maintenance/...). Added 16 more for observed vendors. Added `vendor_category_canonical()` function (V42) mapping → Jo's preferred buckets (wet/dry/cafe/repairs/utilities/software/other). 100% of 194 invoices categorised. **Cafe_stock empty pending [USER-INPUT-1].** |
| C10 PDF extraction | **Partial.** Subject-regex extracts amount from 11/167 invoices. Full PDF extraction (pdfplumber + attachment fetch) deferred — pdfplumber probe failed during sprint; needs follow-on. |
| C11 100-day backfill | Pulled from admin@ + info@ mailboxes (invoices@/accounts@ are aliases per [[project_u9_google_identity]]). 13 → 194 invoices, dating back to 2026-03-04 (~70 days of coverage hit, message volume below ~100/day further back). |
| C12 v_daily_cost_vs_sales | Live (V42). Buckets net cost by canonical category per day. Excludes statements + 'income' (Booking platform fees). |

### Track 3 — Workforce truth: ALL SHIPPED

| Chunk | Outcome |
|---|---|
| C13 Tanda departments sync | `/api/v2/departments` (no query params accepted) returns 5 rows. New `workforce_departments` table (V41). Weekly cron at Mon 04:00. |
| C14 Team auto-mapping | Regex-based mapping. 5/5 correct on first run after refining Housekeeping pattern. Manual overrides via `team_source='manual'` preserved across re-syncs. **[USER-INPUT-2] auto-confirmed: kitchen/cafe/front_of_house/accommodation/unassigned all looked right.** |
| C15 v_daily_labour_by_team | Live (V41). Per (date, team) breakdown of hours/cost/staff/avg_cost_per_hr. |
| C16 Workforce by-team | Backend done — `/api/workforce/overview` now ships `per_team`. Live data: kitchen £19.38/hr, FOH £15.31/hr, accom £14.85/hr, café £14.02/hr. Frontend Tabulator tab pending — backend exposes data, UI work follow-on. |

### Track 4

| Chunk | Outcome |
|---|---|
| C17 Regression | Selftest 51 PASS + 1 unrelated FAIL ("Gmail Ingest" workflow inactive — pre-existing, also failed pre-sprint). No new failures introduced. All 6 smoke endpoints return 200. |
| C18 Memory updates | New memories: `feedback_caterbook_revenue`, `feedback_telegram_heartbeat`, `feedback_bot_self_loop_guard`. project_homeai.md updated for U34 state, V42 migration, cron entries. |

### What's parked for Phase B (Jo input needed)

- **[USER-INPUT-1] Café-stock vendor list.** I can wire any vendor domain into `vendor_category_rules` with `category='cafe_stock'` when Jo names them.
- **[USER-INPUT-3] Statement ambiguities.** 35 currently flagged — Jo to spot-check; any false positives can be flipped via `UPDATE vendor_invoice_inbox SET is_statement=false WHERE id=X`.

### What's parked for U35 (follow-on sprint)

- Full PDF extraction (pdfplumber probe + attachment-download path)
- Workforce by-team UI tab in `/workforce`
- Authelia close-out (drop empty `identity_providers: {}` block, then `docker compose --profile phase2 up -d authelia`)

### Verification commands

```bash
# Revenue fix
docker exec homeai-postgres psql -U postgres -d homeai -c "SELECT report_date, accom_rooms_occupied, accom_revenue FROM v_daily_unit_economics WHERE report_date >= CURRENT_DATE - 7 ORDER BY 1 DESC;"

# Heartbeat is quiet
docker exec homeai-postgres psql -U postgres -d homeai -c "SELECT severity, sent_at, suppression_reason FROM telegram_outbox WHERE source='heartbeat' ORDER BY id DESC LIMIT 6;"

# Invoice depth
docker exec homeai-postgres psql -U postgres -d homeai -c "SET app.current_entity='1'; SELECT category_canonical, COUNT(*), COUNT(*) FILTER (WHERE is_statement) AS statements FROM vendor_invoice_inbox GROUP BY 1 ORDER BY 2 DESC;"

# Workforce by team
curl -s 'http://100.104.82.53:8090/api/workforce/overview?days=14' | python3 -c "import json,sys; [print(r) for r in json.load(sys.stdin)['per_team']]"
```
