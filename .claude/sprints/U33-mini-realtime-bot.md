# U33-mini — Real-time bot loop + TouchOffice 10-min cadence

**Goal:** close the gap between "instruction queued" and "instruction
answered" so emails to `jolyboxbot@gmail.com` get a reply within ~5 min
without requiring a manual Claude Code session. TouchOffice scrape moves
from once-daily to every 10 minutes so the dashboard tracks the trading
day in near real-time.

## Architecture decisions

- **Queries are whitelist-gated. Data ingestion is not.** Anyone can email
  data into the system (bank statements, vendor invoices, etc); only
  whitelisted senders can ask the system questions or trigger SQL.
- **Whitelist starts with one row:** `jolyon.sandercock@gmail.com`.
- **Rejected queries are silent.** No reply is sent to the sender. A
  `query_rejections` log row is written. Telegram alert only if rate
  exceeds 5/hr (rate-limited noise).
- **Data lane is strict-source.** Only emails from known senders
  (`natwest@…`, vendor domains we've enrolled) route to specific import
  paths. Unknown-sender attachments land in `documents` with
  `entity_id=NULL` for manual triage. We can widen to content-based
  later if it proves too narrow.
- **Haiku never composes SQL.** It picks from a whitelist of named,
  parameterised read-only stored functions. No write access, no raw SQL.

## Chunks

| # | Chunk | Cost |
|---|---|---|
| 1 | V32 migration: `query_whitelist` table, seed with Jo's email | 10 min |
| 2 | V33 migration: add `lane`, `sender_email`, `needs_session` columns to `bot_instructions`; add `query_rejections` log table | 15 min |
| 3 | Widen poll script: remove `from:` Gmail filter; classify each polled email into `lane='query'|'data'`; keep 15-min cutoff | 30 min |
| 4 | Data lane router: dispatch attachments to existing pipelines based on strict sender match. NatWest CSV → `bank_transactions`. Known vendor PDF → `vendor_invoice_inbox`. Else → `documents` for triage | 60 min |
| 5 | Whitelisted SQL tools: 6 stored functions in Postgres — `today_totals(site?)`, `last_7d_unit_economics()`, `pending_invoices()`, `latest_caterbook_occupancy()`, `recent_alerts(hours?)`, `entity_summary(entity_id)`. Tool definitions in `/home_ai/services/bot-responder/tools.json` | 60 min |
| 6 | Autonomous responder service `/home_ai/services/bot-responder/`: cron `*/5`, picks one `lane='query' AND status='pending'` row, checks whitelist, calls Haiku with the 6 tools, `/send/bot` replies, marks `done` with resolution. Non-whitelisted → mark `rejected`, log to `query_rejections`, silent | 90 min |
| 7 | Escalation: if Haiku indicates it can't answer with available tools, set `needs_session=true`, Telegram-notify "needs session: <subject>", leave row pending | 20 min |
| 8 | TouchOffice cron `0 3 * * *` → `*/10 * * * *` + skip-if-overlap guard (abort if last `touchoffice_scrapes.scrape_started_at` < 8 min ago) | 30 min |
| 9 | Fix `datetime.utcnow()` deprecations in `u29-instructions-poll.sh` | 5 min |
| 10 | Rate-limit Telegram noise on `query_rejections`: if >5 rejections in past hour, send one digest Telegram, suppress per-row alerts | 15 min |
| 11 | E2E verification: <br>(a) Jo sends "what were yesterday's pub totals?" → reply within 5 min <br>(b) Spoofed sender sends instruction → silently rejected, row in `query_rejections`, no Telegram (1 rejection, under rate) <br>(c) `natwest@…` sends CSV attachment → lands in `bank_transactions` <br>(d) Unknown sender sends CSV → lands in `documents` for triage, not bank table <br>(e) TouchOffice cron flips, observe 3 successful runs in 30 min, no overlap | 30 min |

**Total:** ~6 hr.

## Acceptance (gates)

- [ ] `SELECT * FROM query_whitelist` returns Jo's row, active=true
- [ ] Instruction email from Jo gets a reply via `/send/bot` within 6 min of arrival, with `bot_instructions.status='done'` and a non-null `resolution`
- [ ] Instruction email from a non-whitelisted address never receives a reply; row marked `rejected`; row also appears in `query_rejections`
- [ ] NatWest CSV attached email lands in `bank_transactions` regardless of whether sender is whitelisted (data lane bypass)
- [ ] TouchOffice scrapes complete 3+ times within a 30-min observation window with no overlapping runs
- [ ] No Haiku call composes raw SQL — all DB access via the 6 whitelisted stored functions, verified by inspecting `bot_responder` request logs

## Anti-scope

- **No write-SQL for Haiku.** Read-only stored functions only.
- **No whitelist UI.** `INSERT INTO query_whitelist …` directly when
  adding someone. UI is U34+ if ever needed.
- **No "summon Claude Code session" automation on escalation.** Telegram
  notification + manual `claude` open is the human-in-the-loop.
- **No content-based data routing.** Strict-source only. Unknown senders'
  CSVs go to `documents`, not auto-imported.
- **No new Gmail inboxes.** Reuse `jolyboxbot@` for everything.
- **No Anthropic SDK in n8n.** Bot-responder is a standalone Python
  microservice using `anthropic` package directly, deployed as a sidecar
  container or run via cron from host. Decide at chunk 6 — likely host
  cron is simpler.

## Open known-unknowns

- **TouchOffice 3-year backfill** is still running in the background as of
  2026-05-12 morning. Chunk 8's cron flip must wait until backfill is done
  OR include a feature-flag so backfill mode skips the */10 cron. Check
  backfill status before chunk 8 starts.
- **Anthropic API key for bot-responder** is already in Vault at
  `secret/anthropic/api_key`. Confirm bot-responder reads it via Vault,
  not env var on disk.
- **Stored function performance:** if `today_totals()` is slow because
  it's joining big tables on the fly, materialise via the existing
  `v_daily_unit_economics` view rather than recomputing.

## Key paths to touch

- `/home_ai/postgres/migrations/V32__query_whitelist.sql` (new)
- `/home_ai/postgres/migrations/V33__bot_instructions_lanes.sql` (new)
- `/home_ai/postgres/migrations/V34__bot_query_tools.sql` (new — 6 stored functions)
- `/home_ai/scripts/u29-instructions-poll.sh` (widen filter + classify)
- `/home_ai/scripts/u33-data-lane-router.sh` (new)
- `/home_ai/services/bot-responder/` (new microservice — Dockerfile, main.py, tools.json, requirements.txt)
- `/home_ai/scripts/u33-bot-responder.sh` (new — cron wrapper)
- crontab entries: add bot-responder, update touchoffice cadence
