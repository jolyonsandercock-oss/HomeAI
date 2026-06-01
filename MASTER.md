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
