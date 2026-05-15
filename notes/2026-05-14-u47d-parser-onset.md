# U47d Track 2 — Parser-onset 2026-05-13 01:30 (observed, not fixed)

## Heuristics that flagged it

| id | scope                  | observation                                                                 |
|----|------------------------|-----------------------------------------------------------------------------|
| 3  | p5-epos                | 96 'unparseable' over 24h, same first_seen as caterbook                     |
| 4  | p6-caterbook           | 1,424 consecutive 'unparseable' over 24h, pipeline fully broken             |
| 5  | p5-epos                | 96 consecutive 'unparseable', 100% failure, same first_seen                 |
| 6  | p6b-caterbook-bookings | 96 consecutive 'unparseable', same first_seen                               |
| 8  | system-wide            | All three share first_seen 2026-05-13T01:30; no LLM fallback                |

All five propose injecting a `qwen2.5:7b` format-sniff fallback into the parsers.

## What the data actually shows (2026-05-14)

| Table                      | State                                                            |
|----------------------------|------------------------------------------------------------------|
| `caterbook_email_reports`  | 7/7 days last week populated; 2026-05-13 has 3a/2s/5d row        |
| `touchoffice_fixed_totals` | Both sites populated 5/8–5/13; 5/14 Malthouse already in         |
| `dead_letter`              | 0 rows for caterbook/epos/touchoffice in last 7 days             |
| `events` typed `*.unparseable` | 0 rows in last 7 days                                        |

## Diagnosis

The Dreaming heuristics were looking at **n8n's `ai_usage` table** which tracks
deterministic n8n rule-based parser nodes (`caterbook_parser`,
`caterbook_bookings_parser`, `epos_parser`). Those workflows are a separate
ingest path from my U27/U28 builds:

- **U27 path (TouchOffice browser scrape)**: `homeai-playwright` →
  `touchoffice_fixed_totals` directly. No `epos_parser` in this path.
- **U28 path (Caterbook PDF email)**: `homeai-playwright` → `pdfplumber` →
  `caterbook_email_reports` directly. No `caterbook_parser` n8n node either.

The n8n workflows that *do* call `caterbook_parser` / `epos_parser` are the
older legacy parsers (pre-U27/U28) that consume the same raw inputs via
different intermediaries. When their input shape changed on 2026-05-13 01:30,
they began returning `unparseable` repeatedly, but because the U27/U28 paths
write *directly* to the canonical tables, the dashboards and digests don't
notice — they read from the canonical tables, not the n8n parser outputs.

## Recommended action

1. **Leave the LLM-fallback proposal on the shelf.** It's overkill for what
   has already become a defunct ingest path. The current U27/U28 paths are
   working, so no fallback is needed to keep daily numbers correct.
2. **Disable the legacy n8n parser workflows** (`caterbook_parser`,
   `caterbook_bookings_parser`, `epos_parser`) to stop the unparseable noise
   — they're now duplicates of the U27/U28 ingest paths. Deferred to U47e or
   whenever someone has 30 min in n8n.
3. Mark the five heuristics `status='observed'` with `reviewed_by='claude-u47d'`
   so Dreaming doesn't keep re-flagging them in future passes.

## Open question

If the legacy n8n parsers were ever the canonical source for some downstream
view we still depend on (e.g. an obsolete `epos_daily` table), disabling them
would break that view. Quick audit before disabling: `\d epos_daily` +
`SELECT MAX(report_date) FROM epos_daily` — if `epos_daily` is fresh and
not derivable from `touchoffice_fixed_totals`, the legacy parsers stay.

Logged 2026-05-14 by U47d Track 2.
