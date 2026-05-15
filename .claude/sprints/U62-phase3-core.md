# U62 — Phase 3 core (calendar + tasks + Paperless + doc alerts)

**Prereqs**: U61 shipped (documents schema + linker live).

**Realm**: cross-cutting. Calendar→work/family/owner per source; tasks→inherit from creator; documents→already realm-tagged.

**Remote-doable**: ~80 %. Paperless-ngx container can be brought up; the Brother ADS-2800W SMB profile is Jo's in-person work.

## Tracks

### T1 — V80 calendar_events + Google Calendar sync
- V80: `calendar_events (id, source_account, calendar_id, gcal_event_id UNIQUE, title, start_at, end_at, location, attendees jsonb, body_text, realm, entity_id)`.
- `/home_ai/scripts/u62-calendar-sync.sh` (cron `*/15`) — pull `primary` calendar for each of jo/admin/info/pounana via existing `google/<acct>` OAuth tokens; idempotent on gcal_event_id.
- View `v_calendar_upcoming` (next 30d).

### T2 — V80 tasks + UI
- V80: `tasks (id, source TEXT, source_ref TEXT, title, body, entity_id, realm, priority, status, due_at, completed_at, assigned_to, created_at)`.
- `/api/tasks/list`, `/api/tasks/create`, `/api/tasks/{id}/complete`, `/api/tasks/{id}/snooze`.
- New `/tasks` page in dashboard ribbon. Merges manual rows + `email_tasks` (already extracted).

### T3 — Paperless-ngx container
- New compose service `paperless` (image pinned). Postgres-backed (new `paperless` DB on existing instance). Redis-backed. Tailscale port 8011.
- Vault secret `secret/paperless` (api_token, db_password, secret_key).
- `/home_ai/scripts/u62-paperless-bootstrap.sh` creates DB + Vault secret.
- `/home_ai/scripts/u62-paperless-sync.sh` (cron `*/15`) — REST API → `documents` + run linker.
- In-person carry-forward: Jo to set up "AI BATCH" SMB profile on the scanner (30 min). Without it, the container is idle but harmless.

### T4 — Document expiry alerts cron
- `/home_ai/scripts/u62-doc-alerts.sh` (cron daily 09:00) — surfaces `documents` with `expiry_date <= today+30` or `review_date <= today`. Emits `document_expiry_due` event; bot replies via `telegram_outbox`.

### T5 — Image OCR via Paperless
- Backfill the 9 existing `documents` rows that have empty `ocr_text` if their mime_type is an image. Paperless API enqueues.

## Acceptance
- `SELECT COUNT(*) FROM calendar_events` > 0 after first sync.
- `POST /api/tasks/create` + `/tasks` page renders.
- `docker compose up -d paperless` healthchecks ok; `/api/paperless/documents/` reachable.
- Document expiry alerts dry-run lists 0+ rows.

## Cuts (deferred to U66)
- Versioning + approval workflow for `documents` (table already supports versions).
- Multi-calendar conflict view.
- Image OCR backfill on non-Paperless paths.
