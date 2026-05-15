# U47c — Email intelligence + access split + classifier loop close

**Prereqs**: U47a + U47b shipped.

**Remote-doable**: 100% (basic-auth provisioning is scripted; Jo verifies in browser separately).

**Adjustments from original U47 plan based on Jo's feedback 13/5**:
- Reviews scraper: **alerts only, no drafts**. Jo replies manually. Drafter cron is switched off.
- Hourly review polling (not weekly).
- TripAdvisor: public review page scrape (no login). Skips the SSO risk; owner-reply functionality deferred to U48 in-person work.

## Tracks

### Track 1 — 52-week recurring task suggester (~2h)

Weekly Sonnet job mines emails from 52w ago for periodic patterns Jo should
renew/repeat now (insurance renewals, licence renewals, accountant year-end,
supplier contract reviews, school holiday rotas, summer/winter menu changes,
business rates, water-rates direct-debit checks).

**Script `u47-recurring-task-suggester.sh`** (cron Mon 09:00):
- Pulls emails where `received_at BETWEEN now()-372d AND now()-358d`.
- Plus optional last-4-same-weeks-of-quarter for shorter cycles.
- Sonnet tool-use proposes `(description, category, suggested_due_date, evidence_email_ids[])`.
- INSERT into `recurring_task_suggestions` (V58).
- Telegram digest Mon 10:00.
- Mission Control "Suggested recurring tasks" card with Accept/Dismiss buttons.

**V58**:
```sql
CREATE TABLE recurring_task_suggestions (
  id SERIAL PRIMARY KEY,
  description TEXT NOT NULL,
  category TEXT,
  suggested_due_date DATE,
  evidence_email_ids JSONB,
  ai_confidence NUMERIC(3,2),
  status TEXT DEFAULT 'proposed'
         CHECK (status IN ('proposed','accepted','dismissed','done')),
  created_at TIMESTAMPTZ DEFAULT now(),
  reviewed_at TIMESTAMPTZ
);
```

**Acceptance**:
- Test run on a 14-day window 52 weeks back surfaces ≥3 plausible suggestions.
- Mission Control card shows them with one-click accept/dismiss.

### Track 2 — Reviews monitor (alerts only, no drafts) (~1.5h)

Per Jo: he wants to reply manually, but wants to know within an hour (ideally) of a new review landing.

**Hourly cron `u47-reviews-monitor.sh`**:
- **TripAdvisor**: public review page scrape via Playwright. No login. Read-only. Idempotent on TA review_id.
- **Google**: Business Profile API on admin@malthousetintagel.com. INSERT into `guest_reviews` (existing table from U39).
- Both stamp `status='new'` so subsequent code can pick them up.
- **Telegram on each new review**: emoji-coded by rating (⭐⭐⭐⭐⭐ vs ⭐), title, first 120 chars of body, deep-link to platform's response UI.

**U39 drafter `u39-review-drafter.sh` cron disabled** — leave the script in place but remove the `*/10` cron entry. (Replies stay manual.)

**Mission Control card**: "Unanswered reviews" — counts `guest_reviews WHERE status='new' AND NOT replied` with a list of the latest 5 + click-through to platform.

**Acceptance**:
- Hourly cron pulls TA + Google reviews into `guest_reviews`.
- Telegram fires within minutes of a new review.
- Drafter no longer creates rows in `review_drafts`.
- Mission Control shows the unanswered count.

### Track 3 — Dashboard staff/family password split (~2h)

Caddy basic-auth on two paths. Interim until Authelia/Tailscale-FQDN cert lands (U48 in-person).

**Caddy config addition** (`/home_ai/config/caddy/Caddyfile`):
```caddy
@staff path /staff/* /api/staff/*
handle @staff {
  basicauth { staff $BCRYPT_HASH_STAFF }
  reverse_proxy homeai-build-dashboard:8090
}
@family path /family/* /api/family/*
handle @family {
  basicauth { jo $BCRYPT_HASH_JO }
  reverse_proxy homeai-build-dashboard:8090
}
```

Hashes harvested from Vault at Caddy boot:
- `secret/dashboard/staff-bcrypt`
- `secret/dashboard/jo-bcrypt`

Provisioned via `u47-dashboard-creds.sh` (interactive, prompts for plaintext, hashes with `caddy hash-password`, writes to Vault).

**Backend scope discrimination**: build-dashboard reads `X-Forwarded-Path` from Caddy. Routes under `/staff/*` set `app.current_entity='1'` (Malthouse pub) — staff only see pub ops, no AREL properties, no personal/family. `/family/*` keeps `app.current_entity='all'`.

**Static page**: `services/build-dashboard/static/staff-index.html` is a stripped-down Mission Control that omits family/personal cards. The rest of `/staff/*` URLs (e.g. `/staff/economics`, `/staff/workforce`) serve the existing pages with the staff scope auto-applied.

**Acceptance**:
- `curl -I http://100.104.82.53/staff/` → 401 without creds, 200 with.
- Staff page renders zero rows where `entity_id IN (3,4)`.
- Family page unchanged.

### Track 4 — Tanda timesheets sync (~30m)

`workforce_timesheets` is empty — only /api/v2/shifts is being pulled. Wire `/api/v2/timesheets`:

**Script `u47-tanda-timesheets-sync.sh`** (cron 02:25, just after /shifts at 02:15):
- Hits `https://my.workforce.com/api/v2/timesheets?from=YYYY-MM-DD&to=YYYY-MM-DD`.
- Idempotent on `external_id`.
- Logs to `workforce_sync_log`.

After this, `forecast_vs_actual` table on `/workforce` lights up with real variance numbers.

**Acceptance**:
- After first run, `SELECT COUNT(*) FROM workforce_timesheets` > 0.
- `/api/workforce/forecast_vs_actual?days=28` returns non-empty `items`.

### Track 5 — Classifier feedback applier (~1h)

Without this, Jo's ✎fix clicks on Mission Control go into `bot_feedback` and sit there.

**Extend `u44-feedback-applier.sh`** to ALSO process `bot_feedback` rows with `domain='classifier'`:
- Group corrections by `original_class → corrected_class` (e.g. "10 emails Jo reclassified from fyi→invoice from vendor X").
- Sonnet proposes a heuristic update: "add 'invoice number' to the invoice-classification prompt", or a routing rule.
- Writes the proposal to `dreaming_heuristics` (existing table from U36).
- Telegram digest of high-confidence proposals each morning.
- Mark `bot_feedback.applied = true`.

**Acceptance**:
- After Jo ✎fixes some classifier rows on Mission Control, the next morning's run produces ≥1 heuristic proposal that's reasonable.

### Track 6 — Docs (~30m)

- STATUS.md: U47c wrap.
- STRETCH.md: tick §3.35 (classifier review queue) as fully shipped; mark §3.14 (drafter) as dormant per Jo's preference.
- SPEC.md: §7.10 review-scraper auth model documented; §7.14 access split.

## Total ~7.5h

## Anti-scope

- **No review auto-drafts** (Jo replies manually).
- **No SDD migration** — U48.
- **No Wix integration** — U48.
- **No Authelia full forward_auth** — U48 (depends on Tailscale cert + FQDN).
