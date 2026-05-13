# U46 — Data integrity + daily drivers (highest priority)

**Why now**: TouchOffice sales numbers are wrong by ~66% on at least 12/5/26 (café £352.40 actual vs £134.65 scraped; pub £3,364.26 vs £1,151.71). That single inaccuracy invalidates every downstream metric in U33-U45: labour %, GP %, occupancy ratios, anomaly detection baselines. Has to be fix #1.

Plus four other items Jo flagged: rolling-weekly GP view, local weather as a forecasting/staffing input, an Email To-Do block on Mission Control, and a verification of AI token cost accounting.

**Remote-doable**: ~95%. TouchOffice fix likely a Playwright scraper bug — solvable from the box-side. SDD migration is U48 territory.

## Inputs (clarifying questions for Jo — answer when convenient, don't block sprint start)

- **TouchOffice 12/5/26 figures** — are the actual £352.40 / £3,364.26 NET or GROSS? (Our scrape captures both NET sales and GROSS sales; need to know which we're under-reading.)
- **Tanda as sales backup** — Tanda's "Live Sales" / "Sales Comparison" feature connects to POS systems. Do we have that enabled on the Tanda account? If yes, we could pull sales via the Tanda API as a redundant source. Will probe.
- **Weather API preference** — OpenWeatherMap (free 1000 calls/day), Met Office DataPoint (free, UK-specific, no key needed), or weatherapi.com (free 1M/month)? Recommendation: Met Office (UK-specific, no auth, accurate for Cornwall).

## Tracks

### Track 1 — TouchOffice scraping fix + back-correction (~2 hr)

The scraper is Playwright-based (`u27-touchoffice-daily.sh`) running at 03:00 + `u33-touchoffice-realtime.sh` every 10 min. Both write to `touchoffice_fixed_totals`.

**Diagnosis**:
- Pull a fresh scrape of 12/5/26 manually; compare each label/value pair against the actual EPoS UI Jo verifies
- Check if the discrepancy is consistent (e.g. always missing a specific category, always halving, always 1 site only) or random
- Inspect `touchoffice_scrapes.snapshot_html_path` for 12/5/26 — read the actual HTML the scraper saw

Most likely failure modes:
1. **Wrong widget selected** — TouchOffice has multiple "totals" panels; scraper may be reading "previous day" or a filtered subset.
2. **Site mismatch** — running totals for malthouse end up in sandwich rows or vice versa.
3. **Time-window drift** — scraper reads a partial-day view because the EPoS page defaults to "last 1 hour" or "live".
4. **Truncation** — large numbers ((£3,364) being parsed as £3 with rest stripped.

**Fix**: patch the Playwright selectors / page navigation. If TouchOffice has changed its UI, may need a small refactor. Per `feedback_working_discipline` Rule 9 (3-attempt cap): if I can't fix in 3 attempts, fall through to Track 1b.

**Track 1b — Tanda as sales source (fallback)**: probe Tanda's `/api/v2/...` for sales endpoints. If accessible: build `u46-tanda-sales-sync.sh`, write to a new `tanda_sales` table, and union into `v_daily_unit_economics` as the canonical source with TouchOffice as a check-only.

**Track 1c — Back-correction**: once the scraper is right, force a re-scrape across the last 90 days. The `touchoffice_scrapes` table records every run; we can replay them or pull historical via TouchOffice's archive view. Compare new values vs old, flag discrepancies, update `touchoffice_fixed_totals`. Telegram summary at end.

**Acceptance**:
- Manual scrape of 12/5/26 returns values within ±£1 of Jo's confirmed actuals.
- Back-correction logs N rows changed out of M total.
- Re-run `/api/economics/overview?days=14` shows new revenue numbers consistent with Jo's recollection for a couple of sampled days.

### Track 2 — Token cost verification (~30 min)

The dashboard shows AI usage cost via the `ai_usage` table. Verify accuracy:

1. Pull last 30 days of `ai_usage` rows. Group by model.
2. Re-compute cost using current Anthropic + Ollama pricing:
   - Haiku 4.5: $1/MTok in, $5/MTok out (cache-read = 10% of in cost)
   - Sonnet 4.6: $3/MTok in, $15/MTok out (cache-read = $0.30/MTok)
   - Opus 4.7: $15/MTok in, $75/MTok out (cache-read = $1.50/MTok)
   - Ollama (local): £0 cost, but track £-saved at the cloud Haiku equivalent
3. Compare to whatever the dashboard's spend tile reports.
4. If discrepancy: fix the cost calc (likely under-counting cache, or missing cache_creation_input_tokens).

Surface result in chat as a one-line "actual vs reported" check.

**Acceptance**:
- `ai_usage` total for last 30d matches dashboard `/api/spend` to within 5%.
- Anthropic Console (manual cross-check by Jo, ~2 min) matches our calc to within 5%.

### Track 3 — Rolling weekly GP view (~1 hr)

Extends U44's `v_daily_gp` to roll over date ranges, not just daily snapshots.

New view `v_weekly_gp_rolling`: for any 7-day window, compute:
- Cafe GP = (sandwich_net − cafe_cost) / sandwich_net
- Food GP = (pub_food_proxy − dry_cost) / pub_food_proxy
- Wet GP  = (pub_drink_proxy − wet_cost) / pub_drink_proxy
- **Overall GP** = (total_revenue − all_costs) / total_revenue
- All_costs = wet + dry + cafe + overhead_cost (head office)

Endpoint `/api/gp/rolling?date_from=&date_to=&buckets=...` returns the calc for any date range, not fixed to 7d.

Add a "Rolling GP" panel to the invoices page below the existing daily strip.

**Future-proofing note**: when ice-cream shop overhead is separated out, just add another bucket; the view structure stays.

**Acceptance**:
- View returns sensible numbers for a window with both invoices and sales.
- Endpoint accepts arbitrary date ranges from the U45 date-picker.
- New panel renders on invoices page.

### Track 4 — Weather integration (~1.5 hr)

Met Office DataPoint API — UK-specific, no auth needed (free reg key but optional for some endpoints). Or fallback to OpenWeatherMap free.

Postcode PL34 0DA → lat 50.6620, lon -4.7530 (Tintagel).

**Schema (V52)**:
```sql
CREATE TABLE weather_daily (
  id SERIAL PRIMARY KEY,
  observation_date DATE UNIQUE,
  hours_sunshine NUMERIC(4,1),
  rain_mm NUMERIC(6,2),
  avg_temp_c NUMERIC(4,1),
  peak_temp_c NUMERIC(4,1),
  min_temp_c NUMERIC(4,1),
  max_wind_mph INT,
  source TEXT,
  raw_payload JSONB,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE weather_forecast (
  id SERIAL PRIMARY KEY,
  forecast_date DATE,
  fetched_at TIMESTAMPTZ DEFAULT now(),
  rain_mm NUMERIC(6,2),
  max_temp_c NUMERIC(4,1),
  max_wind_mph INT,
  alert_categories TEXT[],  -- ['heavy_rain', 'high_wind', 'heat_over_20']
  raw_payload JSONB
);
```

**Scripts**:
- `u46-weather-daily.sh` (cron 07:30 daily) — fetches yesterday's actuals + next-5-days forecast
- Telegram alert immediately on any forecast day with >10mm rain, >35mph wind, or >20°C max temp

**Endpoint**:
- `/api/weather/recent?days=30` — daily actuals
- `/api/weather/forecast` — next 5 days
- `/api/weather/sales_correlation?days=90` — joins to `v_daily_unit_economics` for forecasting input

**Mission Control widget**: small "5-day weather + alerts" tile.

**Acceptance**:
- 30 days of historical weather backfilled.
- 5-day forecast updates daily.
- Synthetic test alert fires on a forecast day with rain >10mm.

### Track 5 — Email To-Do scaffold (~1.5 hr)

Foundation for the U47 full email-task extractor — schema + UI tile + a placeholder Sonnet job that runs against recent emails.

**Schema (V53)**:
```sql
CREATE TABLE email_tasks (
  id SERIAL PRIMARY KEY,
  email_id BIGINT REFERENCES emails(id),
  task_type TEXT CHECK (task_type IN ('action', 'complaint', 'follow_up', 'rsvp', 'other')),
  description TEXT,
  severity INT CHECK (severity BETWEEN 1 AND 5),
  detected_at TIMESTAMPTZ DEFAULT now(),
  due_date DATE,
  resolved_at TIMESTAMPTZ,
  resolution_notes TEXT,
  ai_model TEXT,
  ai_confidence NUMERIC(3,2)
);

-- Urgency = age_days × severity. Computed in view.
CREATE VIEW v_email_tasks_open AS
SELECT t.*, e.subject, e.from_address,
       EXTRACT(EPOCH FROM (now() - t.detected_at))/86400 AS age_days,
       (EXTRACT(EPOCH FROM (now() - t.detected_at))/86400) * t.severity AS urgency_score
  FROM email_tasks t
  JOIN emails e ON e.id = t.email_id
 WHERE t.resolved_at IS NULL
 ORDER BY urgency_score DESC;
```

**Script `u46-email-task-extractor.sh`** (cron */15 min, cost-capped):
- Reads recent classified emails (last 24h, ai_category IN ('action-required', 'school-medical', 'property', 'pub'))
- Sonnet tool-use classifies each into 0-3 task records with type + severity (1=trivial, 3=normal, 5=urgent) + description
- INSERT into `email_tasks` (idempotent on email_id)

**Endpoint** `/api/email_tasks` → returns top 10 by urgency_score.

**Mission Control tile**: small "Email To-Do" block with top 3 by urgency, click → expand list.

**Acceptance**:
- Sonnet extracts at least 1 task from a synthetic "your tax return is due" email.
- Tile renders on Mission Control.
- Resolution: `POST /api/email_tasks/{id}/resolve {notes}`.

## Total

~6 hr autonomous. No Jo input gates other than the clarifying Qs at top (which don't block sprint start).

## Anti-scope

- **No SDD migration** — U48 (needs sudo).
- **No Wix integration** — U48.
- **No password-protected dashboards** — U47.
- **No 52-week review** — U47 (depends on email task extractor maturing).
- **No real review scraping** — U47 (uses Track 5 + Jo-supplied login accounts).
- **No new pipelines outside the listed tracks.**

## Files in scope

- `/home_ai/scripts/u27-touchoffice-daily.sh` — patch
- `/home_ai/scripts/u33-touchoffice-realtime.sh` — patch likewise if needed
- `/home_ai/postgres/migrations/V52__weather.sql` — NEW
- `/home_ai/postgres/migrations/V53__email_tasks.sql` — NEW
- `/home_ai/postgres/migrations/V54__rolling_gp.sql` — NEW (or fold into V53)
- `/home_ai/scripts/u46-touchoffice-backfill.sh` — NEW
- `/home_ai/scripts/u46-weather-daily.sh` — NEW
- `/home_ai/scripts/u46-email-task-extractor.sh` — NEW
- `/home_ai/services/build-dashboard/main.py` — 5 new endpoints
- `/home_ai/services/build-dashboard/static/index.html` — Email To-Do + Weather tiles
- `/home_ai/services/build-dashboard/static/invoices.html` — Rolling GP panel
