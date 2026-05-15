# U63 — Phase 2 close + access prep

**Prereqs**: U61 + U62 schema landed.

**Realm**: cross-cutting.

**Remote-doable**: ~70 %. Authelia user-account creation is security-sensitive and stops at "ready for Jo to set the passwords".

## Tracks

### T1 — Tanda timesheet sync
- Existing `u47-tanda-timesheets-sync.sh` is on disk but not on cron. Smoke-test it; install cron daily 02:20 (5 min after shifts pass).
- Backfill last 90 days.
- Acceptance: `SELECT COUNT(*) FROM workforce_timesheets` > 0 after first run; `forecast_vs_actual` view populates.

### T2 — TouchOffice 301-day backfill
- Use existing `u27-touchoffice-backfill.sh`. Pull every (date, site) for the 301 known-miss dates from U61's coverage audit. ~75 min per 30 days × 2 sites.
- Run in background; log to `/home_ai/logs/u63-touchoffice-backfill.log`.
- Re-run coverage audit after; expect missing-day count to drop ≥ 80 %.

### T3 — U38.5 — migrate remaining 5 n8n Anthropic nodes to tool-use
- Nodes: Gmail Haiku Classifier, Invoice P2 Haiku, Nanny P8 Haiku, Report P9 Sonnet, Dreaming n8n. Each needs `format=tool` + `input_schema` swap. Schemas already in `/home_ai/ai_schemas/`.
- Risk: response shape changes from `{message:{content}}` to `{content:[{type:tool_use,input:…}]}`. Each downstream node must read `.input.X` not `.content`. Update sibling Code nodes in same workflow.
- One node at a time, smoke-test after each.

### T4 — Authelia user accounts (PREP ONLY)
- Add 3 user stubs to `/home_ai/security/authelia-v2/users_database.yml` with strong placeholder hashes — Jo to flip passwords on next box visit:
  - `accountant` — group `finance`, realm `work`, sees `/finance` + `/invoices`
  - `pubstaff` — group `pub`, realm `work` (entity=1 only), sees `/pub` + `/touchoffice`
  - `family` — group `home`, realm `family`, sees `/economics` + `/m`
- Document `home_ai.set_realm()` hook for Caddy `forward_auth` → maps `Remote-Groups` to realm. Already in main.py middleware (U52).
- Acceptance: container restarts cleanly, users exist; Jo sets real passwords in person.

### T5 — Mission Control Coverage tile
- `/api/coverage/recent-gaps` already exists (U61 T6). Add the tile to `index.html` ribbon area: show top-5 missing dates × feeds, click-through to `/coverage` (new small page).

## Acceptance
- `workforce_timesheets` populated; `forecast_vs_actual` view non-empty.
- TouchOffice `feed_coverage` missing-count drops materially.
- 1–5 Anthropic n8n nodes ship on tool-use (whichever sequence is safe).
- Authelia container starts with the new users.
- `/coverage` page renders.
