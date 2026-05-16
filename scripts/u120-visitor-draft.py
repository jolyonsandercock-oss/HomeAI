"""u120-visitor-draft.py — draft welcome / checkout / review WA messages
from accommodation_bookings + wa_templates.

Three triggers, all checked on every run (run hourly via cron):
  - guest.welcome             checkin = tomorrow, not yet sent
  - guest.checkout_reminder   checkout = today, not yet sent (only if it's
                              still morning, < 10am, else skip)
  - guest.review_nudge_day2   checkout = 2 days ago, not yet sent

Skips any booking without guest_phone. Inserts guest_msg_log row with
UNIQUE(booking_id, template_slug) so reruns are idempotent.
"""
import os, re, json, sys, asyncio, urllib.request
from datetime import date, datetime, time, timedelta
import asyncpg

VAULT_TOKEN = os.environ["VAULT_TOKEN"]
RUN_HOUR    = int(os.environ.get("RUN_HOUR", str(datetime.now().hour)))


def vault(p):
    r = urllib.request.urlopen(urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{p}",
        headers={"X-Vault-Token": VAULT_TOKEN}), timeout=5)
    return json.loads(r.read())["data"]["data"]


REVIEW_URL = "https://g.page/r/CRRTU8RYGFiVEAE/review"  # Google review URL — replace with real


def render(template_body: str, ctx: dict) -> str:
    """Tiny {{var}} substitution. Missing keys leave the placeholder."""
    def repl(m):
        return str(ctx.get(m.group(1).strip(), m.group(0)))
    return re.sub(r"\{\{\s*(\w+)\s*\}\}", repl, template_body)


async def queue(conn, *, booking_id, template_slug, body, phone, label):
    qid = await conn.fetchval("""
        INSERT INTO wa_outbound_queue
          (account, target_jid, target_label, body,
           drafted_by, draft_reason, status, realm)
        VALUES ('pub', $1, $2, $3, 'u120-visitor', $4, 'pending_approval', 'work')
        RETURNING id
    """, phone, label, body, template_slug)
    await conn.execute("""
        INSERT INTO guest_msg_log (booking_id, template_slug, channel, target, outbound_id, realm)
        VALUES ($1, $2, 'wa', $3, $4, 'work')
        ON CONFLICT (booking_id, template_slug) DO NOTHING
    """, booking_id, template_slug, phone, qid)
    return qid


async def main():
    pw = vault("postgres")["password"]
    conn = await asyncpg.connect(f"postgresql://postgres:{pw}@homeai-postgres:5432/homeai")
    await conn.execute("SELECT home_ai.set_realm('owner')")

    today = date.today()
    tomorrow = today + timedelta(days=1)
    two_days_ago = today - timedelta(days=2)

    # Load all relevant templates once
    templates = {r["slug"]: r["body"] for r in await conn.fetch(
        "SELECT slug, body FROM wa_templates WHERE approved_at IS NOT NULL"
    )}

    triggers = []

    # 1. welcome — checkin = tomorrow (covers all morning runs the day before)
    rows = await conn.fetch("""
        SELECT b.id, b.guest_name, b.guest_phone, b.room
          FROM accommodation_bookings b
          LEFT JOIN guest_msg_log l
            ON l.booking_id = b.id AND l.template_slug = 'guest.welcome'
         WHERE b.checkin_date = $1
           AND b.status IN ('confirmed','deposit_paid','paid','active')
           AND b.guest_phone IS NOT NULL
           AND l.id IS NULL
    """, tomorrow)
    for r in rows:
        body = render(templates["guest.welcome"],
                      {"guest_name": r["guest_name"], "room": r["room"]})
        triggers.append((r["id"], "guest.welcome", body,
                         r["guest_phone"], r["guest_name"]))

    # 2. checkout — only run if it's morning (RUN_HOUR < 10)
    if RUN_HOUR < 10:
        rows = await conn.fetch("""
            SELECT b.id, b.guest_name, b.guest_phone
              FROM accommodation_bookings b
              LEFT JOIN guest_msg_log l
                ON l.booking_id = b.id AND l.template_slug = 'guest.checkout_reminder'
             WHERE b.checkout_date = $1
               AND b.status IN ('confirmed','deposit_paid','paid','active')
               AND b.guest_phone IS NOT NULL
               AND l.id IS NULL
        """, today)
        for r in rows:
            body = render(templates["guest.checkout_reminder"],
                          {"guest_name": r["guest_name"]})
            triggers.append((r["id"], "guest.checkout_reminder", body,
                             r["guest_phone"], r["guest_name"]))

    # 3. review nudge — checkout 2 days ago, only morning
    if RUN_HOUR < 12:
        rows = await conn.fetch("""
            SELECT b.id, b.guest_name, b.guest_phone
              FROM accommodation_bookings b
              LEFT JOIN guest_msg_log l
                ON l.booking_id = b.id AND l.template_slug = 'guest.review_nudge_day2'
             WHERE b.checkout_date = $1
               AND b.status IN ('confirmed','deposit_paid','paid','active')
               AND b.guest_phone IS NOT NULL
               AND l.id IS NULL
        """, two_days_ago)
        for r in rows:
            body = render(templates["guest.review_nudge_day2"],
                          {"guest_name": r["guest_name"], "review_url": REVIEW_URL})
            triggers.append((r["id"], "guest.review_nudge_day2", body,
                             r["guest_phone"], r["guest_name"]))

    queued = 0
    for booking_id, slug, body, phone, name in triggers:
        try:
            qid = await queue(conn, booking_id=booking_id, template_slug=slug,
                              body=body, phone=phone, label=name)
            print(f"  queued #{qid} → {name} ({slug})")
            queued += 1
        except Exception as e:
            print(f"  #{booking_id} {slug} error: {e}")

    print(f"queued {queued} of {len(triggers)} candidates "
          f"(welcome+checkout+review at hour {RUN_HOUR}:00)")
    await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
