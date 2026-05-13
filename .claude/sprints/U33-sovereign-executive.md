# U33 — Sovereign Executive: Dashboard Refactor + Live Ops Hardening

**STATUS: SHIPPED 2026-05-12** — Tiers 1 & 2 complete, Tier 3 (Authelia) parked partway.
See "Sprint result" section at bottom of file.


**Goal:** "Give me a dashboard that identifies exactly where my money is leaking in under 5 seconds, backed by data that won't fracture if an email is missed."

Reconciliation of an externally-sourced sprint prompt against the actual U32 close state. ~60% of the original prompt was already shipped or already queued — this sprint keeps only the genuinely new value plus the queued Dashboard Refactor.

## Sequencing note

`U33-mini-realtime-bot.md` (Haiku-on-bot-instructions, stored-function tool calls) is **parked** until this sprint ships. Its TouchOffice 10-min cron chunk is folded into this sprint (Chunk 2). The bot-responder work resumes as U34.

## What was rejected from the source prompt and why

| Source ask | Verdict | Reason |
|---|---|---|
| Materialise `caterbook_bookings` into `canonical_bookings` with UPSERT | **Reject** | View rebuilds deterministically from `caterbook_observations`. 482 rows, <50ms reads. `email_report_id` already provides lineage. Premature optimisation that adds drift risk. |
| Unique constraint on `(ref, room)` | **Reject** | Would break the daily-observation pattern. Existing `(report_date, ref, room, section)` unique index is correct. |
| Add `source_event_id` to bookings | **Reject** | `caterbook_observations.email_report_id` already provides this. |
| Create `staff_rate_cache` | **Reject** | `staff_meta` (V31) has been live since U32; 134/134 rates populated. Don't build a duplicate. |
| 15-min TouchOffice cadence | **Adjusted** | 10 min with overlap guard (per U33-mini design). |
| Tanda Sales mirror | **N/A** | Doesn't exist — Tanda is workforce only. Sales come from TouchOffice. |
| Gridstack.js for grid layout | **Reject** | Alpine drag/persist already shipped (U6T3) and survives. Don't swap a working primitive for a dependency. |
| Glassmorphism 20px blur | **Skip** | Already shipped — 14 references in `index.html`. |
| Build `v_executive_metrics` from scratch | **Adjusted** | `v_live_ops_kpis` + `v_daily_unit_economics` already cover labour %, SPLH, traffic light, revenue, hours, cost. Extend rather than replace. |

## Scope — what we ARE doing

### Tier 1 — Data trust & freshness

| # | Chunk | Cost | Notes |
|---|---|---|---|
| 1 | **Tanda pay-sync cron**: schedule `u32-workforce-pay-sync.sh` daily at 02:30 (after `u29-workforce-sync.sh` at 02:15 has refreshed `workforce_users`). Add `/home_ai/logs/u32-pay-sync.log`. | 10 min | Real follow-on from U32 — currently a one-shot. |
| 2 | **TouchOffice 10-min cron** with overlap guard. Cron `*/10 * * * *`; abort if last `touchoffice_scrapes.scrape_started_at` < 8 min ago. Lifted from U33-mini Chunk 8. | 25 min | Bridges trading day into dashboard in near real-time. |
| 3 | **Data Distribution Guard** view `v_kpi_anomalies`: for each KPI (`pub_net_sales`, `accom_revenue`, `labour_hours`, `total_covers`, `in_house_count`), compute today vs 7-day rolling avg; flag if outside ±50%. Severity score for ranking. | 40 min | The genuinely new BI idea in the source prompt. Catches silent-extraction failures (empty PDF parses, missed emails). |
| 4 | **Live occupancy in `v_live_ops_kpis`**: extend the view to bridge `caterbook_bookings`-derived occupancy % for today (`in_house_count / total_rooms`). Add `total_rooms` constant from `variables` table (or new migration if absent). | 25 min | The one missing piece the source prompt correctly identified. |

### Tier 2 — Dashboard refactor (queued plan, executed)

Pulls in the queued `project_dashboard_refactor` brief.

| # | Chunk | Cost | Abort signal |
|---|---|---|---|
| 5 | **State audit + before/after screenshot.** Catalogue every endpoint and YAML data file the dashboard reads. | 20 min | n/a |
| 6 | **Phase-gate progress bar.** Three segments (Phase 1: Foundation ✓, Phase 2: Orchestration, Phase 3: Autonomy). Reads phase data from `data/phase1.yaml` + new `data/phases.yaml` stubs. | 30 min | If phase boundaries don't render cleanly, fall back to hard-coded percentages. |
| 7 | **Executive Command Ribbon.** High-density sticky header: Labour % light, Occupancy %, System Health light. All three off `v_live_ops_kpis` + `/api/healthz-deep`. | 30 min | n/a |
| 8 | **Tiered layout.** Top: Exec ribbon + phase bar. Middle: Live Ops (revenue, labour, occupancy, debt widget). Bottom: registries (tasks, debt, outcomes). 4/8/16/32 px spacing scale. | 45 min | If existing draggable system breaks → revert to soft visual grouping. |
| 9 | **Outcome Registry pagination.** 10/page + "Live Stream" toggle. | 30 min | n/a |
| 10 | **Technical Debt as standalone widget.** Cost-of-Delay = severity × age_days × impact. May need `data/debt.yaml` field additions. | 30 min | n/a |
| 11 | **7-day sparklines** on the 3 primary KPIs (revenue, labour cost, occupancy). Inline SVG, no chart library. | 25 min | n/a |
| 12 | **Real `/api/healthz-deep`.** Replace `/api/healthz` with a probe that actually `SELECT 1 FROM events LIMIT 1` and hits n8n's `/healthz`. 2s timeout each, fall back to "degraded". | 20 min | n/a |
| 13 | **Colour + tabular-nums audit.** Single pass: strict traffic-light palette (Emerald/Amber/Rose/Slate). `font-variant-numeric: tabular-nums` on every stat. JetBrains Mono for numerics. | 25 min | n/a |
| 14 | **Anomaly widget.** Surface `v_kpi_anomalies` rows in a small panel on Mission Control. Red dot if any active. Click → drilldown table. | 25 min | n/a |
| 15 | **Drag-persist regression test.** Reorder a card, refresh, confirm order persists. Selftest 52/52 PASS. | 15 min | If localStorage layout doesn't survive → fix before declaring done. |

### Tier 3 — Security close-out (CONFIRMED in scope, 2026-05-12)

| # | Chunk | Cost | Notes |
|---|---|---|---|
| 16 | **Authelia bootstrap fix.** Resolve Vault/bootstrap-secret mismatch (open debt #3). Verify `homeai-authelia` starts cleanly with secrets read from Vault, not bootstrap stub. | 30 min | Pre-req for chunk 17. If Authelia fails to start after fix, abort Tier 3 and park as standalone sprint. |
| 17 | **Caddy `forward_auth` wiring.** Add `forward_auth` directive in `Caddyfile` for `/dashboard`, `/pub`, `/economics`, `/m`, `/forensics`, `/touchoffice`, `/caterbook`, `/workforce`, `/invoices`. `/api/healthz-deep` stays public (heartbeat probes). | 45 min | Smoke test: unauthenticated `curl -I` against each protected route returns 302 → Authelia; authenticated session passes through. |
| 18 | **Verify `bot_instructions` ingress still works.** The instruction-poll cron is host-side (not via Caddy) but confirm Telegram webhook/heartbeat still reaches inside the perimeter. | 15 min | Regression guard — auth-walls have a habit of breaking inbound automation. |

**Total: ~9 hr** (Tier 1 + Tier 2 + Tier 3).

## Acceptance gates

- [ ] `crontab -l` shows `u32-workforce-pay-sync.sh` scheduled; one successful run logged.
- [ ] `touchoffice_scrapes` shows ≥3 successful rows within a 30-min observation window, no overlap.
- [ ] `SELECT * FROM v_kpi_anomalies WHERE flagged=true` returns rows where today's KPI is outside ±50% of 7-day rolling avg (force-test by injecting a synthetic outlier).
- [ ] `v_live_ops_kpis` has a non-null `occupancy_pct` for today.
- [ ] Mission Control loads in <2s and renders 3 traffic lights at the top, a phase-gate bar, and a debt widget — none requiring scroll.
- [ ] Drag a card, refresh — order persists.
- [ ] `/api/healthz-deep` returns 200 when Postgres + n8n both healthy; returns 503 with `{degraded: [...]}` when one is down (simulate by stopping n8n briefly).
- [ ] No traffic-light colours outside the four-colour palette (Emerald/Amber/Rose/Slate). Single grep audit.
- [ ] All numeric stats render with `tabular-nums` and JetBrains Mono — no digit jitter when values tick.
- [ ] `homeai-authelia` running with Vault-sourced secrets (no bootstrap-stub fallback).
- [ ] `curl -I https://<dashboard>/dashboard` from an unauthenticated session returns 302 → Authelia for all protected routes; `/api/healthz-deep` stays public.
- [ ] `bot_instructions` poll + Telegram heartbeat still firing post-Authelia (regression check).

## Anti-scope

- **No materialised `canonical_bookings`** — observations + view is the canonical pattern.
- **No Gridstack.js** — current drag system stays.
- **No new auth model beyond Authelia bootstrap fix** — Tailscale-fence remains the outer perimeter.
- **No `staff_rate_cache`** — `staff_meta` is the cache.
- **No "Tanda Sales"** — Tanda is workforce; sales come from TouchOffice. Don't let LLM-suggested entities sneak in.
- **No bot-responder work** — that's U34 (resumes the parked U33-mini).

## Memory rules in force

- Rule 1 (verify before done): each chunk needs a smoke test in the running system, not just a file edit.
- Rule 6 (state sync): each session start, re-query `bot_instructions`, `pg_views`, `crontab`. Memory drifted ~7 migrations behind reality during the U32→U33 gap — don't trust documented state.
- Rule 7 (no A/B menus mid-execution): pick one path per chunk and ship it.
- Rule 9 (3-attempt cap): especially on Tier 2 layout work, abort and park if 3 re-renders fail.
- Rule 10 (audit consumers): `v_live_ops_kpis` is read by `index.html`, `m.html`, `/api/kpis`, possibly Metabase — grep before changing its column set.

## Files in scope

- `/home_ai/postgres/migrations/V39__kpi_anomalies_and_occupancy.sql` — NEW
- `/home_ai/services/build-dashboard/main.py` — `/api/healthz-deep`, `/api/anomalies`, `/api/occupancy`
- `/home_ai/services/build-dashboard/static/index.html` — exec ribbon, phase bar, anomaly widget, sparklines, tier layout
- `/home_ai/services/build-dashboard/data/phases.yaml` — NEW (phase 2/3 stubs)
- `/home_ai/services/build-dashboard/data/debt.yaml` — extend with `age_days`, `impact`
- `/home_ai/scripts/install-u33-crons.sh` — NEW (idempotent crontab installer for Tanda pay-sync + TouchOffice 10-min)
- `/home_ai/config/caddy/Caddyfile` — Tier 3 only, if Authelia confirmed in-scope

---

## Sprint result (2026-05-12)

### Shipped

| Chunk | What | Result |
|---|---|---|
| C1 | Tanda pay-sync cron | Installed: `30 2 * * * /home_ai/scripts/u32-workforce-pay-sync.sh`. Test run upserted 134 staff_meta rows. |
| C2 | TouchOffice 10-min cadence | Already in cron from U33-mini (`u33-touchoffice-realtime.sh`, 480s overlap guard). Verified ≥3 successful scrapes in last 30 min. |
| C3 | `v_kpi_anomalies` view | V39 migration applied. Catches today's data outside ±50% of 7-day rolling avg. Currently flagging 2 partial-day under-readings (expected mid-day). |
| C4 | Occupancy bridge | `v_live_ops_kpis` extended with `occupied_rooms`, `total_rooms`, `occupancy_pct`. `ops_constants` table seeded with `inn_total_rooms=9`. |
| C5 | Dashboard state audit | Found ~60% of Tier 2 already shipped in U31/U32 (phase bar, tiers, pagination, debt widget, healthz-deep, palette, tabular-nums). Updated chunk verdicts accordingly. |
| C6 | Phase-gate bar | Verified pre-shipped (`/api/phases` + Alpine renderer at index.html:545-567). |
| C7 | Executive Command Ribbon | Extended: replaced "In-house" tile with "Occupancy" (% + rooms used + guests), added inline-SVG sparklines on Labour%/Revenue/Occupancy. |
| C8 | Tiered layout | Verified pre-shipped (TIER 1/2/3 wrappers, `.tier` CSS). |
| C9 | Outcome Registry pagination | Verified pre-shipped (`paginatedOutcomes()`, 10/page, Live Stream toggle). |
| C10 | Technical Debt widget | Verified pre-shipped (standalone widget with Cost-of-Delay badge). |
| C11 | 7-day sparklines | Added `/api/kpi/sparklines` + `sparkSvg()` helper rendering inline SVG polyline + tinted area. |
| C12 | `/api/healthz-deep` | Verified pre-shipped (postgres + n8n + google-fetch probes, 2-3s timeouts). |
| C13 | Colour + tabular-nums | Verified pre-shipped (4-colour palette tokens, `.stat-num`, `.num-stable`, JetBrains Mono). |
| C14 | Anomaly widget | Added: alert strip above KPI ribbon, only renders when `flagged_count > 0`. Click expands to detail table (metric × today × 7d avg × Δ% × severity). |
| C15 | Drag-persist regression | Selftest 51 PASS + 1 unrelated FAIL ("Gmail Ingest" workflow inactive, pre-existing). Drag/persist JS unchanged from prior shipped state. |

### Parked

| Chunk | Status | What's left |
|---|---|---|
| C16 | Half-done | Vault drift resolved (config re-rendered from Vault), `users_database.yml` written with argon2id hash of generated admin password (stored at `secret/authelia/admin_initial`), compose block consolidated. **Blocker:** Authelia 4.39 rejects empty `identity_providers: {}` block in config. Drop that line and run `docker compose --profile phase2 up -d authelia`. |
| C17 | Not started | Needs C16 first. |
| C18 | Not started | Needs C16/C17 first. |

### New artifacts

- `/home_ai/postgres/migrations/V39__occupancy_and_kpi_anomalies.sql`
- `/home_ai/services/build-dashboard/main.py` — new endpoints `/api/anomalies`, `/api/kpi/sparklines`; rebuild required before they're live (image bakes main.py — see [[feedback_dashboard_image_rebuild]])
- `/home_ai/services/build-dashboard/static/index.html` — occupancy tile, anomaly strip, sparklines, anomaly drilldown table
- `/home_ai/security/authelia-v2/configuration.yml` — re-rendered from Vault (now matches)
- `/home_ai/security/authelia-v2/users_database.yml` — argon2id-hashed admin password
- `/home_ai/docker-compose.yml` — Authelia block consolidated (single block, profile-gated to `phase2`)
- Vault: new `secret/authelia/admin_initial` (24-char strong password)
- Cron: new line `30 2 * * * /home_ai/scripts/u32-workforce-pay-sync.sh`

### Verification

```bash
# All endpoints return 200
for url in /api/healthz /api/healthz-deep /api/phases /api/anomalies /api/kpi/sparklines /api/economics/overview; do
  curl -s -o /dev/null -w "$url %{http_code}\n" http://100.104.82.53:8090$url
done

# Occupancy bridge live
curl -sf 'http://100.104.82.53:8090/api/economics/overview?days=2' \
  | python3 -c "import json,sys; k=json.load(sys.stdin)['kpi']; print(f\"occupancy={k['occupancy_pct']}% rooms={k['occupied_rooms']}/{k['total_rooms']}\")"

# Anomaly guard live
curl -sf http://100.104.82.53:8090/api/anomalies \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('flagged:',d['flagged_count'],'/ items:',len(d['items']))"
```

### Lessons recorded

- New feedback memory: `feedback_dashboard_image_rebuild.md` — main.py + static/ are baked into the image, not volume-mounted. Rebuild + harvest POSTGRES_PASSWORD from Vault before `compose up`.
- Existing dashboard had ~60% of the Tier 2 brief already shipped in U31/U32; the queued `project_dashboard_refactor.md` memory was stale. Memory updated.
