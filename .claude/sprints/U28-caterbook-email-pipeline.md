# U28 — Caterbook accommodation pipeline (email-driven)

**Decision (2026-05-11):** Caterbook is **NOT scraped via browser**. The
Playwright stub at `/scrape/caterbook-arrivals` is parked — Caterbook emits
a daily "Arrivals and Departures" email with a PDF attachment, which is a
strictly better source: lower fragility, no credentials at runtime, no
captcha/2FA risk, deeper historical reach via Gmail search.

## Inputs

- **Inbox:** `info@malthousetintagel.com`
- **From:** Caterbook system address (filter narrows further on subject)
- **To:** `stay@malthousetintagel.com`
- **Subject:** *contains* `The Olde Malthouse Inn: Arrivals and Departures`
- **Body:** PDF attachment with three tables for the report date:
  - **Arrivals** — guests checking in today
  - **Stayovers** — guests already in residence (no movement today)
  - **Departures** — guests checking out today

## What we want

1. **Dashboard view** (`/caterbook` or extend `/pub`):
   - Today's arrivals (name, room, source channel, total)
   - Today's stayovers (name, room, nights remaining)
   - Today's departures (name, room, total amount)
   - Per-room revenue trend over time (heat map / sparkline)
2. **DB collation:** the canonical artifact is *revenue per room per night*.
   Each booking's stay is broken into nightly slots so trend queries are
   trivial: `SUM(rate_per_night) GROUP BY room, night_date`.
3. **Historical depth:** Gmail search back as far as the inbox holds emails
   matching the filter; ingest each PDF the same way.
4. **Cron:** **07:00 daily** to pick up the previous evening's email.

## Schema (new migration V28)

### `caterbook_email_reports` — one row per email/day
| col | type | notes |
|---|---|---|
| id | bigserial PK | |
| idempotency_key | text unique | `cb_email_{sha256(source_email_id)}` |
| source_email_id | bigint FK emails(id) | the Gmail row |
| report_date | date | the date the report covers (parsed from subject/PDF) |
| arrivals_count | int | |
| stayovers_count | int | |
| departures_count | int | |
| total_revenue | numeric(14,2) | sum of room×nights×rate for that report's rows |
| raw_pdf_path | text | snapshot of the PDF on disk |
| received_at | timestamptz | from emails.received_at |
| entity_id | int default 1 | RLS |

### `caterbook_room_nights` — the headline analytics table
| col | type | notes |
|---|---|---|
| id | bigserial PK | |
| idempotency_key | text unique | `cb_rn_{sha256(room+night_date+guest+booking_ref)}` |
| source_email_id | bigint FK | |
| night_date | date | one row per night occupied |
| room | text | |
| guest_name | text | sanitised — no PII in raw_text |
| source_channel | text | Booking.com / Direct / Agoda / etc. |
| rate_per_night | numeric(10,2) | derived: total ÷ nights |
| nights_in_stay | int | from the booking |
| arrival_date | date | |
| departure_date | date | |
| total_amount | numeric(10,2) | full booking total |
| currency | char(3) default 'GBP' | |
| created_at | timestamptz default now() | |
| entity_id | int default 1 | |
| UNIQUE (room, night_date, guest_name) | | |

### `caterbook_daily_snapshot` — what each day looks like at email time
| col | type | notes |
|---|---|---|
| id | bigserial PK | |
| idempotency_key | text unique | `cb_snap_{report_date}` |
| report_date | date | |
| arrivals | jsonb | list of {room, guest, channel, total, nights, arr, dep} |
| stayovers | jsonb | same shape |
| departures | jsonb | same shape |
| occupancy_pct | numeric(5,2) | (stayovers + arrivals) / total_rooms |
| total_rooms | int | static — Malthouse capacity |
| revenue_in_house | numeric(12,2) | sum of in-house guests' nightly rate |
| created_at | timestamptz default now() | |
| entity_id | int default 1 | |

All three tables: RLS enabled, `entity_isolation` policy matching the
existing pattern. Grants to `homeai_pipeline` (write) and `homeai_readonly`
(read).

## n8n workflow design

### `P6-caterbook-arrivals-departures` (one workflow, idempotent)

```
[Schedule Trigger 07:00 daily]
   │
   ▼
[Gmail Search]
   account: info@malthousetintagel.com
   q: "to:stay@malthousetintagel.com subject:\"The Olde Malthouse Inn: Arrivals and Departures\" newer_than:2d"
   (newer_than:2d for daily runs; backfill workflow uses a wider window)
   │
   ▼
[Loop: for each email]
   ├─ already in caterbook_email_reports by idempotency_key?  → skip
   ├─ fetch the PDF attachment via homeai-google-fetch
   ├─ POST pdf to homeai-pdfplumber  → structured text
   ├─ Code Node: parse three tables (arrivals / stayovers / departures)
   ├─ Code Node: explode each booking into per-night rows
   ├─ Postgres: SET LOCAL app.current_entity='1'
   │   INSERT INTO caterbook_email_reports     ... (one row)
   │   INSERT INTO caterbook_daily_snapshot    ... (one row, jsonb of all three lists)
   │   INSERT INTO caterbook_room_nights       ... (N rows, one per stayed night)
   ├─ HMAC-sign payload, emit `accommodation.received` event
   └─ Audit log row
```

### `P6-caterbook-backfill` (one-shot, manually triggered)

Same workflow but the Gmail search query is `older_than:1d` paginated — pull
every matching email in the inbox, dedupe by idempotency_key. Run from n8n
UI when ready; takes minutes once authored.

## Cron

```
0 7 * * * /home_ai/scripts/u28-caterbook-daily.sh >> /home_ai/logs/u28-caterbook.log 2>&1
```

The script kicks the n8n webhook for the daily workflow.

## Dependencies (already present)

| Dependency | Status |
|---|---|
| Gmail multi-account ingest (homeai-google-fetch) | ✓ live (5 identities per memory) |
| pdfplumber service | ✓ live (used by P2 invoice extractor) |
| n8n + Postgres | ✓ live |
| `emails` table to FK source_email_id | ✓ live |

## Outputs

- `/touchoffice` already exists; **add `/caterbook` page** with arrivals /
  stayovers / departures cards + per-room revenue heatmap powered by
  `caterbook_room_nights`.
- Reuses `/pub` panel patterns; same Alpine.js style as `/touchoffice`.

## Risks / open questions

| Risk | Mitigation |
|---|---|
| PDF layout drift | snapshot every raw PDF; parser regex anchored on column headers + falls back to `requires_human=true` on schema mismatch |
| Guest name PII | only the sanitised version reaches AI prompts; raw_text stays out of the LLM pipeline |
| Multi-night bookings split by date in three different reports | idempotency_key on `(room, night_date, guest)` makes re-INSERTs no-ops |
| Time zone of report_date | parse from the email subject/header; assume Europe/London |
| **Channel labelling** | Caterbook's PDF may say "Booking.com" / "Agoda" / etc. — confirm exact strings from a real PDF before committing the channel-classifier enum |

## Anti-scope

- Browser scraping (paused — `/scrape/caterbook-arrivals` stays as a 501 stub)
- Real-time channel updates (the email is once-a-day)
- Multi-property — Malthouse only for v1
