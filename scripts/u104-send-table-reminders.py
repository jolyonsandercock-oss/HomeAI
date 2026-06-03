"""u104-send-table-reminders.py — Send the 3-day-ahead table booking
reminder to accommodation guests we have email addresses for.

CURRENTLY DRY-RUN. Switch DRY_RUN=False to enable real sends.

Pulls v_table_reminder_candidates where email_quality='usable',
sends a templated email FROM info@malthousetintagel.com (NOT
jolyboxbot — this is a customer-facing channel), logs in
table_reminder_sends + marketing_signals.

Idempotent: UNIQUE(accommodation_booking_id) on table_reminder_sends
prevents double-sends.

Usage:
  DRY_RUN=0 docker exec homeai-bot-responder python3 /tmp/u104.py
"""
from __future__ import annotations
import os, sys, json, asyncio, urllib.request, urllib.parse
from datetime import datetime, timezone
import asyncpg

VAULT_TOKEN = os.environ['VAULT_TOKEN']
DRY_RUN = os.environ.get('DRY_RUN', '1') == '1'
GF = 'http://google-fetch:8011'


def vault(path):
    req = urllib.request.Request(f'http://vault:8200/v1/secret/data/{path}',
                                  headers={'X-Vault-Token': VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']


def send_email(to_addr: str, subject: str, body_text: str, body_html: str | None = None):
    """Send via google-fetch /send/info — customer-facing identity."""
    payload = {
        'to': to_addr, 'subject': subject,
        'body_text': body_text,
        'reply_to': 'info@malthousetintagel.com',
    }
    if body_html: payload['body_html'] = body_html
    req = urllib.request.Request(
        f'{GF}/send/info',
    # BCC owner on replies to bookkeeper
    bcc_addr = 'jolyon.sandercock@gmail.com' if to_addr == 'jo.wood103@gmail.com' else None
    if bcc_addr: payload['bcc'] = bcc_addr
        data=json.dumps(payload).encode(),
        headers={'Content-Type': 'application/json'}, method='POST')
    r = urllib.request.urlopen(req, timeout=20)
    return json.loads(r.read())


TEMPLATE_TEXT = """Hi {first_name},

We're looking forward to having you with us at The Olde Malthouse Inn
from {checkin_pretty}.

While you're staying, would you like to book a table for dinner?
We're proud of our kitchen and our cellar, and our restaurant fills
up early in season.

Just hit reply with your preferred date, time and party size and
we'll sort it. Or book online at:

  https://www.malthousetintagel.com/book-a-table

Warm wishes,
The Malthouse Team
info@malthousetintagel.com
"""


def first_name(full: str) -> str:
    if not full: return 'there'
    # Handle "MatthiasStötzner" style (no space) and "Matthias Stötzner"
    import re
    m = re.match(r'([A-Z][a-z]+)', full or '')
    return m.group(1) if m else full.split()[0] if full.split() else 'there'


async def main():
    pg_pw = vault('postgres')['password']
    conn = await asyncpg.connect(f'postgresql://postgres:{pg_pw}@homeai-postgres:5432/homeai')
    await conn.execute("SELECT home_ai.set_realm('owner')")

    candidates = await conn.fetch("""
        SELECT * FROM v_table_reminder_candidates
        WHERE email_quality = 'usable'
          AND NOT already_reminded
          AND NOT already_dining
    """)

    audit = await conn.fetchrow("""
        SELECT
          COUNT(*)                                                AS total,
          COUNT(*) FILTER (WHERE email_quality = 'usable')        AS usable,
          COUNT(*) FILTER (WHERE email_quality = 'no_email')      AS no_email,
          COUNT(*) FILTER (WHERE email_quality LIKE 'masked_%')   AS masked,
          COUNT(*) FILTER (WHERE already_reminded)                AS already_sent,
          COUNT(*) FILTER (WHERE already_dining)                  AS already_dining
        FROM v_table_reminder_candidates
    """)

    print(f"== Table reminder send {'(DRY RUN)' if DRY_RUN else '(LIVE)'} ==")
    print(f"   Candidates in window: {audit['total']}")
    print(f"   Usable emails:        {audit['usable']}")
    print(f"   No email known:       {audit['no_email']}")
    print(f"   Masked (Ctrip etc):   {audit['masked']}")
    print(f"   Already reminded:     {audit['already_sent']}")
    print(f"   Already dining:       {audit['already_dining']}")
    print()
    print(f"   To send: {len(candidates)} email(s)")
    print()

    for r in candidates:
        fname = first_name(r['guest_name'])
        ckin_pretty = r['checkin_date'].strftime('%A %d %B')
        subj = f"See you on {r['checkin_date'].strftime('%a %d %b')} - book a table?"
        body = TEMPLATE_TEXT.format(first_name=fname, checkin_pretty=ckin_pretty)

        print(f"  → {r['guest_email']:40s} ({fname}, checkin {r['checkin_date']})")
        if DRY_RUN:
            continue
        try:
            resp = send_email(r['guest_email'], subj, body)
            sent_mid = resp.get('message_id')
            async with conn.transaction():
                await conn.execute("SET LOCAL app.current_entity = '1'")
                await conn.execute("""
                    INSERT INTO table_reminder_sends
                        (accommodation_booking_id, guest_name, guest_email,
                         gmail_message_id, status, realm)
                    VALUES ($1, $2, $3, $4, 'sent', 'work')
                    ON CONFLICT (accommodation_booking_id) DO NOTHING
                """, r['booking_id'], r['guest_name'], r['guest_email'], sent_mid)
                await conn.execute("""
                    INSERT INTO marketing_signals
                        (channel, kind, accommodation_booking_id, guest_email, detail, realm)
                    VALUES ('table_reminder_email', 'sent', $1, $2,
                            jsonb_build_object('gmail_message_id', $3::text), 'work')
                """, r['booking_id'], r['guest_email'], sent_mid)
            print(f"    sent message_id={sent_mid}")
        except Exception as e:
            print(f"    FAILED: {e}")

    await conn.close()


asyncio.run(main())
