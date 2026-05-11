# U27 — Browser-scraped EPoS + Accommodation (P5/P6 unblock)

**Goal:** Get `epos_daily_reports` and `accommodation_daily_reports` populating.
**Approach:** Replace the Gmail-trigger design for Pipelines 5 + 6 with a
Playwright-based scraper that logs into the vendor portals and extracts the
same fields the existing parsers already expect. Downstream is unchanged.

## Why this sprint exists

User confirmed 2026-05-11: neither TouchOffice (touchoffice.net) nor Caterbook
support emailing daily reports. Both portals are browser-only. The original
SPEC v5.2 §6.2 design (Gmail Trigger → Haiku report_parser) can't fire — no
inbound mail will ever arrive.

The pivot keeps the value-add layer (Haiku parser + arithmetic validation +
schema INSERTs + event emission) intact and swaps only the source: instead of
"email arrives", a cron-scheduled Playwright run produces the same JSON shape
the existing pipeline nodes consume.

## Scope (chunks)

| # | Chunk | Owner | Estimate |
|---|---|---|---|
| 1 | Vault credentials — `secret/touchoffice` + `secret/caterbook` | you | 5 min |
| 2 | Scraper service scaffold — `homeai-scraper` container (Python + Playwright + headless Chromium on `ai-internal`) | me | 60 min |
| 3 | TouchOffice scrape — login → Reports → previous-day Z-report → emit `epos.report.received` | me | 90 min |
| 4 | Caterbook scrape — login → Arrivals/Departures or daily summary → emit `accommodation.received` | me | 90 min |
| 5 | n8n rewire — replace Gmail Trigger with Schedule Trigger (04:30 EPoS / 09:00 Caterbook) + HTTP Request to scraper | me | 30 min |
| 6 | SPEC + STRETCH edits — §6.2 Pipeline 5/6 triggers, §2.6 vendor-setup section | me | 15 min |
| 7 | Failure handling — 3 retries, screenshot on final fail, dead_letter on persistent miss, audit_log row per run | me | 30 min |
| 8 | Optional polish — re-run new `authelia-bootstrap.sh` to align Vault with rendered config (carry-over from U26) | me | 5 min |

**Total:** 4-6h of build + 5 min of user-provided creds.

## Dependencies

- TouchOffice + Caterbook usernames + passwords (chunk 1 is the gate)
- Flag from you on 2FA / captcha presence on either portal — different login
  flow if so (TOTP injection, or a one-time browser-state seed)
- All infrastructure already in place (Vault, n8n, Postgres schema, alerting)

## Architecture sketch

```
┌──────────────────────────────────────────────────────────────┐
│ n8n Schedule Trigger (04:30)                                 │
│   └─> HTTP Request → homeai-scraper:8000/scrape/touchoffice-z│
│         └─> Playwright → touchoffice.net                     │
│              ├─ login (creds from Vault)                     │
│              ├─ navigate to Z-report for date=yesterday      │
│              ├─ extract table → JSON                         │
│              └─ return {report_date, session, net_sales,…}   │
│   └─> emit `epos.report.received` (existing pipeline takes   │
│       over: Haiku parser → arithmetic check → INSERT)        │
└──────────────────────────────────────────────────────────────┘
```

`homeai-scraper` lives in `services/scraper/` (new) — single Python service,
`/scrape/touchoffice-z` and `/scrape/caterbook-arrivals` endpoints. Reads
creds via `docker exec homeai-vault vault kv get` at scrape time so secrets
never sit in env vars.

## Out of scope (anti-scope)

- Touchless / fully-automatic credential rotation (annual manual rotate is fine)
- Real-time scraping (daily cadence is enough — these are reporting tools)
- Multi-property support beyond The Olde Malthouse (one site each for now)
- Generalising the scraper for other vendors (Xero/NatWest already have APIs)
- ICRTouch PLU-level per-flavour tracking — that's the separate ICRTouch
  config debt from STRETCH §4 (Pending Decisions)

## Risks

| Risk | Mitigation |
|---|---|
| Captcha on either portal | Use a session-cookie seed; if hard captcha → manual once-a-day login + cookie reuse |
| 2FA on either portal | Plan around TOTP injection or seeded browser-state |
| Selector drift (vendor changes HTML) | Snapshot full HTML on every run to `/home_ai/storage/scraper-snapshots/` + use text-anchored selectors |
| ToS — browser scraping | User-owned accounts, internal use only, no public redistribution → typical-pattern fine; document in SPEC |
| Persistent login fail | After 3 retries → dead_letter + alert via existing pipeline; daily auto-pause if 2 consecutive misses |

## Acceptance criteria

- [ ] `secret/touchoffice` and `secret/caterbook` populated in Vault
- [ ] `homeai-scraper` container healthy on `ai-internal`
- [ ] EPoS daily run at 04:30 yields ≥1 row/day into `epos_daily_reports`
- [ ] Caterbook daily run at 09:00 yields ≥1 row/day into `accommodation_daily_reports`
- [ ] 2 consecutive failures produce a `dead_letter` row + Telegram alert (once P10 is up)
- [ ] SPEC §6.2 P5/P6 + §2.6 reflect Playwright triggers
- [ ] `debt.yaml` P5/P6 entry resolved
- [ ] phase1.yaml P5/P6 status flips from blocked → done

## Carries forward to U28+

- P3 Xero OAuth (still user-blocked)
- P7 Cashing Up — Google Sheets OAuth (still user-blocked)
- P10 Daily Digest — Telegram + SMTP (still user-blocked)
- Caddy reverse-proxy routes (tasks.yaml `caddy-routes`)
- Authelia container start + Caddy forward_auth wiring
- CI Auto-Fix (now possible — `off-host-backup` GitHub repo exists)

## Anti-scope still

- LoRA fine-tune (Phase 3, GPU planning needed)
- Storyblok (Phase 5)
- Calendar/Drive/Sheets pipelines (Phase 3)
- WhatsApp / Garmin (Phase 4)
- Paperless-ngx Phase 3 build (SPEC v5.2 §8.1b — needs the Brother ADS-2800W on hand)
- NAS-mount restic repoint (postponed by you 2026-05-11)
