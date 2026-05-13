# U47 — Email intelligence + access split

**Prereqs**: U46 ships (TouchOffice integrity + email_tasks schema).

**Remote-doable**: 100%.

## Tracks

### Track 1 — 52-week recurring task review (~2 hr)

Weekly Sonnet job that mines emails from 52 weeks ago + the past 4 quarters for **periodic patterns** Jo should renew/repeat now.

Examples: insurance renewals, licence renewals, accountant year-end, supplier contract reviews, school holiday rotas, summer/winter menu changes, business rates, water-rates direct-debit checks.

**Script `u47-recurring-task-suggester.sh`** (cron weekly Mon 09:00):
- Pulls emails from `emails` table where `received_at BETWEEN now()-372d AND now()-358d` (the same week one year ago, plus a small jitter).
- Plus optionally last 4 same-weeks-of-quarter for shorter cycles.
- Sonnet tool-use proposes: `(task_description, suggested_due_date, category, evidence_email_ids[])`.
- INSERT into `recurring_task_suggestions` table (NEW V55).
- Telegram digest of new suggestions on Monday 10:00.

**Schema V55**:
```sql
CREATE TABLE recurring_task_suggestions (
  id SERIAL PRIMARY KEY,
  description TEXT,
  category TEXT,
  suggested_due_date DATE,
  evidence_email_ids JSONB,
  ai_confidence NUMERIC(3,2),
  status TEXT DEFAULT 'proposed' CHECK (status IN ('proposed','accepted','dismissed','done')),
  created_at TIMESTAMPTZ DEFAULT now(),
  reviewed_at TIMESTAMPTZ
);
```

**Endpoint** `/api/recurring_suggestions` and Action Queue card on Mission Control.

**Acceptance**:
- Test run pulls emails from a 14-day window 52 weeks back.
- At least 3 reasonable suggestions on first real run (insurance/licences/etc).
- Suggestions surface on dashboard with Accept/Dismiss buttons.

### Track 2 — Reviews scraper (Playwright) (~3 hr)

Now we know the login accounts (TripAdvisor = info@malthousetintagel.com Gmail; Google reviews = admin@malthousetintagel.com Gmail), U39's stub becomes real.

**Strategy**:
- New service `services/review-scraper/` (extends existing Playwright container or runs alongside).
- For Google Reviews: use the Google Business Profile API where possible (needs OAuth on admin@). API path is more robust than scraping.
- For TripAdvisor: Playwright with the info@ Google login. Anti-bot is real; use real UA, randomised delays 2-5s.
- Both INSERT into `guest_reviews` (existing table from U39).
- The drafter (`u39-review-drafter.sh`) already runs `*/10` and picks up `status='new'` rows.

**Scripts**:
- `u47-google-reviews-sync.sh` — weekly cron Mon 09:30. Tries Google API first; falls back to OAuth-protected Playwright if API path unavailable.
- `u47-tripadvisor-sync.sh` — weekly cron Mon 09:35. Playwright + info@ Gmail OAuth login flow.

**Acceptance**:
- 5+ historical reviews from Google + TripAdvisor for the Malthouse appear in `guest_reviews` after first run.
- Sandwich-shop reviews ditto.
- Drafter runs against them and produces hospitality-tone responses.

### Track 3 — Dashboard password split: staff vs family (~2 hr)

Two separate dashboard front-ends, password-protected, until full Authelia lands.

**Approach**: Caddy basic-auth on two paths.

- `/staff/` → routes to current build-dashboard but mounts an alternate `index.html` showing only operational data: rota, sales, GP, weather, reviews, invoices (no personal/family data). Different `static/staff-index.html` file; route serves this when URL is `/staff/`.
- `/family/` → current full Mission Control with everything (personal alerts, kids, etc).

Caddy config:
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

Vault secrets:
- `secret/dashboard/staff-bcrypt` — bcrypt hash of the staff password
- `secret/dashboard/jo-bcrypt` — bcrypt hash of Jo's password
- Provisioned via `u47-dashboard-creds.sh` (interactive, prompts for plaintext, writes hash to Vault)

**Endpoint discrimination**: backend serves the same data; the staff page just filters what's rendered (no personal entity_id=3/4 data). RLS on the staff API: `SET app.current_entity = '1,2'` (entities 1+2 only).

**Acceptance**:
- `curl -I http://100.104.82.53/staff/` returns 401; with credentials returns 200.
- Staff page does not render any data with entity_id IN (3, 4).
- Family page renders everything (current behaviour).

### Track 4 — Update STATUS/STRETCH/SPEC docs (~30 min)

- STATUS.md: U46+U47 wraps, current state
- STRETCH.md: archived items moved to "shipped"; new entries for U48 candidates
- SPEC.md: §7.10 review scraper auth model documented; §7.11 weather-as-forecast-input

## Total

~7.5 hr autonomous.

## Anti-scope

- **No SDD migration** — U48.
- **No Wix integration** — U48.
- **No Authelia full forward_auth** — U48 (still depends on tailscale cert + FQDN).
