# U163-U167 — Autonomous batch (5 sprints, no Jo-input required)

All 5 sprints execute without human-in-the-loop. Sequenced for impact-per-hour.

## U163 — Reviews scraper Playwright rewrite

**Prereqs**: review_listings has 3 URLs (Google, TripAdvisor restaurant, TripAdvisor hotel).

**Build**:
- `scripts/u163-reviews-scrape.py` — Playwright headless, profile-persisted, parses each listing's recent reviews. Headers spoofed (User-Agent + Accept-Language) to bypass casual anti-bot.
- For TripAdvisor: tagged-as-bot rows live in `.review-container` divs; iterate, extract reviewer / rating / body / posted_at.
- For Google: render the embedded reviews page via Playwright (no API), parse from DOM.
- Upsert into `guest_reviews` via natural key (source + reviewer + posted_at).
- Replaces existing `u133-scrape-reviews.py` cron entry.

**Acceptance**: 7-day backfill of reviews; `reviews_recent` slug returns data.

## U164 — Pipeline self-healing

**Build**:
1. **Master-router post-trigger**: after each `Trigger X Pipeline` HttpRequest returns 200, n8n node sets events.status='processed' immediately, regardless of webhook response shape. Removes the 10-min recovery delay. n8n API edit, no schema change.
2. **`recover_stale_leases_v3()` function**: extend v2 to also handle ANY event where `processing_started_at > 30 min ago` — recover regardless of retry_count if downstream evidence exists. The current threshold of retry_count >= 3 dead-letters too eagerly.
3. **`pipeline_completion_lag_5m` slug**: per pipeline, count of events still in 'processing' >5 min. Surfaces drift before it floods.

**Acceptance**: 24h soak shows zero dead_letter rows from `stale_lease_recovery` source.

## U165 — Operational observability

**Build**:
- `pipeline_health_per_day` slug — per workflow, per day: runs, success rate, p50 + p95 duration.
- `data_source_freshness` slug — per upstream (gmail/caterbook/dojo/touchoffice/xero/dext/trail/reviews): max(received_at OR scraped_at OR transaction_date), age vs expected cadence.
- `cost_by_capability_30d` slug — ai_usage rolled up by capability_tag with quota ceiling delta.
- `scripts/u165-freshness-watcher.sh` — cron */15 min, queries `data_source_freshness`, Telegrams if any source > expected_cadence × 2.
- Synthetic alert test: stale a source artificially, confirm alert fires.

**Acceptance**: stale-source alert fires within 15 min of synthetic stale.

## U166 — Data quality reconciliation

**Build** — 5 reconciliation slugs:
- `recon_dojo_vs_touchoffice_7d` — daily total comparison; flag >5% drift.
- `recon_bookings_vs_room_nights` — find accommodation_bookings without corresponding caterbook_room_nights.
- `recon_invoices_unmatched_in_xero_21d` — orphan candidates for chase.
- `recon_duplicate_attachments` — email_attachments with same (gmail_message_id, filename) but different ids.
- `recon_uncategorised_documents` — docs with category='paperless' that look invoice-shaped (heuristic on title/correspondent).

Plus:
- `data_quality_issues_open` — union of all above with severity classification.
- `scripts/u166-data-quality-digest.sh` — cron 06:00 daily; Telegram digest if total open issues > 10.

**Acceptance**: digest delivers tomorrow morning; running counts surfaced.

## U167 — Backup restore drill

**Build**:
- `scripts/u167-restore-drill.sh` — spins postgres sandbox container on port 5433 with empty volume, runs `restic restore latest --target /tmp/pg-sandbox`, restores from snapshot.
- Validation queries: row counts match prod within 0.1%, schema version matches, sample slugs return same rows.
- Document RTO (restore time) + RPO (last snapshot age) in `audits/u167-restore-drill-<date>.md`.
- Cron monthly (`0 4 1 * *`). Telegram on failure, silent on success (logged only).
- Stretch: same for off-host-backup git repo — clone to scratch, verify HEAD.

**Acceptance**: first run completes <15min RTO; subsequent runs land monthly without intervention.

## Execution order

1. **U163** — closes visible gap; populates 11 currently-empty slugs.
2. **U164** — prevents future auto-pause; protects U159-U162 work.
3. **U165** — proactive instead of reactive; would have caught today's issues earlier.
4. **U166** — silent drift detection; foundational for staff rollout.
5. **U167** — DR proof; declares the system audit-ready.
