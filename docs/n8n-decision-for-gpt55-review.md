# n8n vs Cron — Architecture Decision Brief (for GPT-5.5 assessment)

**Prepared:** 2026-06-20 · **For:** external review via Hermes → GPT-5.5 · **All figures measured live today.**

---

## 0. TL;DR — what we need from you

We run a self-hosted "home AI" administrative engine for a small UK hospitality + property business
(a pub, a cafe, letting rooms, and a property company), operated mostly by **one owner plus AI agents**.

For weeks we believed **n8n** (a visual workflow tool) was a near-dead legacy layer we were replacing
with simple **cron jobs**. We just measured the live system and that belief is **wrong**: n8n is the
busiest, most load-bearing component we have. So before we invest in "retiring" it, we want an outside
read on whether that's even the right goal — and if so, how to sequence it safely.

**Please assess sections 5–8 and answer the 6 questions in section 8.**

---

## 1. The system in one paragraph

Event-driven data platform on one Linux box, all Docker. PostgreSQL 16 is the backbone (a partitioned
`events` table + domain tables, with row-level security isolating 4 business *entities* and 3 *realms*
owner/work/personal). Two orchestration mechanisms run side by side: **(A) n8n** processes a real-time
event bus (email/document/invoice flow), and **(B) ~66 cron jobs** ("sweeps") pull/scrape the other
data sources directly into the DB, deliberately bypassing the event bus. Local LLMs (on an AMD GPU) do
enrichment; secrets live in Vault. There is no ops team — reliability and simplicity matter more than
throughput.

**Glossary** (so this reads standalone): *entity* = which of the 4 legal businesses a row belongs to;
*realm* = a privacy boundary (owner/work/personal); *sweep* = a cron job that pulls one source on a
schedule; *Pn* = an internal pipeline number (P2 invoices, P5 EPoS tills, P6 accommodation, P9 document
classification, etc.).

---

## 2. Architecture as actually measured today (this corrects our own docs)

> ⚠️ **Correction to our internal architecture doc.** Its headline claim was *"the n8n event path is
> largely DEAD; the live system is cron sweeps."* **That is false as of 2026-06-20.** n8n's Master
> Router is the single busiest component, and several pipelines we'd marked "inactive" are active. An
> earlier AI-assisted review inherited the wrong premise. Everything below is freshly measured.

### 2a. n8n workflow activity — last 24 hours (from n8n's own execution log)

| Workflow | Runs/24h | Cadence | Role | Verdict |
|---|---:|---|---|---|
| **Master Router** | **2,880** | ~every 30s | Claims queued events, dispatches to pipelines (2,832 ok / 48 err) | **Live core** |
| Telegram Bot (commands) | 1,440 | ~every 60s | Owner command handler | Live |
| **Gmail Ingest Pipeline** | 323 | webhook + poll | The real **email → DB** path (classify, detect invoices) | **Live, load-bearing** |
| Report Ingestion (P9) | 139 | event-driven | Classifies inbound documents | Live (but lossy — see §3) |
| P5 EPoS / P6 Caterbook / P6b Bookings | 96 each | ~every 15m | Till + accommodation event handling | Live |
| Gmail Poll Driver | 96 | ~every 15m | Pull trigger feeding Gmail Ingest | Live |
| **Invoice Pipeline (P2)** | 54 | event-driven | Invoice capture from `invoice.detected` | **Active** (doc said "inactive") |
| Dead Letter Sweeper / Pub Anomaly Alerter | 24 each | hourly | Housekeeping / alerts | Live |
| **Alertmanager Sink** | 5 | on-alert | **Every Prometheus alert flows through here** | **Live, single point** |
| Notify Bridge, Nanny (P8), Daily Digest, Diagnostics, HMAC Verifier, Cornwall News | 1–7 | daily/ad-hoc | Misc | Live, low-volume |
| Bank CSV Import, Cleanup (weekly), Image Audit (monthly), **Partition Maintenance** | **0** | — | Idle / not firing | See §6 risk |

### 2b. Cron sweeps — 66 active jobs

These pull sources that never touch the event bus: EPoS tills (TouchOffice), accommodation (Caterbook),
labour (Tanda/Workforce), bank statements, British Gas portal, Paperless, calendar, invoice **PDF
extraction** (the GPU line-item + date extractors), counterparty resolution, plus the new **Metis**
self-improvement loop. This half of the system is already cron-native and version-controlled.

### 2c. The real shape: it is *already* a hybrid

- **n8n owns the event bus**: Gmail webhook → `events` table → Master Router (30s) → P2/P5/P6/P9.
- **Crons own the scraped sources**: 66 sweeps writing straight to domain tables.

So the question is not "n8n *or* crons" — we already run both. The question is whether to **migrate the
event-bus half off n8n too**, or **keep n8n as the deliberate event/webhook layer**.

---

## 3. Data-flow health (measured today)

- `events` table: **11,188 processed · 0 pending · 1,146 failed · 1 in-flight.** No live pile-up.
- The **1,146 failed** break down as: `document.received` **822** (newest 2026-06-04 — residue of an
  attachment-handling quarantine), `invoice.detected` **232** (newest 2026-06-01), `email.received`
  **55** (newest **today** — a live trickle of failures), `child.event.detected` 32.
- A **pipeline-health registry** (`ops.pipeline_runs`) was built specifically as "evidence to justify
  retiring n8n." It **exists but has 0 rows** — it was never wired up. So we currently have **no
  systematic health evidence** for any pipeline.

---

## 4. What *only* n8n does today (the hard dependencies)

1. **Alerting.** Alertmanager is hard-wired to `http://homeai-n8n:5678/webhook/prom-alert`
   (`receiver: n8n-sink`). **Kill n8n and all Prometheus alerting goes silent.** This is the gating
   dependency.
2. **Live email ingestion.** The Gmail webhook (real-time push) + poll driver. Crons do not currently
   ingest email.
3. **Event routing.** Master Router is the dispatcher between event producers and consumer pipelines.
4. **P2/P5/P6/P9** pipelines and the Telegram command bot.

---

## 5. The decision — three postures

**A. Status-quo hybrid (do nothing structural).** n8n keeps the event bus; crons keep scraped sources.
Lowest effort. Cost: the event-bus half stays in a tool that is hard to version, hard to test, and has
a history of silent failures (quarantines, dead-letter floods, GUC drift).

**B. Shrink n8n to a thin webhook/event layer.** Move all *scheduled orchestration* to crons (mostly
already done); keep n8n only for genuine webhook receivers (Gmail push, Alertmanager sink) and the event
router; stop building anything new in it. Medium effort, large reliability win, keeps a small stable n8n.

**C. Full retirement to cron + tiny services.** Replace even the webhook receivers with small dedicated
endpoints (we already run a `critical-listener` service that could host them). Highest effort; eliminates
n8n entirely; risk concentrated in re-implementing the live email path.

**Our current lean: B**, on the reasoning that a *permanent* co-equal hybrid of two orchestration engines
is the worst case (double the failure surface), but a *thin, bounded* n8n confined to dumb webhook
receivers is pragmatic for a solo-run system. **We want you to pressure-test that lean.**

---

## 6. Proposed plan (if we pursue B, with the door open to C)

Phased and gated — nothing is disabled until its replacement is proven by a parallel run.

- **Gate 0 — Make the system observable.** Wire the empty `ops.pipeline_runs` registry: every pipeline
  (n8n *and* cron) emits a heartbeat + row-count on each run. **You cannot safely retire what you can't
  measure, and right now we measure nothing.** ~1–2 weeks to accumulate baseline.
- **Phase 1 — Move alerting off n8n.** Repoint Alertmanager from the n8n sink to the existing
  `critical-listener` service. This removes the single hardest dependency and de-risks everything after.
- **Phase 2 — Certify the cron half.** 14 days of green registry data proving the 66 sweeps are
  complete and fresh. (This half is already cron-native; this is evidence-gathering, not migration.)
- **Phase 3 — Migrate the event-bus half (the hard part).** Per pipeline (P2/P5/P6/P9, Gmail Ingest,
  Master Router): decide cron-poll replacement vs keep-in-thin-n8n, run both in parallel for 7 days,
  confirm capture parity (±5%), then cut over with a documented rollback.
- **Phase 4 — Residual webhook receivers.** Decide thin-n8n vs tiny-service for the last 1–2 endpoints.
  Low stakes once Phases 1–3 are done.

**Sequencing principle:** observability → alerting independence → certify the easy half → migrate the
hard half → mop up. We do *not* touch the live email path until everything around it is proven.

---

## 7. Open risks & unknowns (please scrutinise)

1. **Lossy pipeline?** 1,146 failed events (incl. 55 `email.received` failing *today*). We don't yet know
   if these are benign (dupes/junk) or real data loss. This must be triaged before we trust any
   parity claim.
2. **Webhook vs poll latency.** Gmail ingestion is real-time *push*. A cron replacement is *poll*
   (5–15 min lag). For a low-volume business inbox this is probably fine — but it's a genuine downgrade
   we'd be accepting.
3. **Partition Maintenance shows 0 runs.** Monthly DB partitions are created by an n8n workflow that
   isn't firing. July's partition exists; **August's may not** — a latent time-bomb independent of this
   whole decision, and a sign n8n itself has silent gaps.
4. **No evidence base.** The registry is empty, so today every "it's fine" claim is anecdotal.
5. **Solo-operator constraint.** Whatever we choose has to be debuggable at 7am by one non-specialist
   owner with AI help. "Technically superior but more moving parts" may be the wrong trade here.

---

## 8. Questions for you (GPT-5.5)

1. **Is retirement even the right goal?** Given n8n is the live core (not vestigial), is migrating off it
   worth the risk, or is posture **A/B** — "freeze n8n, keep it as a bounded event/webhook layer, crons
   for everything else" — the saner target for a solo-operated system? Argue the strongest case against
   our lean.
2. **Is the phase order right,** and what gate are we missing? Specifically: should alerting (Phase 1)
   come before or after certifying the cron half (Phase 2)?
3. **Push vs poll:** does losing real-time webhook email ingestion actually matter for a low-volume
   business inbox, or is poll-every-5-min strictly fine?
4. **Failures & evidence:** fix the 1,146 failed events + empty registry *before* migrating, or migrate
   first and fix as we go? What's the risk of each ordering?
5. **Highest-risk single step** in our plan, and how would you de-risk it?
6. **Steelman "hybrid forever."** We assert a permanent two-engine hybrid is the worst case. Is that
   actually true here, or is a *deliberate, bounded* hybrid (n8n = dumb webhook shim, crons = everything
   scheduled) a perfectly good end state we should just commit to and stop agonising over?

---

*Appendix — confidence note: every number in §2–§4 was read from the live database / live config on
2026-06-20. Where our own architecture document disagrees, trust this brief; the doc is being corrected
separately.*
