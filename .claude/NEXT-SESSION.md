# Next session — opening prompt (draft)

_Updated 2026-06-01. Read `MASTER.md` §4 (2026-05-31→06-01) first._

## Live & verified (this session)
- **Realm security closed + gated.** U147 Phase A (cross-realm leak fixed:
  `withRealm()` txn wrapper + `security_invoker` views, V216) and Phase B
  front-half (work/owner **realm gate** — frontend derives realm from Authelia
  `Remote-Groups`; owner sees all, work/personal RLS-scoped, default-deny to
  work). Owner/personal dashboard items can now be added safely.
- **Local AI telemetry** surfaced on `/backend` (owner-gated, V222).
- **KPI traffic-light dashboard** live (Mission Control) with Jo's thresholds
  (V223). GP%/prime **provisional** (muted) — pending stock + covers.
- **Invoice realm fixed** (U233, entity-authoritative). **COGS coverage** signal (U232).
- **5yr email backfill**: 72k headers done; **bodies backfilling overnight**
  (`u237`, work first). Marketing junk filter (`u236`, hourly).
- **Comms loop restored** (u66/u29-instructions-poll/u33 crons re-added) — Telegram
  + email chat works. **Dojo** current to 05-29; u135 sweep fixed.

## In progress / next
- **Morning digest emails** (admin = yesterday/7d/30d performance retro; info =
  1d/7d forward briefing) + a **KPI/business/customer data tick-list** for Jo to
  select/edit what each email contains — STARTED this session.
- **KPI accuracy**: GP%/prime stay provisional until (a) **covers ingestion**
  (TouchOffice covers report — needs a scraper session; the home-dashboard widget
  doesn't carry covers) and (b) stock counts (deferred by Jo).
- **U147 role-layer (Phase B back-half)** — services off `postgres` superuser →
  per-realm roles; flip RLS NULL→TRUE to default-deny; pen-test. High blast radius.
- **Gate hardening**: strip client `Remote-Groups` on the IP-backdoor route.

## Owned elsewhere / parked
- **TouchOffice 5yr history** — Hermes (home-widget caps ~12mo; needs Reports-page scraper).
- Trail scraper broken (2FA selector); Xero P3 not live; Reconciliation v5.4 queued.
