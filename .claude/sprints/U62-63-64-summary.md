# U62 + U63 + U64 — autonomous run summary (2026-05-15)

Three sprints back-to-back, ~3 h autonomous remote.

## U62 — Phase 3 core ✅
- **V80** — `calendar_events` (RLS-protected, indexed) + `tasks` (manual + AI-extracted union view `v_tasks_unified`) + `v_documents_expiry_due` view.
- **`/home_ai/scripts/u62-calendar-sync.sh`** — cron `*/15`. Pulls `primary` calendar across every Google identity with `calendar` scope. **First run: 68 events upserted, 17 in next-30-day window.**
- **`/tasks` page** — drag-down add form, Tabulator with email_tasks + manual rows merged, "✓ done" button. 32 open rows (1 manual + 31 email-extracted).
- **`/api/calendar/upcoming`** — already populated with today's Alhambra MOT + Merc MOT + Provisional with Nicky etc.
- **Paperless-ngx** — container `homeai-paperless` running on `100.104.82.53:8011`. New `paperless` DB on the existing Postgres. Vault secret `secret/paperless` written. `u62-paperless-bootstrap.sh` is re-runnable. `u62-paperless-sync.sh` cron `*/15` ready (smoke-tested: 0 docs ingested because nothing scanned yet). **Awaiting Jo's Brother ADS-2800W SMB profile (30 min in-person).**
- **Doc-expiry alerts** — `u62-doc-alerts.sh` cron 09:00 daily. Routes via `telegram_outbox`. Currently quiet (no documents have expiry dates set yet).

## U63 — Phase 2 close ✅ (3.5 / 5 tracks)
- **T1 Tanda timesheets** ✅ — 30d backfill 47 timesheets / 3,636.7 hours. Cron 02:20 daily installed. `forecast_vs_actual` view now populates.
- **T2 TouchOffice backfill** 🟡 — 30 days, 2 sites = 60 scrapes running in background (PID logged in `/home_ai/logs/u63-touchoffice-backfill.log`). ~67s per (date, site). Progress at 7/120 when this summary was written; should finish in ~1.5h.
- **T3 n8n Anthropic tool-use migration** ❌ deferred — touching live n8n workflow nodes mid-autonomy is too risky without per-node smoke testing. **Queue for next in-person session.**
- **T4 Authelia user prep** 📋 — `users_database.yml` is root-owned by design. Wrote `/home_ai/scripts/u63-authelia-users-prep.sh` which prints ready-to-paste YAML for accountant / pubstaff / family users + access_control rules. **Jo runs at the box: hash 3 passwords with `docker run --rm authelia/authelia hash-password`, paste into users_database.yml, `docker compose restart authelia`.**
- **T5 Coverage page** ✅ — `/coverage` page added to ribbon. Tabulator over `v_feed_coverage_summary` + `v_feed_coverage_recent_gaps`.

## U64 — Phase 5 first steps (RAG) ✅
- **V81** — `vendor_invoice_lines.search_tsv` (STORED tsvector + GIN) + `v_research_corpus` view unioning emails (473) + invoice lines (729) + documents (9) = **1,211 searchable items**.
- **`/api/research/ask`** — Sonnet 4.6 with OR-joined tsquery, ts_rank_cd, ts_headline snippet. Source-filterable (`emails` / `invoice_line` / `document`). Strict citation requirement.
- **`/research` page** in ribbon — text box, source chips, narrative + clickable passages with `<mark>` highlighting.
- **Verified end-to-end**: "cruzcampo" → 5 invoice lines + Sonnet lists 5 keg purchase dates with citations; "wagyu beef from forest produce" → Sonnet correctly catches that it's Freedown Hills brand, not Forest Produce supplier.
- **Vector embeddings deferred to U65** — Ollama on ai-internal can't reach its registry to pull `nomic-embed-text`. Two paths for U65: add `ai-egress` to Ollama, or wire Voyage AI via the existing ai-egress network.

## Mission Control ribbon now
`Economics · Finance · Search · Documents · Tasks · Coverage · Research`

## Migrations applied
- V80 — calendar_events, tasks, v_tasks_unified, v_documents_expiry_due
- V81 — vendor_invoice_lines.search_tsv, v_research_corpus

## Scripts added
- `u62-calendar-sync.sh` (cron `*/15`)
- `u62-paperless-bootstrap.sh` (one-shot)
- `u62-paperless-sync.sh` (cron `*/15`)
- `u62-doc-alerts.sh` (cron `0 9 * * *`)
- `u63-authelia-users-prep.sh` (one-shot, output-only — Jo applies at the box)

## Awaiting Jo (in-person at the box)
1. Brother ADS-2800W SMB profile → `\\<jolybox-tailscale>\paperless-consume` (~30 min)
2. Apply Authelia user stubs from `u63-authelia-users-prep.sh` output (hash 3 passwords, paste, restart, ~20 min)
3. The 4 outstanding U57 in-person items remain: tailscale cert FQDN, vault auto-unseal bootstrap, REALM_ENFORCE flip, PreToolUse hooks install.

## Open for the next remote sprint (U65 candidates)
- Vector embeddings: add `ai-egress` to ollama, pull `nomic-embed-text`, rebuild `v_research_corpus` with a real embeddings column. Recall on "meat" → wagyu/burgers/beef.
- TouchOffice range-scraper for the remaining 271 known-miss dates (after the 30-day batch completes).
- n8n Anthropic tool-use migration (5 nodes) once a quiet window exists.
- Recipe model — sales-to-consumption reconciliation now that line items are live.
- Document versioning + approval workflow (table already supports versions via `document_versions`).
