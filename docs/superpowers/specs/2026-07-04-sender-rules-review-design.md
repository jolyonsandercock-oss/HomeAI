# Sender Rules Review — design (2026-07-04)

**Goal:** A dashboard page (linked from Tasks) to review the auto-derived
invoice-sender rules — whitelist real senders flagged for review, deny genuine
non-invoice senders, and see/reverse any auto-decision — with changes taking
effect immediately.

**Context:** `invoice_sender_rules` (V291) holds deny/allow/review rules;
`u294-derive-sender-denylist.sh` (daily) auto-derives them from 90d evidence and
rebuilds `static_context['invoice.sender_denylist']`, which the gmail-ingest
classifier reads (u293/u295). Today the `review` tier (PDF-bearing, 0-captured
senders — possible real suppliers with broken capture) is only visible via SQL.

## Architecture

Mirrors the existing `/counterparty-review` page pattern (dedicated static HTML
+ FastAPI queue/action endpoints + shared db helpers with V288 realm context).

### DB (V292)
`home_ai.rebuild_sender_denylist()` — plpgsql function that regenerates
`static_context['invoice.sender_denylist']` from `invoice_sender_rules`
(action='deny' minus allow overrides), returning the new counts. **Single source
of truth**: both `u294` and the dashboard action endpoints call it, so the
denylist can never drift between cron and UI. `u294`'s inline rebuild SQL is
replaced by a call to this function.

### Backend (main.py)
- `GET /sender-rules-review` → `FileResponse(sender-rules-review.html)`.
- `GET /api/sender-rules/queue` → `{counts:{deny,allow,review}, review:[...], rules:[...]}`.
  - `review`: `action='review'` rows + evidence + up to 3 recent email subjects
    from that sender (from `emails`, realm-scoped) so the reviewer can judge.
  - `rules`: all rows (deny/allow/review) with sender, match_type, action,
    source, reason, evidence, updated_at — for the collapsible "All rules" view.
- `POST /api/sender-rules/set` `{sender, match_type in (address,domain), action in (allow,deny)}`
  → upsert `source='manual'`, reason `'manual via dashboard'`; call
  `rebuild_sender_denylist()`; audit_log. Returns `{ok, counts}`.
- `POST /api/sender-rules/delete` `{sender, match_type}` → delete row; rebuild;
  audit_log. (Used for Remove / dismiss.)
- Validation: reject unknown action/match_type with 400; `sender` lowercased,
  length-capped. Every mutation writes `audit_log(pipeline='sender_rules_review',
  action, ai_parsed={sender,match_type,action,by})`.

### Frontend (static/sender-rules-review.html)
Styled like counterparty-review.html (dashboard theme, no external CDN).
- Header: title + counts ("N to review · D denied · A allowed").
- **Needs review** (primary): one card per `review` sender — evidence line
  (N classified / M with PDF / 0 captured, window) + up to 3 sample subjects +
  buttons **Whitelist** (green → set allow) and **Deny** (red → set deny).
  Empty state: "Nothing to review — auto-rules are handling it." Deferring = no
  action; stays in the queue.
- **All rules** (collapsible, default collapsed): table grouped by action, with
  source + reason, and inline **Whitelist**/**Deny** (flip) and **Remove**.
  Lets the owner see and reverse any auto-deny.
- After each action: toast/inline confirmation + refresh; errors surfaced (no
  silent failure).

### Tasks page
Add a card linking to `/sender-rules-review` with a count badge = number of
`action='review'` rows (fetched from the queue endpoint or a tiny count route).

## Data flow
classifier reads `static_context['invoice.sender_denylist']` ← rebuilt by
`rebuild_sender_denylist()` ← called by both `u294` (daily) and the dashboard
POST actions (immediate). Rules table is the system of record; static_context is
the derived cache the classifier reads.

## Error handling
- Endpoint input validation → 400 with message.
- POST actions wrapped; DB error → 400 JSON, no partial state (single txn:
  upsert + rebuild together).
- Frontend: fetch failures show an error banner, not a blank page.

## Testing
- `GET /api/sender-rules/queue` (X-Realm: all) returns review items + rules + counts.
- `POST set {allow}` on a review sender → row becomes allow, `rebuild` runs,
  `static_context` denylist no longer contains it; deployed classifier node code
  (mock harness, as used for u295) confirms that sender now classifies invoice.
- `POST set {deny}` on a fresh sender → appears in denylist; classifier downgrades.
- `POST delete` → row gone, denylist rebuilt.
- Page loads (200) and renders the queue.
- Re-run u294 after a manual allow → the allow is respected (not re-derived to deny).

## YAGNI (explicitly out)
- No free-text "add arbitrary rule" box (auto-derivation + review covers real
  senders; rare manual adds stay in SQL).
- No bulk-select / pagination (queue is small, ~10 items).
- No per-rule edit of evidence (evidence is derived, not user-owned).
