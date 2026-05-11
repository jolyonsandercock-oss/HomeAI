# Overnight Plan #2 — 12-hour window, four sprints

Theme: frontend creativity + operational value. Build things Jo can actually
look at, not just behind-the-scenes infrastructure.

## Constraints I'm respecting
- google-fetch still down (will restore on ./start.sh). Ingestion paused, but
  all dashboards/UIs can read from the existing DB just fine.
- No self-modify of `~/.claude/settings.json`
- No sudo / Vault restart / root file writes
- No GitHub remotes pushed to
- Telegram fallback through `notify-bridge-v1` keeps heartbeat live

## Sprints

### U18 — Pub Live Operations Board  (frontend, ~3h)
A pub-side dashboard Jo can put on a screen behind the bar or pop open on a
tablet. NOT the build-dashboard (that's the developer view) — this is the
**operations** view.

What it shows:
- Today's pub revenue: EPoS gross + covers, accommodation occupancy + revenue
- This week's bookings as a calendar strip — colour-coded by source channel
- Today's arrivals + tomorrow's departures (airport-gate style)
- Top KPIs as big numbers with sparkline trends (last 14 days)
- Live auto-refresh every 60s, subtle update animation
- Dark theme matching existing build-dashboard aesthetic

Backend:
- New FastAPI service `homeai-pub-board` on port 8094
- Reads epos_daily, accommodation_daily, accommodation_bookings
- Single `/api/snapshot` endpoint serves the full payload
- Static `index.html` with Alpine.js + Tailwind CDN

Plumbing:
- Add to docker-compose.yml
- Caddy route `/pub` → homeai-pub-board:8094
- u18-selftest.sh checks: container up, /healthz green, snapshot has keys

### U19 — Telegram Bot Expansion  (backend, ~2h)
The current bot handles /digest /queue /help. Add operationally useful
commands so Jo can check things from his phone without opening the UI.

New commands:
- `/book` — today's confirmed bookings + tomorrow's arrivals
- `/epos` — today's gross, covers, ADR vs 7-day avg
- `/invoices` — invoices needing review (last 7 days)
- `/dl` — open dead letters with brief context
- `/pause` — flip system.state to paused (was advertised in /help but NOT yet wired)
- `/resume` — flip back to running
- `/sweep` — manually trigger dead-letter-sweeper-v1 once

Refactor:
- Existing dispatch is inline in a JS Code node. Split into a small command
  registry pattern so adding commands stops being a chore.
- Add a `command_log` table so we can audit who did what via the bot (defensive
  for the destructive /pause and /resume).

V26 migration: command_log

### U20 — Dead Letter Forensics UI  (frontend, ~3h)
We hit dead-letter false positives this session. The sweeper auto-resolves the
obvious cases. For the rest, Jo needs a quick way to look at one, understand
why it failed, and resolve it with a note.

UI:
- New page at Caddy `/forensics`
- Table of unresolved DLs with: event_type, pipeline, age, retry count, the
  event payload's most useful field (gmail_message_id / supplier / etc.)
- Click row → expand to full payload + linked event chain (parent/children) +
  whether downstream rows exist + last audit_log entries
- Buttons: "Resolve as false-positive (downstream OK)" • "Mark for human review"
  • "Re-enqueue (set status=pending)"
- Server-side endpoints in the same `homeai-pub-board` service (saves a
  container — same shape, different path)

### U21 — SearXNG self-hosted search  (infra stretch, ~1h)
Stretch-doc item 3.6. Pure infrastructure win — Jo gets a private search
engine routable through Caddy at `/search`, no API key, no telemetry.

- Add `searxng/searxng` to docker-compose, pinned version
- Caddy route `/search`
- u21-selftest: container up + a test query returns >0 results

## Anti-scope (deliberately not doing)
- LoRA / Colab work (needs GPU time + careful eval, not for 12h overnight)
- Storyblok (Phase 5 — needs design decisions)
- Calendar/Drive/Sheets (needs google-fetch online + scope decisions)
- Authelia + hooks (already scripted, user-gated)
- Anything that requires restarting Vault / google-fetch

## Time budget
- U18 frontend  : 3h
- U19 bot       : 2h
- U20 forensics : 3h
- U21 searxng   : 1h
- Selftest+close: 1h
- Buffer        : 2h
