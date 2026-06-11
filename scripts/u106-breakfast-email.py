"""u106-breakfast-email.py — Compose + send the 5pm breakfast email.

REPLY-BASED VERSION (not form-POST):
  - Numbered menu so guests can reply with just "1, 3, coffee"
  - Or reply freely — Haiku parses on the inbound side
  - Reply-To: info@malthousetintagel.com
  - Subject carries the booking ref so we can match on inbound

DRY_RUN=1 by default — TEST_RECIPIENTS only.

Usage:
  TEST=1 docker exec -i homeai-bot-responder python3 /tmp/u106.py
"""
from __future__ import annotations
import os, sys, json, hmac, hashlib, urllib.request, asyncio
from datetime import datetime, date, timedelta
import asyncpg

VAULT_TOKEN = os.environ['VAULT_TOKEN']
TEST = os.environ.get('TEST', '1') == '1'
GF = 'http://google-fetch:8011'
SECRET = os.environ.get('BREAKFAST_TOKEN_SECRET', '')
if not SECRET:
    raise SystemExit('BREAKFAST_TOKEN_SECRET missing/empty — Vault secret/breakfast, mirrored in /home_ai/.env (U250)')

TEST_RECIPIENTS = [
    'jolyon.sandercock@gmail.com',
    'kitchen@malthousetintagel.com',
]

# A real, working URL — the Reserve-a-Table button on the public site
RESERVE_URL = 'https://malthousetintagel.com/our-food/'
BOOK_PHONE  = '01840 770461'


def vault(path):
    req = urllib.request.Request(f'http://vault:8200/v1/secret/data/{path}',
                                  headers={'X-Vault-Token': VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']


def make_token(booking_id: int, service_date: str) -> str:
    msg = f"{booking_id}.{service_date}".encode()
    sig = hmac.new(SECRET.encode(), msg, hashlib.sha256).hexdigest()[:16]
    return f"{booking_id}.{service_date}.{sig}"


def first_name(full: str) -> str:
    import re
    m = re.match(r'([A-Z][a-z]+)', full or '')
    return m.group(1) if m else (full.split()[0] if full and full.split() else 'there')


MENU = [
    {'category': 'Continental & Cereal', 'items': [
        'Luxury granola with natural yoghurt',
        'Summer berry compote with natural yoghurt',
        'Crunchy nut cornflakes with semi-skimmed milk',
        'Freshly baked croissant, jam & butter',
    ]},
    {'category': 'Light Breakfast', 'items': [
        'Sausage sandwich',
        'Bacon sandwich',
        'Scrambled eggs & bacon on toast',
        'Beetroot-cured salmon, smashed avocado & poached egg on toast',
    ]},
    {'category': 'Full Breakfast', 'items': [
        'Full Cornish (bacon, sausage, hogs pudding, fried egg, tomato, mushrooms, beans, hash brown)',
        'Full Vegetarian (veggie sausage, hash brown, fried egg, tomato, mushrooms, beans)',
        'Full Vegan (vegan sausage, beans, hash browns, tomatoes, mushrooms)',
    ]},
]


def numbered_menu_html() -> str:
    """Render the menu as a numbered list — guests reply with the numbers."""
    out = []
    counter = 1
    for cat in MENU:
        out.append(f'<h4 style="color:#18189b;margin:14px 0 6px 0">{cat["category"]}</h4><ol start="{counter}" style="margin:0 0 8px 22px;padding:0">')
        for item in cat['items']:
            out.append(f'<li style="margin:4px 0">{item}</li>')
            counter += 1
        out.append('</ol>')
    return ''.join(out)


def numbered_menu_text() -> str:
    """Plain-text version of the menu for the text part."""
    out = []
    counter = 1
    for cat in MENU:
        out.append(f'\n{cat["category"]}')
        for item in cat['items']:
            out.append(f'  {counter}. {item}')
            counter += 1
    return '\n'.join(out)


def render_html(booking_id: int, guest_count: int, first: str,
                room: str, service_date: str,
                weather: str, tides: str, activities: str, specials: str) -> str:
    token = make_token(booking_id, service_date)
    weekday = date.fromisoformat(service_date).strftime('%A')

    # mailto fallback with pre-filled subject + body
    import urllib.parse as up
    mailto_body = up.quote(
        f"Booking #{booking_id} — breakfast choices for {service_date}\n\n"
        f"Guest 1: \n"
        + (f"Guest 2: \n" if guest_count >= 2 else "")
        + (f"Guest 3: \n" if guest_count >= 3 else "")
        + "\nTime preference (8:00 / 8:30 / 9:00): \nDrinks: \nAllergies / notes: \n"
    )
    mailto_subj = up.quote(f"Breakfast — booking #{booking_id} ({service_date})")
    mailto = f"mailto:info@malthousetintagel.com?subject={mailto_subj}&body={mailto_body}"

    # Reserve-a-table mailto fallback
    table_mailto = (
        f"mailto:info@malthousetintagel.com?"
        f"subject={up.quote('Table for tonight — booking #' + str(booking_id))}"
        f"&body={up.quote('Please book us a table for tonight. Party size: __  Time preference: __')}"
    )

    return f"""<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body {{ font-family: Georgia, 'Times New Roman', serif; max-width: 660px; margin: 0 auto;
          padding: 24px; background: #fafafa; color: #2a2a2a; line-height: 1.55; }}
  h1 {{ font-size: 22px; color: #18189b; margin: 0 0 10px 0; }}
  .intro {{ font-size: 15px; color: #555; margin: 0 0 16px 0; }}
  .brief {{ background: #fff; border-left: 3px solid #18189b; padding: 12px 16px;
            margin: 18px 0; font-size: 14px; }}
  .brief b {{ color: #18189b; }}
  .menu-box {{ background: #fff; padding: 14px 18px; border: 1px solid #ddd;
               border-radius: 6px; font-size: 14px; }}
  .menu-box h4 {{ font-size: 14px; text-transform: uppercase; letter-spacing: 0.04em; }}
  .reply-cta {{ background: #18189b; color: #fff; padding: 16px 20px; border-radius: 6px;
                margin: 22px 0; font-size: 15px; }}
  .reply-cta a {{ color: #fff; font-weight: bold; text-decoration: underline; }}
  .reply-eg {{ background: #f0f3ff; border: 1px dashed #18189b; padding: 10px 14px;
               margin: 10px 0; font-family: ui-monospace, Menlo, monospace;
               font-size: 13px; border-radius: 4px; color: #18189b; }}
  .table-offer {{ background: #fff7ed; border: 1px solid #fbbf24; padding: 14px;
                   border-radius: 4px; margin: 20px 0; font-size: 14px; }}
  .table-offer a {{ color: #18189b; font-weight: bold; }}
  .specials {{ background: #fff; border: 1px dashed #888; padding: 12px;
                border-radius: 4px; margin: 12px 0 18px 0; font-size: 14px; }}
  .specials b {{ color: #18189b; }}
  footer {{ margin-top: 26px; color: #888; font-size: 12px; text-align: center;
            border-top: 1px solid #eee; padding-top: 12px; }}
</style></head>
<body>

<h1>A {weekday.lower()} kind of breakfast, {first}</h1>

<p class="intro">
The light over the Atlantic tomorrow looks like {weather.lower()},
and the cliff path back from Boscastle catches the morning sun
beautifully at this time of year.
</p>

<div class="brief">
  <b>Tomorrow's brief</b> ({weekday} {service_date})<br>
  <b>Weather:</b> {weather}<br>
  <b>Tides:</b> {tides}<br>
  <b>Locals:</b> {activities}
</div>

<p>Breakfast is served 8-9am downstairs. Here's the menu — numbered
so you can reply quickly:</p>

{('<div class="specials"><b>Chef specials tomorrow:</b><br>' + specials + '</div>') if specials else ''}

<div class="menu-box">
{numbered_menu_html()}
</div>

<div class="reply-cta">
  <b>Just hit reply</b> with your choices. We're happy with anything from
  a one-word answer to a full sentence — your call.

  <div class="reply-eg">
    G1: 9 + coffee<br>
    G2: 1 + tea, no nuts<br>
    Time: 8:30
  </div>

  <div class="reply-eg">
    "Cornish breakfast and a coffee for me, granola for Anna at 9am please"
  </div>

  Or if your email doesn't have an easy reply button:
  <a href="{mailto}">click here to start a reply</a>.
</div>

<div class="table-offer">
  <b>Dinner tonight?</b> Tables fill up at this time of year.
  <a href="{RESERVE_URL}">Reserve via our site</a>,
  call us on <b>{BOOK_PHONE}</b>, or
  <a href="{table_mailto}">click reply</a> and we'll sort it.
</div>

<footer>
  Sent from the Olde Malthouse Inn ({room}). Replies go straight to
  info@malthousetintagel.com.<br>
  01840 770461  ·  malthousetintagel.com  ·  Booking ref #{booking_id}
</footer>

</body></html>"""


def render_text(booking_id, guest_count, first, room, service_date,
                weather, tides, activities, specials):
    weekday = date.fromisoformat(service_date).strftime('%A')
    return f"""A {weekday.lower()} kind of breakfast, {first}

Looking forward to tomorrow ({weekday} {service_date}). Breakfast is
served 8-9am downstairs.

Tomorrow's brief:
  Weather: {weather}
  Tides:   {tides}
  Locals:  {activities}

{('CHEF SPECIALS: ' + specials) if specials else ''}

MENU (reply with the numbers, or just words — whichever's easier):
{numbered_menu_text()}

DRINKS: Tea / Coffee / Both / None

Examples of what to reply:
  G1: 9 + coffee
  G2: 1 + tea, no nuts
  Time: 8:30

Or: "Cornish breakfast and a coffee for me, granola for Anna at 9am please"

DINNER TONIGHT?
Reserve via {RESERVE_URL}, call {BOOK_PHONE}, or just reply.

— The Olde Malthouse Inn ({room})
01840 770461  ·  info@malthousetintagel.com  ·  Booking ref #{booking_id}
"""


def send_email(account: str, to: str, subject: str, html: str, text: str):
    payload = {
        'to': to, 'subject': subject,
        'body_text': text, 'body_html': html,
        'reply_to': 'info@malthousetintagel.com',
    }
    req = urllib.request.Request(f'{GF}/send/{account}',
        data=json.dumps(payload).encode(),
        headers={'Content-Type': 'application/json'}, method='POST')
    r = urllib.request.urlopen(req, timeout=20)
    return json.loads(r.read())


async def main():
    pg_pw = vault('postgres')['password']
    conn = await asyncpg.connect(f'postgresql://postgres:{pg_pw}@homeai-postgres:5432/homeai')
    await conn.execute("SELECT home_ai.set_realm('owner')")

    if not TEST:
        print('LIVE mode not yet enabled — set TEST=0 to fire to guests.')
        await conn.close()
        return

    sample = await conn.fetchrow("""
        SELECT id, guest_name, room
        FROM accommodation_bookings
        WHERE checkin_date = CURRENT_DATE
          AND status IN ('confirmed','deposit_paid','paid','active')
        ORDER BY id LIMIT 1
    """)
    if not sample:
        print('No sample booking for today')
        await conn.close()
        return

    service_date = (date.today() + timedelta(days=1)).isoformat()
    weather    = "Mostly sunny 17°C, light SW breeze (weather API stub)"
    tides      = "High 06:42 & 19:18; low tide rockpooling 12:30 (tide API stub)"
    activities = "Tintagel Castle (5-min), Coast Path to Boscastle (2h), Glebe Cliff sunset"
    specials   = "Pan-fried local mackerel with samphire — chef's pick (placeholder)"

    html = render_html(
        booking_id=sample['id'],
        guest_count=2,
        first=first_name(sample['guest_name']),
        room=sample['room'] or 'Garden Suite',
        service_date=service_date,
        weather=weather, tides=tides, activities=activities, specials=specials,
    )
    text = render_text(
        booking_id=sample['id'], guest_count=2,
        first=first_name(sample['guest_name']),
        room=sample['room'] or 'Garden Suite',
        service_date=service_date,
        weather=weather, tides=tides, activities=activities, specials=specials,
    )

    subject = (f"[TEST] A {date.fromisoformat(service_date).strftime('%A').lower()} "
               f"kind of breakfast — booking #{sample['id']}")

    for to_addr in TEST_RECIPIENTS:
        account = 'bot' if 'sandercock' in to_addr else 'info'
        try:
            resp = send_email(account, to_addr, subject, html, text)
            print(f'  sent to {to_addr:38s} via {account:5s} → {resp.get("message_id")}')
        except Exception as e:
            print(f'  FAILED to {to_addr}: {e}')

    await conn.close()


asyncio.run(main())
