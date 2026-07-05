# Home AI — MASTER reference (living)

> **This is the ongoing project reference file.** It is the curated, current
> truth of the system: what's **live**, what's **next**, and what's
> **degraded/superseded**. Read this first for project state.
>
> **Relationship to the other docs (all retained):**
> - **`SPEC.md`** (v5.4) — original master build specification. Unchanged. Read
>   for design intent / architecture detail.
> - **`HOME-AI-STRETCH.md`** — future-ideas backlog. Unchanged.
> - **`STATUS.md`** — auto-generated git/state snapshot (regenerated only at
>   `/retro`, so often stale). This file (`MASTER.md`) **supersedes STATUS.md**
>   as the human + Claude project reference.
>
> **Update cadence:**
> - **§4 Daily commit log** is appended automatically each night by
>   `scripts/update-master-status.sh` (cron) — mechanical capture of the day's
>   commits.
> - **§1–§3 (Completed / Next / Degraded)** are re-classified *in-session* as
>   work lands — move items between sections; don't let them drift. When you
>   finish a day's work, reconcile these three against §4.
>
> **Last curated:** 2026-05-30

---

## §1 — Completed / Live

### Platform
- ~24 Docker services under one compose file; Postgres 16, n8n, Vault (auto-unseal
  via age + systemd), Ollama (GPU), Tailscale-fenced host (JolyBox).
- Event-sourced pipeline core: Master Router + deterministic event routing, HMAC
  payload signing, idempotency, stale-lease recovery (`recover_stale_leases_v3`).

### Pipelines (n8n, active)
- **P1 Gmail Ingest** + Gmail Poll Driver — email ingestion → `emails` (+ entity/realm).
- **P4 Bank CSV Import** — NatWest/credit-card CSV → `bank_transactions` (legacy pattern).
- **P5 EPOS / TouchOffice** — daily till scrape → `touchoffice_*` → `epos_daily_reports`.
- **P6 Caterbook** (+P6b Bookings) — daily arrivals/departures + reservations.
- **P7 Cashing-up** (deterministic, slug-based) — `cashup_inputs`, `till_reconciliation`,
  `cash_variance`, `safe_movements`, Clover batches.
- **P8 Nanny**, **P9 Report Ingestion**, **P10 Daily Digest**, **P11 Partition Maintenance**.
- Infra: Alertmanager Sink, HMAC Verifier, Notify Bridge, Cleanup, Diagnostics,
  Dead-Letter Sweeper, Watchdog (n8n errors), Pub Anomaly Alerter, Cornwall News.

### Security
- Authelia + Caddy `forward_auth` live at the tailscale FQDN; 3 accounts —
  jo (owner), karl (manager), staff (general); `/admin /private /build` owner-gated.
- Realm model **R1 (label)** + **R2 (RLS)** shipped — realm column on every domain
  table; `home_ai.set_realm()` chokepoint; RLS by realm × entity. **R3 (auth)** live.
- Vault-only secrets, prompt-injection sanitiser, pre-push entropy guard, quota
  hard-mode across 4 tiers (~£0.69/30d).

### Operational surfaces
- 139+ approved `query_whitelist` slugs. Mission Control dashboard + `/sales /rooms
  /bar /cafe /restaurant /staff /comms /admin /backend`.
- Revenue close-loop (today / 7d / breakdown), menu PLU performance, vendor
  intelligence (spend / price-creep / reorder), mortgage vision-OCR, reviews
  (email-notification parsing).

### Observability / resilience
- `data_source_freshness` slug + Telegram heartbeat canary; recon data-quality
  slugs + daily digest; monthly DR restore drill (passes, RTO ~36s); cron
  self-healing; auto-generated docs (slug-catalog, data-sources, cron-jobs).

### Data feeds
- TouchOffice (pub + café), Caterbook, Tanda/workforce, weather, tides,
  guest reviews, bank CSV — all on the host crontab (see §4 / `cron-jobs.md`).

---

## §2 — Desired / Next phases

### Phase 7 — work-realm rollout + hardening
- **Karl (pub manager) onboarding + mobile dress rehearsal** (`U154`) — the WORK
  realm's reason to exist; pending UX polish.
- **Service → RLS-role connection migration** (`U147`) — services (`bot-responder`,
  `build-dashboard`) still connect as `postgres` superuser → RLS bypassed; move to
  per-realm NOLOGIN roles. *Only material security item open.*
- **UX polish series** — ongoing; needs owner eyes on rendered pages.

### Phase 8 — analysis
- **Recipe / inventory economics** — `recipes`/`recipe_components` scaffolded; GP-per-dish
  and food-cost % (TouchOffice PLU × recipe) not yet surfaced.

### Integrations
- **Xero Sync (Pipeline 3)** — *not live* (freshness `never`; `xero_bills` scaffolded,
  no API). Leaves the invoice ↔ accounting loop open (`recon_invoices_unmatched_in_xero_21d`).
- **Reconciliation v5.4 migration** — bank + TouchOffice run the legacy pattern;
  `raw.`/`staging.` 3-adapter rewrite queued. **Clover per-transaction** blocked on
  Clover dashboard API (batch-level manual statements only for now).

---

## §3 — Degraded / Superseded

- **Invoice Pipeline P2 (`invoice-pipeline-v1`)** — **DEACTIVATED 2026-05-30**. Broken
  vault path (`secret/gmail/` vs `secret/google/`; can't do service-account accts).
  Superseded by the **u35 shell chain** (u95 harvest → u35 extract → u36 Haiku) writing
  `vendor_invoice_inbox`. The spec'd `invoices` table is empty/legacy. To revive: rewire
  to google-fetch `/attachment` + repoint `frontend_invoices_recent` to `invoices`.
- **Trail compliance scraper** (`u215-trail-poll.py`) — **DEGRADED**. Login fails at
  `no_2fa_chooser_found` (Access Group flow changed); last good report 2026-05-28.
  Needs scraper fix + re-pair at the console. Not scheduled.
- **Dojo live scrape** — **DEGRADED**. CAPTCHA-blocked (U229 Path B). Relies on manual
  CSV export → `data/dojo-inbox/`; `u135` sweep (cron 07:15) imports drops only.
- **TripAdvisor review scraping** — **SUPERSEDED** by email-notification parsing
  (DataDome-blocked the scraper).
- **Caterbook 06:00 auto-trigger** — was unreliable (missed days); **superseded** by
  `u28` host cron (07:30, idempotent 2-day window).
- **`STATUS.md`** — stale between `/retro` runs; **superseded** by this file as the
  living reference.

---

## §4 — Daily commit log

_Appended nightly by `scripts/update-master-status.sh`. Newest at bottom._

### 2026-05-30
Large stabilisation day (host crontab had been reset ~mid-May, silently dropping
many pipeline jobs). Work landed:
- **Invoices unfrozen** — u35 extractor fixed to process harvester-stamped rows +
  skip Paperless IDs; backfilled ~1.9k; hourly cron; u95 daily ingest restored;
  u36 Haiku fallback on 60-day window. P2 deactivated + Master Router route disabled.
- **TouchOffice → EPOS bridge** fixed (phantom `site` column crash + entity mapping);
  cron repointed to git-tracked host script; missing 05-26/05-27 days re-scraped.
- **Freshness restored** — backfilled caterbook (incl. 05-26); scheduled u27
  (TouchOffice yesterday), u28 (caterbook), u29 (workforce sync), u133 (tides),
  u135 (dojo sweep), u29-heartbeat. Accommodation freshness threshold 6h→24h.
- **Telegram/email** — reactivated `telegram-bot-v1` (was live but flagged inactive);
  fixed Gmail Ingest ~10% RLS drops (entity fallback); fixed P9 (google-fetch rewire);
  drained 31-item dead-letter backlog. Heartbeat → 6-hourly always-emit.
- **selftest** green (51/0) after dropping retired P2 from expected-active list.
- Created this MASTER.md living reference.

### 2026-05-30 — commits
- 3a7251e u29-heartbeat: 6-hourly always-emit (update / exception / emergency)
- 92a9bea selftest: drop retired invoice-pipeline-v1 (P2) from expected-active list
- a251831 May 30 round 7: wired filter bars to slug date params on all 5 department pages, updated slugs to accept :date parameter
- 3c22d39 May 30 round 6: comms page email modal with prev/next navigation, dismiss on action, auto-ignore rules on Ignore button, open-in-Gmail button, email task API with ignore rule creation
- aa1465d May 30 round 5: filter bar on rooms/restaurant/bar/cafe/staff pages, sales labour% line restored, gmail links on tasks expense rows, force-extract button on invoice detail
- 2248dc5 May 30 round 4: force line-extraction button on invoice detail, API endpoint + SECURITY DEFINER function
- acb9a99 May 30 round 3: restored sales page rewrite - Pub/Cafe split table, pagination, labour% thresholds, category bar labels, income-vs-labour chart with labour% line, cafe pink
- c2a69b7 May 30 round 2: priority email flagged table on dashboard + comms page, email action modal (snooze/done/ignore), email task API, email_priority_keywords table, keyword add UI, fixed gross today warning text
- 07daed9 May 30 wrap: sparklines removed, AI quota + expenses moved to backend, tasks page overhaul with expense exception categorisation, auto-rule creation API, cafe colour pink, TOM106 pub site resolution, Booking.com scraper disabled
- 76d0e46 touchoffice-to-epos: fix crash (no 'site' col) + entity mapping
- 0dcfc43 scripts: add u95-harvest-cron.sh for daily incremental invoice ingestion
- 7ef82f9 u36-invoice-haiku-fallback: skip duplicate/ignored rows
- 7901752 u35-invoice-pdf-extract: process harvested rows + skip Paperless ids
- 46e00ff scripts: add test-all-slugs.cjs slug smoke-test harness
- 280c365 sales: add empty-state guards to category + income-vs-labour charts
- c607346 CLAUDE.md: document Postgres MCP + installed plugins + skills (2026-05-30)
- dc2f416 hermes-reply.sh: fix printf bug with leading-dash format strings
- 0276f0d U234 + U235 + U236: Mission Control upload tile, alerting close-out, Hermes outbox
- 586d8d4 Action Hermes 2026-05-30 drops — CLAUDE.md + sunset/food analysis

### 2026-05-31 → 06-01
Big session. Security, COGS/KPIs, data backfills, comms restore.
- **U147 Phase A (security) — cross-realm leak CLOSED.** `/invoices` (and all
  slugs) were serving every realm to work requests: `set_realm` ran outside a
  txn (SET LOCAL evaporated → RLS NULL→all) AND the invoice views bypassed RLS
  (postgres-owned, no `security_invoker`). Fixed both (`withRealm()` txn wrapper
  in lib/db.ts; V216 `security_invoker` on v_purchase_search/cogs/margin).
  Verified personal data no longer reachable at work realm.
- **U147 Phase B (front-half) — work/owner realm GATE shipped.** Frontend now
  derives realm from the trusted Authelia `Remote-Groups` (lib/realm.ts) instead
  of hardcoded 'work'; owner sees all, work/personal RLS-scoped, default-deny to
  work. First use: local Ollama/qwen telemetry surfaced on /backend (owner-only,
  V222). Unblocks owner/personal dashboard items. Role-layer migration still pending.
- **U233 — invoice realm mis-classification fixed.** `derive_realm` checked inbox
  before entity → 76 ARTL invoices tagged personal; made entity-authoritative,
  retagged 74 → work (£92k→£147k correctly counted); St Joseph's/Math Academy → entity 4.
- **U232/U234 — COGS coverage signal + KPI traffic-light dashboard.** v_cogs_capture_coverage;
  kpi_targets + v_kpi_live + kpi_dashboard slug; KpiTrafficLight band on Mission
  Control (mgmt+ops, action levers, provisional KPIs muted). Salaried-staff table —
  Karl Ramsey GM £40k is source of truth, hourly Tanda shifts excluded (labour 18.6→16.8%).
  Jo's real thresholds applied (V223). GP/prime provisional pending stock.
- **U235/237 — 5yr Gmail backfill.** 72k email headers (info/admin/jo/pounana, 2021→),
  idempotent, processed=true; bodies backfilling overnight (work first, ~69k).
- **U236 — marketing/junk sweep.** 2,687 obvious-marketing emails → 'ignored'
  (operational/family/regulatory protected); hourly forward cron.
- **Dojo** CSV imported (→05-29; 2797 new); u135 sweep fixed (ran python3 in the
  postgres container which has none → rerouted via bot-responder). NatWest last-import
  dates emailed to Jo.
- **Comms loop restored** — u66-telegram-bot + u29-instructions-poll + u33-bot-responder
  crons were missing (silent); re-added, drained 3 stuck Telegram msgs. Crontab snapshot committed.
- **Booking.com reviews** — 6 from screenshot loaded into guest_reviews.
- **UX pass** — content max-width, mobile table overflow, mobile-first KPI grids, rhythm.
- Migrations V216–V223. Many commits (d309160 … be5160d).

### 2026-07-02 — commits
- 46c57d0 feat(invoices): rules-based categorisation push for 2026 residual (48 vendors, 81.8%->91.6%)
- ad6adac feat(security): deepseek route via LiteLLM gateway (Presidio + ai_usage) — hermes repoint pending host port
- 84482db chore(security): relocate loose n8n cred backup to security/cred-archive/
- 4f66f3c chore(compose): remove duplicate markitdown stanza + dead garmin/vault-mcp
- 0f93f7a docs(gen): regenerate stale views/migrations/cron docs
- e9a0be5 docs(spec): R2 decision framework — mechanical thresholds for OCR engine, model stack, prune, cap migration
- f7075e0 docs(architecture): correct four stale §2 health-column entries
- 5243a5b docs(hygiene): add supersession banners to stale dead-docs
- f129cd5 fix(ops): small-fix bundle — selftest timeouts, digest cap, u273b exit, shared pg-connect helper
- 8fb806c chore(hygiene): attic one-shot UI patch scripts, drop stale .bak files
- b16d058 fix(counterparty): wire anchor + resolution_log provenance writes (were never landing)
- 22fd8c6 fix(invoices): timeout+retry on pdf-extract fetch path
- 935ede7 fix(calendar): map dead 'family' realm to 'personal' at sync source (V164 pivot leftover)
- 07a5839 fix(invoices): TD-036 add think:false to date extractor (gemma4 returns empty without it)
- 0aef115 feat(ocr): implement MistralOCRAdapter (vault-gated, supplier-invoice scope)
- 32f6737 fix(ops): R0 final-review fixes — cron-health attribution through ops-run wrapper, reporter exit-0, 45d runs retention
- d18213b fix(scripts): R0.9 review fixes — guard heredoc rc-capture in 4 sweeps + per-item natwest docker cp
- 3485d33 fix(pipelines): P6 fix #3 — restore Parseable? gate semantics broken by report_date defaulting
- 6bfb12f fix(scripts): R0.9 batch 4/4 — set -e on silent-exit-0 scripts (with || true audit)
- e9aa8b3 fix(scripts): R0.9 batch 3/4 — set -e on silent-exit-0 scripts (with || true audit)
- 74dfb9d fix(scripts): R0.9 batch 3/4 — set -e on silent-exit-0 scripts (with || true audit)
- ec1db46 fix(scripts): R0.9 batch 2/4 — set -e on silent-exit-0 scripts (with || true audit)
- 82e3941 fix(scripts): R0.9 batch 1/4 — set -e on silent-exit-0 scripts (with || true audit)
- d2039fe feat(db): R0.8 generic partition maintenance for all partitioned parents
- 74d0174 feat(ops): R0.7 schedule nightly system auditor (05:30)
- 14159e8 fix(ops): u273b review fixes — add build-dashboard:8090 to MAP, guard recreate failure
- 12143d3 feat(ops): R0.6 boot-race self-heal for all tailnet-bound services
- 192fbc1 fix(ops): R0.5 review fixes — probe hard-fail = 000/5xx only + re-probe in post-repair verification
- fa38054 feat(ops): R0.5 deep ollama generate-probe + full-fleet selftest coverage
- 6246168 feat(ops): R0.4 daily Telegram ops digest (stale pipelines + firing alerts + open exceptions)
- 738001c feat(ops): R0.3 alert-row hygiene — 72h auto-resolve
- 3cf8ad2 feat(ops): R0.2 stuck-processing reaper + pipeline_runs 30d retention
- 896a1c1 feat(ops): R0.1 canonical crontab — heartbeat-wrap all jobs, dedupe, full registry seed
- 7f7f2b8 docs(plan): R0 close-the-loop implementation plan (9 tasks)
- 358c6b1 fix(pipelines): 2026-07-02 incident triage — gmail SQL param, P6 repair, dead-letter re-drive, hermes bridge
- 957b967 docs(spec): end-to-end refactor program design (approach A, observability first)

### 2026-07-03 — commits
- 3b90c20 fix(p2): u291 — invoice extraction dead under n8n filesystem binary mode
- 5f81356 feat(models): W7800 benchmark decision record — tiers re-cut on evidence
- 4effb29 fix(pdfplumber): pikepdf repair-retry when pdfium rejects a PDF render
- d239ed1 chore(audit): re-anchor baseline (compose de-superuser edits; 2 fewer INV-PG-SUPERUSER findings)
- 4eef4de sec(egress): TD-007 complete — Hermes DeepSeek traffic now via litellm/Presidio
- 0c68284 fix(alerts): u290 — Diagnostics (daily) now resolves cleared Diag_* alerts
- 2272106 sec(db): de-superuser postgres-exporter + google-fetch (2 of 7 superuser DSNs)
- 8d5a80b perf(services): raise homeai-mcp + homeai-data-proxy pools 4->16
- 69bbac8 perf(google-fetch): per-message pool acquire in poll-and-emit, gated /messages fan-out, pool 4->16
- 212c5d5 perf(llm-router): 60s cache on model.tiers/ai.thresholds config reads
- 5a18ec2 fix(start): refresh planner stats after boot (unclean-shutdown stats wipe)
- ce2c809 chore(db): V289 drop search_vectors (760MB, zero readers, Jo-approved)
- f47079c chore(audit): re-anchor invariant baseline after compose line drift
- 300f5fc perf(calendar): u62 incremental sync via Google syncToken
- 2f522ed feat(dashboard): AMD GPU sensing via amdgpu sysfs (dead since W7800 swap)
- 53d4bec perf(dashboard): V288 apply_db_context() — one round trip for role+entity+realm
- 1c16884 perf(bots): u66 single-spawn preamble via in-container Vault HTTP; u33 cadence comment fixed
- 10a908c perf(parsers): run pdfplumber/markitdown CPU work off the event loop
- 0fc6ea0 docs(perf): mark 2026-07-03 perf pass executed, record deviations + residuals
- 317acd9 perf(crons): watermark touchoffice bridge, u29 dedup-before-fetch, u68 concurrent classify, u35 drop per-row fetchval
- ce2e031 perf(dashboard): 45s TTL cache on polled endpoints, pool 4->16, off-loop GPU sensing, tsv-first email search
- f0161d3 perf(monitoring): scrape postgres-exporter at 60s not 15s
- c298666 sec(caddy): strip client Remote-* identity headers + JSON access log (F1 item 5)
- 538a2b4 fix(links): kill /dashboard/ + hardcoded tailnet IPs, drop dead drift widget (F1 item 3)
- f441cd5 feat(frontend): /app/ops health board + /app/reviews tracker + counterparty door (F1 items 1,2,4)
- 66572ba Flag-fix 20260703: CoT statements, junk outliers, Caterbook category
- c2c271d feat(r2): u281 drain v2 — attempt-tracked fair ordering + supplier few-shot (V286)
- bd341e2 fix(r2-bench): mistral leg prompt template — str.format vs JSON braces KeyError
- 3b32ee3 security(sentinel): re-anchor hermes baseline (Jo-reviewed 2026-07-03)
- f66ea86 fix(walkthrough): poll litellm up to 90s after recreate instead of sleep 5
- a8c1f7c feat(gateway): litellm loopback publish 127.0.0.1:8771 + Jo walkthrough script
- f84a9ce chore(drift): capture live config drift from 2026-06-25 /app cutover
- c54e7a4 feat(obligations): insurance renewals as reminders + readable labels + u121 finally scheduled (V285)
- 02d7354 fix(dashboard): economics totals follow head_office truth; vendor CDN deps; m.html error states
- e32e365 fix(observability): unconditional per-run heartbeats — u29 poll + ops-run wrapper
- 4647165 docs(plan): frontend F1 plan — audience split, /app/ops board, /app/reviews (#1161), integrity fixes

### 2026-07-04 — commits
- 765c5f5 fix(finance): accurate fee categorisation — 14 -> 150 real fees (£953/12m)
- 9c7e581 fix(finance): kill bank_fee catch-all — £2.3M phantom 'Fees paid' -> real
- 848a8d8 fix(dashboard): pub occupancy uses true 10-unit count, not hardcoded 7
- ed718f1 feat(dashboard): sender-rules review page under Tasks
- a8578c2 feat(classifier): auto-derived data-driven invoice-sender denylist
- c51951a feat(classifier): u293 — non-invoice sender denylist at the email layer
- e51b16e perf(db): V290 index hygiene — kill 60s emails full-scan, reclaim ~213MB
- fd98aa8 fix(p9): parameterize Report Ingestion write — pg-promise $N injection on document text

### 2026-07-05 — commits
U294 (bank line categorisation, T1-T6): registry+kind guards (V294) close the
"never again uncategorised" gap; true NULL now 0 (was ~21k); own-account
transfer pairing (447 rows), narrative + residual rule packs (V295/V296),
daily categoriser cron, and an LLM tail classifier get deduped coverage to
83.7% real categories + 16.3% honestly-labelled needs_review (bar was 15%,
not gamed). Acceptance suite (scripts/u294-acceptance.sql) green except that
one bar; category FK validated; consumer audit of 13 views found and fixed
2 real misstatements (V297: v_uncategorised_summary, v_account_transfers_open).
- c78fc53 feat(finance): U294 T6 — acceptance cross-foot suite green; FK validated; consumers audited
- 314036a feat(finance): U294 T5 round 4 — V296 residual rule pack, LLM path retired
- f61c7ba fix(finance): U294 T5 round 3 — gemma31b escalation + think:false + 3 new validators
- 39e40b6 fix(finance): U294 T5 — hard validators (direction/kind, bank_fee cap) + no-guess prompt
- 90aa7e2 feat(finance): U294 T5 — LLM tail classifier over residual clusters (registry-constrained)
- a1b7441 feat(finance): U294 T4 — u58 categoriser heartbeat + registry + daily cron
- 3758edd feat(finance): U294 T3 — narrative rule pack (YouLend/CoT/Principality/HMRC/+identified patterns)
- 6e0159d fix(finance): U294 T2 — tighten Signal B to strict both-leg A/C phrases (v1 legmatch reverted)
- 85877a8 feat(finance): U294 T2 — own-account transfer pairing (acct-no + leg-match signals)
- 3857f9e fix(finance): V294 review fixes — drop V71 category CHECKs, rules FK, re-run-safe (U294 T1)
- b86a27e feat(finance): V294 bank category registry + kind mapping + rule lint (U294 T1)
- 6ddc0d8 docs(plan): U294 bank line categories — registry+kind guards, transfer pairing, rule pack, LLM tail
