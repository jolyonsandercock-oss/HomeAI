# Home AI — Live State Snapshot (for external review)

*Generated 2026-05-12, R2 status appended 2026-05-14. Designed to be
ingested by another LLM (Gemini, GPT, etc.) for a second-opinion review
of what's live, what's planned, and where the design has shifted from
the original spec.*

## 0. Most recent change (2026-05-14)

**Realm-split R1 + R2 shipped (U52).** Three-realm access model
(OWNER / WORK / FAMILY) now enforced at the database layer:

- 93 home_ai domain tables carry a `realm` column (V64/V64a).
- 87 of those (all non-partition tables) carry a `realm_isolation` RLS
  policy (V65 + V65b). On the 43 tables that already had an entity-level
  policy, realm_isolation is RESTRICTIVE so it AND-composes with the
  existing entity filter. On the other 44, it is PERMISSIVE and is the
  sole filter.
- `home_ai.set_realm(text)` chokepoint function validates & sets
  `app.current_realm` per-transaction.
- A transitional NULL/empty-GUC branch returns TRUE for every row so
  pre-V65 behaviour is preserved until services explicitly opt in.
- `query_whitelist.realm` reseeded; `bot-responder` filters slugs by
  caller's realm at load time.
- `REALM_ENFORCE` env on build-dashboard. Default `0` (dormant — every
  request runs as OWNER). Flip to `1` only after R3 Auth lands and
  Authelia + Caddy set the `X-Realm` header.
- Shadow test (`/home_ai/scripts/u52-realm-shadow-test.sh`) verifies
  enforcement across 20 tables × 3 realms — `--baseline` / `--check
  transitional` / `--check enforced` all green at sprint exit.
- `v_realm_audit_violations` view: 0 violations across events,
  invoices, vendor_invoice_inbox, bank_transactions, documents (emails
  excluded — realm derived from mailbox-of-receipt by spec).

**Realm work outstanding**: R3 Auth (blocked on tailscale-cert FQDN
[[feedback_authelia_cookie_domain]]), R5 Ingest tagging (next sprint),
R6 Bot/AI scope (queued), R7 Backup (queued).

## 1. Business context

Owner: Jo (jolyon.sandercock@gmail.com). Runs three concerns:

| Concern | Legal entity | Key systems |
|---|---|---|
| **Pub / inn / restaurant / ice-cream shop** | Atlantic Road Trading Ltd (entity_id=1) | TouchOffice/ICRTouch EPoS, Caterbook accommodation, Workforce.com (Tanda) staff |
| **Investment properties** (7 units) | Atlantic Road Estates Ltd (entity_id=2) | bank, rent ledger |
| **Personal / family** | entity_id=3 | Gmail, school emails, calendar |

Goal of Home AI: an "administrative engine" sitting between these — a
single Postgres + dashboard + Telegram bot that ingests everything,
normalises it, surfaces anomalies, and answers the daily "did the
business make money?" question without copy-paste.

## 2. Architecture (one paragraph)

Single host (JolyBox, Ubuntu 26.04) on a Tailscale tailnet. ~25 Docker
containers under one compose file (`/home_ai/docker-compose.yml`).
PostgreSQL 15 as the single source of truth, with row-level security
keyed on a `app.current_entity` GUC. Vault stores all secrets (zero
secrets on disk in the build tree, enforced by a PreToolUse hook).
n8n orchestrates pipelines. AI workers (Ollama for hot tier, Anthropic
Claude Haiku for cloud tier) are stateless and only see sanitised text.
Backups: nightly + weekly Restic to local + GitHub off-host-backup of
the config tree (no data). All inbound user traffic Tailscale-fenced.

## 3. Pipelines (Phase 1 — 10 of 11 live; P3 parked on Xero)

| # | Name | Trigger | Source → Sink | Status |
|---|---|---|---|---|
| P1 | Gmail Ingest | Gmail watch on 5 accounts | google-fetch poll every 1min → `events` table with HMAC-signed payload | **live** |
| P2 | Invoice Pipeline | `invoice.detected` event | pdfplumber/MarkItDown + Haiku → `invoices` + `vendor_invoice_inbox` | **partial** (ingest + inbox triage live; full extraction blocked on P3 Xero matching) |
| P3 | Xero Sync | scheduled | Xero API → `xero_invoices` + `xero_payments` | **PARKED** — OAuth authorize endpoint rejects requests even with minimal scope on a fresh app; email sent to api@xero.com for log lookup |
| P4 | Bank CSV Import | manual upload | NatWest CSV → `bank_transactions` | live |
| P5 | TouchOffice EPoS (browser) | cron 03:00 daily | Playwright scrape of touchoffice.net home widgets → `touchoffice_fixed_totals` + `_department_sales` + `_plu_sales` per site (Malthouse + Sandwich Bar) | **live** — 30d backfill clean, 3y backfill running in background |
| P6 | Caterbook (email) | cron 07:00 daily | Gmail PDF (`info@malthousetintagel.com` → `stay@…`, subject "The Olde Malthouse Inn: Arrivals and Departures") → pdfplumber → `caterbook_observations` → derived views `caterbook_bookings` + `caterbook_room_nights` | **live** — 140 emails ingested (2025-11-19 onward, 282 complete bookings, 467 room-nights) |
| P7 | Cashing Up | cron 23:30 (planned U32) | Google Sheet `2026CashUp` (weekly-block layout) → `till_reconciliation` join to TouchOffice for variance flagging | scaffolded; creds in Vault; parser is the U32 chunk |
| P8 | Nanny | child_events ingest | school emails → `child_events` | live (105 events across 3 kids, 90d backfill) |
| P9 | Report Ingestion | manual or pipeline-emitted | misc reports → `documents` | live |
| P10 | Daily Digest | cron 21:00 | rolls up P5+P6+P8+health → email (Gmail API via `jolyboxbot@`) + Telegram | **live** |
| P11 | Monthly Partition | cron 25th of month | creates next month's `events` partition | live |

Also wired:
- **U30 Workforce** sync (Tanda API) — daily 02:15 cron, 1,343 shifts /
  36 staff / 6,000.5 hours over the last 12 months. Schema: `workforce_users`,
  `workforce_locations`, `workforce_shifts`, `workforce_timesheets`,
  `workforce_wage_comparisons`, `workforce_sync_log`.

## 4. Inbound instruction loop (live)

- `jolyon.sandercock@gmail.com` → `jolyboxbot@gmail.com` poll every 5 min
- New emails queued in `bot_instructions` (V30 migration), Telegram ACK
  to the user within ~5 min of arrival
- Claude Code session start checks the queue (enforced via a feedback
  memory entry) before doing other work
- Bot replies via `google-fetch /send/bot` (Gmail API, no SMTP needed)

## 5. Heartbeat

Cron `*/15` sends a 2-line silent Telegram pulse:
- scrape ages (last successful TouchOffice / Caterbook / Workforce sync)
- firing alerts + dead-letter count
- pending instructions count

## 6. Dashboards (Tailscale-only, `100.104.82.53:8090`)

| Route | What's there |
|---|---|
| `/` | Mission Control — debt, tasks, phases, agents, lifecycle, heartbeat |
| `/pub` | Pub Live Ops board (older schema; rewire pending in U32) |
| `/touchoffice` | per-site per-day NET/GROSS/covers + top depts + top PLUs + scrape log |
| `/caterbook` | today's arrivals/stayovers/departures + per-room revenue + daily snapshots |
| `/workforce` | per-day + per-dept + top-staff + sync log |
| `/invoices` | vendor-invoice triage (Tabulator: sort + filter + click-through) |
| `/playground`, `/forensics` | older single-purpose tools |
| `/viewer/email/{account}/{message_id}` | renders any Gmail message inline (sandboxed iframe) |
| `/viewer/snapshot/{filename}` | streams an HTML/PNG scrape snapshot |
| `/viewer/pdf?path=…` | streams a whitelisted PDF |

`/invoices` is the proof of U31 dashboard-table UX: every column header
sorts, every column has a filter input, free-text search, click any row
to see the source email rendered inline. The other four pages get the
same treatment in U32.

## 7. Stack / dependencies

- **Postgres 15** (in-container, partitioned events table by month)
- **Vault 1.15.6** (Shamir-unsealed, 5 shares / 3 threshold)
- **n8n** for orchestration; ~80 active workflows
- **Ollama** (qwen2.5:7b hot tier, phi4/llama3.3:70b warm)
- **Anthropic Claude Haiku** for invoice extraction; **Sonnet 4.6** for
  Code/agent work
- **Playwright (Python, in `homeai-playwright` container)** for the
  TouchOffice browser scrape — Tanda image (microsoft/playwright:noble)
- **pdfplumber** + **MarkItDown** for PDF/doc parsing
- **Caddy** as reverse proxy (most routes still direct-port — Caddy
  routes for `/dashboard`, `/metabase` etc. are queued debt)
- **Grafana + Prometheus + Alertmanager** for monitoring
- **Restic** for backups (local + GitHub off-host-backup of config tree)

## 8. Tables landed (recent migrations)

- V27 `touchoffice_fixed_totals` / `_department_sales` / `_plu_sales` / `_scrapes`
- V28 `caterbook_email_reports` / `_observations` / `_daily_snapshots` + views `caterbook_bookings` + `caterbook_room_nights`
- V29 `vendor_invoice_inbox` + 6 `workforce_*` tables
- V30 `bot_instructions`

Total ~70 tables, all RLS-protected with the `entity_isolation` policy.

## 9. Cron schedule (UK time)

```
00:30  synthetic-email-suite           tests pipelines didn't drift
02:15  u29-workforce-sync 7d           Tanda labour data
03:00  backup-nightly + u27-touchoffice-daily (both sites)
07:00  u28-caterbook-daily             pulls latest Caterbook PDF
21:00  u29-daily-digest                email + Telegram digest
*/5    u29-instructions-poll           email-instruction queue
*/15   u29-heartbeat                   silent Telegram pulse
```

## 10. Outstanding work

**Open debt (3):**
- P3 Xero — parked awaiting Xero support
- PreToolUse hooks not installed in `~/.claude/settings.json` (2 min fix)
- Authelia bootstrap secret/Vault mismatch (cosmetic, 30 min)

**Open tasks (9 hands-off + 1 user-blocked):**
- Complete U31 dashboard-table migration (3 pages)
- `daily_unit_economics` view + `/economics` page
- P7 Cashing Up parser
- Invoice PDF auto-extraction (vendor_invoice_inbox enrichment)
- Workforce department-name sync
- Phone-first `/m` landing page
- Caddy reverse-proxy routes
- CI Auto-Fix (GitHub Actions)
- Schema drift column-order cleanup
- (user) Xero OAuth retry once support replies

## 11. Open design questions worth a second opinion

1. **Cross-pipeline economics:** the cleanest "did the business make
   money today" view is a Postgres view joining `touchoffice_fixed_totals`
   (net sales) + `caterbook_room_nights` (accom revenue) + a derived
   `workforce_shifts.hours_worked × workforce_users.base_pay_rate`
   (labour cost). But `base_pay_rate` is only populated on some users —
   we'd need a separate API call to `/api/v2/user_pay_fields` to fill the
   rest. Is that the right design, or should we compute labour cost from
   pay_runs (more authoritative, less granular)?
2. **Caterbook reconstruction:** each email is a snapshot (today's
   arrivals + stayovers + departures), so a single email never gives
   arrival_date + departure_date for the same booking. We collate
   across multiple emails by `(ref, room)` key in a view. 282 of 474
   observed bookings are "complete"; 120 are pre-window (booked before
   our oldest email, 2025-11-19); 72 are post-window (still in-house).
   Is the view the right place to derive this, or should we materialise
   the bookings into a table at ingest time?
3. **TouchOffice browser scrape:** is it sustainable, or should we
   migrate to Tanda's "Sales actual" mirror once the latter starts
   returning rows (currently empty for this account)? The browser scrape
   is fragile (HTML can change without notice).
4. **Vendor invoice inbox vs canonical invoices:** I've split into two
   tables — `vendor_invoice_inbox` (light triage, every invoice-shaped
   email) and `invoices` (heavyweight P2-extracted). Is that the right
   separation, or should the inbox be a status column on the canonical
   table?
5. **`bot_instructions` queue:** good enough for one user, but what about
   conflicts when two instructions arrive about the same thing? Should
   there be a "supersedes" link, or do I trust Claude to read the queue
   in order?

## 12. Reviewer notes

- Code: github.com/jolyonsandercock-oss/HomeAI (off-host-backup; private)
- Schema: `/home_ai/postgres/init-db.sql` + migrations V1..V30
- Sprint plans: `/home_ai/.claude/sprints/U*.md` (13 plans on disk)
- This doc: `/home_ai/STATE.md` (regenerate manually at major sprint
  boundaries)

What would you reach for first if your remit were "make this more
trustworthy without breaking what works"? What's the biggest design
risk you see in §11?

— Home AI (built by Claude Code under Jo's direction, 2026-04 → 2026-05)
