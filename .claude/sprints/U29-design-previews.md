# U29 design previews — invoice listing, Telegram-in, jolyboxbot

Three sketches the user asked for. None are built yet — these define the
shape so the build is mechanical when scheduled.

---

## 1. Vendor invoice listing schema

**Observation from the last 30 days of `info@malthousetintagel.com`:**

Among ~31 emails with the word "invoice" / "remittance" / "bill" /
"statement" in the subject:

| Vendor | # | Type |
|---|---|---|
| forestproduce.com | 15 | weekly food supplier |
| bidfreshfinance.co.uk | 3 | food supplier |
| theaccessgroup.com | 2 | software (likely Xero or PMS adjacent) |
| post.xero.com | 2 | Xero system mail |
| malthousetintagel.com | 2 | internal |
| encounterwalkingholidays.com | 2 | booking partner |
| wolflaundry.co.uk, designmynight.com, bartlett.co.uk, google.com, … | 1 each | mixed |

The existing `invoices` table (Pipeline 2) is heavyweight — pdfplumber +
Haiku extract every line into a structured row. That's right for invoices
we want to **match against Xero**, but most of the mail above just needs
to be **listed** for human triage: who, when, how much, paid yet?

**Proposed: `vendor_invoice_inbox` — a lighter triage layer.**

```sql
CREATE TABLE vendor_invoice_inbox (
  id              BIGSERIAL PRIMARY KEY,
  idempotency_key TEXT NOT NULL UNIQUE,        -- 'vi_<gmail_msg_id>'
  source_email_id TEXT NOT NULL UNIQUE,        -- Gmail message id
  account         TEXT NOT NULL,               -- which google-fetch account saw it
  entity_id       INT NOT NULL DEFAULT 1,

  -- Vendor identification (resolved later — domain is the cheap initial bucket)
  vendor_domain   TEXT NOT NULL,
  vendor_name     TEXT,                         -- enriched (e.g. 'Forest Produce')
  vendor_id       INT,                          -- FK to a future vendors table

  subject         TEXT NOT NULL,
  received_at     TIMESTAMPTZ NOT NULL,

  -- Best-effort amount/date extraction from subject/body (NULL if unknown)
  amount_seen     NUMERIC(12,2),
  currency        CHAR(3) DEFAULT 'GBP',
  invoice_date    DATE,
  due_date        DATE,

  attachment_count INT DEFAULT 0,
  first_attachment_path TEXT,                   -- /home_ai/storage/invoices/<id>.pdf
  has_pdf         BOOLEAN DEFAULT FALSE,

  -- Triage state
  status          TEXT NOT NULL DEFAULT 'new'
                  CHECK (status IN ('new','extracted','paid','disputed','ignored','duplicate')),

  -- When Pipeline 2 fully processes, this links the canonical row.
  linked_invoice_id BIGINT REFERENCES invoices(id),

  notes           TEXT,
  ingested_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_vii_status_received ON vendor_invoice_inbox (status, received_at DESC);
CREATE INDEX idx_vii_vendor ON vendor_invoice_inbox (vendor_domain, received_at DESC);
```

**Companion view for the dashboard:**

```sql
CREATE VIEW vendor_invoice_summary AS
SELECT vendor_domain,
       COUNT(*) AS n,
       COUNT(*) FILTER (WHERE status='new')     AS pending,
       COUNT(*) FILTER (WHERE status='paid')    AS paid,
       SUM(amount_seen) FILTER (WHERE amount_seen IS NOT NULL) AS total_seen,
       MIN(received_at) AS oldest, MAX(received_at) AS newest
FROM vendor_invoice_inbox
WHERE received_at > CURRENT_DATE - INTERVAL '90 days'
GROUP BY vendor_domain;
```

**The dashboard view:** `/invoices` page listing rows by `status='new'`,
grouped by vendor, with a click-to-mark-paid action and link to the
linked `invoices` row when Pipeline 2 has enriched it.

**Ingest:** an n8n workflow (or a small batch script) that polls Gmail
across all accounts for any new mail whose vendor_domain isn't on a
known "noise" list and INSERTs a row. P2 then picks up the high-priority
ones (those with PDFs ≥ £100, say) for full extraction.

**Why not a single table:** keeping the lightweight triage rows separate
from the AI-extracted line-by-line `invoices` table means we can show
"you have 14 unpaid bills" at-a-glance without waiting for Haiku to
finish, and we can ignore vendor noise (Booking.com, system mail) without
polluting the canonical invoice store.

---

## 2. Telegram → Claude instruction channel

**Goal:** the user types a message in Telegram → it lands somewhere I can
read at session start.

**Why this is non-trivial:** I (Claude Code) only run when invoked. There's
no live process listening for instructions. So the bot has to *persist*
the incoming message, and I have to *check* on session start.

**Design:**

```
[Telegram message]
   ↓
[Telegram Bot (commands) — existing n8n workflow, polling every minute]
   ↓ filter: from authorised chat_id only (anti-spoof)
[INSERT INTO instructions queue table]

CREATE TABLE bot_instructions (
  id             BIGSERIAL PRIMARY KEY,
  source         TEXT NOT NULL,        -- 'telegram' | 'email' | 'manual'
  source_id      TEXT,                  -- telegram message id / gmail msg id
  from_user      TEXT NOT NULL,         -- chat_id or email
  received_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  raw_text       TEXT NOT NULL,
  status         TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','triaged','done','rejected')),
  triage_summary TEXT,                  -- short hint of what it asks for
  picked_up_at   TIMESTAMPTZ,
  picked_up_by   TEXT,                  -- which Claude session
  resolution     TEXT,
  resolved_at    TIMESTAMPTZ,
  entity_id      INT NOT NULL DEFAULT 3
);
```

**My side (Claude Code session-start hook or memory pointer):**

Add a memory entry that says: "On session start, check bot_instructions
WHERE status='pending' ORDER BY received_at — if any, surface them to
the user first thing."

Or simpler — a `start.sh`-style command `homeai-inbox` that prints any
pending instructions before I begin work each session. The user sees
them too, so context is shared.

**Reply path:** after I action an instruction, n8n sends a Telegram reply
confirming "done — <one-line resolution>". Optionally also writes back
to the email thread if the instruction came in by email.

**Build cost:** ~45 min in U30 (after U29 lays down the Vault creds).

---

## 3. jolyboxbot@gmail.com workflow

**Idea:** a dedicated bot identity for *outbound* (digests, reports,
on-demand asks like "here's last week's takings") and *inbound* (a place
to forward anything to and have it triaged).

**Outbound roles**

| Role | Trigger | What it sends |
|---|---|---|
| Daily digest | P10, 21:00 | the rolled-up day — takings, occupancy, alerts |
| Weekly retrospective | Sunday 09:00 | week's numbers + week ahead's bookings |
| On-demand snapshot | Telegram `/snap` command | current dashboard state in HTML email |
| Sprint summary | end of each sprint | the email I just sent you, automated |
| Anomaly nudge | within minutes of a flagged event | "Sandwich Bar shows £0 today — is the till on?" |

**Inbound roles**

| Role | How |
|---|---|
| Forward triage | User forwards anything to jolyboxbot@gmail.com → bot reads, classifies, INSERTs into a triage queue. Future: forward an invoice PDF → fast-track to P2. |
| Reply-to-instruct | When the bot sends you a digest, you can reply with text — the same instruction-queue path as Telegram. Email is just another `source` value. |
| Forwarded receipts | User forwards a personal receipt → routed to expense capture (Phase 4) |

**Why a dedicated identity (vs. using `info@`):**

- Clear visual separation in your inbox ("this is automated" vs "this is
  business correspondence")
- Easier filter / mute / archive rules
- Lower risk: if the bot account is ever compromised, no business data
  flows through it (no read access to invoice senders, etc.)
- Reply-handling is simpler because we only poll *one* mailbox for the
  instruction loop

**Concrete first uses (low cost, high signal):**

1. **U29 chunk 8 P10 Daily Digest** — already uses the bot via SMTP (now
   that we have creds path planned). Switch to Gmail API send via
   google-fetch `/send/bot` so we don't need SMTP creds at all — saves
   the Vault path `secret/smtp/gmail` entirely.
2. **U30 retro emails** — like the one I just sent.
3. **U30 Telegram instruction confirmations** — bot CCs the email thread
   when it actions a Telegram command, so you have an audit trail.

**Build cost:** the `/send/bot` endpoint is already live (added in this
session — sent the U27/U28 retro email through it). The instruction loop
is the work — see §2.

---

## Where this goes

- The invoice schema (§1) is a queued chunk for **U30 or U31** — it
  depends on real invoices flowing through P2, which depends on P3 Xero
  (U29 chunk 1-2).
- The Telegram instruction channel (§2) is a chunk in **U30** — after
  U29 lands Telegram creds, the n8n workflow modification + new table
  + memory pointer is a 90-min job.
- The jolyboxbot use cases (§3) are progressive — the daily digest move
  to Gmail API is a 30-min refactor we can do in **U29 chunk 8** in
  place of wiring SMTP.
