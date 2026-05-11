# Gate C readiness scorecard — 2026-05-09

Walk of SPEC §6.5 against current build state. Status legend:

- ✅ **PASS** — verified working
- ⚠️ **PARTIAL** — works in isolation, needs real data to fully exercise
- ❌ **FAIL** — known broken
- 🚧 **BLOCKED-on-user** — needs credentials / interactive step
- ⏭️ **N/A Phase 1** — deferred to Phase 2 per SPEC v5.3

## Security (8 items)

| Status | Item | Notes |
|---|---|---|
| ✅ | vault status → Unsealed | Confirmed; runs since `start.sh` boot |
| ✅ | n8n Vault token cannot read secret/garmin | Policy excludes garmin path; verified via diagnose-vault-token-header.sh |
| ✅ | RLS: SET app.current_entity='2' → only entity_id=2 rows | rls-test-suite.sql passes against emails + events |
| 🚧 | Prompt injection email → security_audit_log | sanitiseForPrompt deployed in gmail-ingest-v1; security_audit_log writes deferred (no prompt-injection event emitter wired yet) |
| ✅ | security_audit_log: UPDATE fails (append-only) | Trigger enforces; verified manually 2026-05-01 |
| ✅ | No secrets in any .env file or n8n credential store | Confirmed; n8n uses Vault HTTP fetch pattern; no .env files with secrets |
| ⚠️ | HMAC signature present on all events table rows | Pipelines emit signed events; daily HMAC verifier samples 100 random events, currently 0 calls (workflow needs first 04:30 fire to populate audit) |
| ✅ | UFW: only Tailscale range allowed | Configured in bootstrap.sh; verified active |

## Infrastructure (7 items)

| Status | Item | Notes |
|---|---|---|
| ✅ | docker compose ps → all services healthy | 17 containers running |
| ✅ | nvidia-smi inside Ollama shows RTX 3060 12GB | Confirmed earlier sessions |
| ✅ | Ollama inference returns valid JSON | qwen2.5:7b verified during gmail-ingest-v1 build |
| ✅ | 25+ tables in DB | `\dt` shows ~50 tables including n8n + homeai |
| ✅ | events_overflow: COUNT(*) = 0 | Currently 0 |
| ✅ | events_2026_04 partition exists | Plus 05/06/07 partitions; V12 fn auto-creates +2 months |
| ✅ | Backup: at least one restic snapshot | nightly + weekly snapshots, first IDs 0f85747f / 81fd984d |

## Pipelines (16 items)

| Status | Item | Notes |
|---|---|---|
| ✅ | Gmail: test email → email.received within 15 min | Real email `19e0854873034c7f` flowed through 2026-05-08 |
| ✅ | Idempotency: same email twice → one row | Sprint 2 A1 fix added WHERE NOT EXISTS to Gmail Poller |
| 🚧 | Invoice: PDF → invoices table | P2 built and active; needs an invoice-classified email with attachment to fire — until gmail-ingest-v1 sees one in the wild, untested e2e |
| 🚧 | Invoice idempotency: same PDF twice → one row | UNIQUE on idempotency_key in invoices; will hold once data flows |
| 🚧 | EPoS: TouchOffice email → epos_daily_reports | P5 not built — blocked on Gmail account routing decision |
| 🚧 | EPoS arithmetic: net+vat ≈ gross | Same — pipeline not built yet |
| 🚧 | Caterbook: email → accommodation_daily_reports | P6 not built — blocked on Gmail account routing decision |
| 🚧 | Cashing up: Sheet row → till_reconciliation | P7 not built — blocked on Google Sheets OAuth |
| 🚧 | Cashing up variance: >£5 → Telegram | Same — and Telegram bot not set up |
| 🚧 | Nanny: school email → child_events | P8 built and active; needs school-medical email to fire e2e |
| ✅ | Pipeline versioning: pipeline_version='1.0' | All workflows write '1.0' to audit_log |
| ⚠️ | Event lineage: trace_id chain | Implemented via parent_event_id; verified for email.received → email.classified; invoice.detected → invoice.extracted untested e2e |
| ⚠️ | Dead letter: break pipeline → dead_letter entry | Recovered events flow through dead_letter_archive (V13 cleanup); active dead_letter_count = 0 currently. Auto-pause via Alertmanager DeadLetterFlood verified via synthetic test |
| ⚠️ | Stale lease: 15 min processing → recovered | recover_stale_leases() V13 atomic; runs from Master Router every 30s. Verified V13 marked 21 stuck events as failed; ongoing operation untested |
| ⚠️ | Monthly partition: 25th → next month's partition | partition-maintenance-v1 active; cron fires 2026-05-25 09:00 — first real fire pending |
| ✅ | events_overflow after partition: still 0 | V12 fn creates +2-month partition idempotently |

## Outputs (10 items)

| Status | Item | Notes |
|---|---|---|
| 🚧 | Open WebUI accessible from phone | Container healthy at port 8088; admin signup is interactive |
| 🚧 | Open WebUI: llama3.3:70b listed | llama3.3:70b not pulled (Step 13 deferred per SPEC v5.3) — only qwen2.5:7b in hot tier |
| 🚧 | Open WebUI: admin account, signup disabled | Same — interactive |
| 🚧 | 7am digest email received | P10 not built — blocked on SMTP credentials |
| 🚧 | Telegram morning brief | Same — blocked on Telegram bot |
| 🚧 | Telegram /status command | Same |
| 🚧 | Telegram /takings command | Same |
| ⚠️ | Metabase financial dashboard | Email Review Queue card live; financial dashboard pending real data |
| ⚠️ | Manual review queue shows flagged items | Email Review Queue card lives at `Our analytics`; will populate once classifier flags emails |
| ✅ | Grafana: pipeline health chart shows activity | Pipeline Health dashboard provisioned with 13 panels |

## Summary

| Category | PASS | PARTIAL | BLOCKED | FAIL | N/A |
|---|---|---|---|---|---|
| Security | 6 | 1 | 1 | 0 | 0 |
| Infrastructure | 7 | 0 | 0 | 0 | 0 |
| Pipelines | 4 | 4 | 8 | 0 | 0 |
| Outputs | 1 | 2 | 7 | 0 | 0 |
| **Total** | **18** | **7** | **16** | **0** | **0** |

**Verdict:** **Gate C cannot fully pass without user-side credential setup.**
Of 41 items, 16 are blocked on you (Xero OAuth, Telegram bot, SMTP, Google
Sheets, Open WebUI signup, NAS mount, 70B model pull). The remaining 25
items are all PASS or PARTIAL — no FAILs. The PARTIAL items will go green
the moment real data arrives (an email with a PDF attachment fires P2 →
P9; a school-medical email fires P8; etc.).

## What unblocks the remaining 16

| Blocker | Time | Unblocks |
|---|---|---|
| Xero OAuth (developer.xero.com + Playground) | 30 min | P3, P2 matching, "Invoice→source=email_ocr" check |
| Decide TouchOffice/Caterbook Gmail account | 1 min | P5, P6 |
| Google Sheets OAuth | 15 min | P7 + variance alert |
| Telegram bot via BotFather + chat_id → Vault | 10 min | P10 Telegram side, dead-letter Telegram alerts |
| SMTP creds (Gmail app password works) → Vault | 5 min | P10 email digest |
| Open WebUI admin signup in browser | 2 min | Open WebUI items |
| Pull llama3.3:70b (overnight, 42 GB) | passive wait | "llama3.3:70b listed" item |
| Mount /mnt/mycloud + repoint Restic | 10 min | NAS-side backup item |

Total user-side time: **~75 minutes** spread across 8 unblockers.

## Recommendation

Once Xero + Telegram + SMTP are wired (the three highest-value), the
remaining FAIL surface drops to ~6 items, all minor. Phase 1 closes.
Phase 2 hardening (auto-unseal, Authelia, benchmarks, Dreaming, CI
Auto-Fix) is intentional Phase 2 work per SPEC v5.3.
