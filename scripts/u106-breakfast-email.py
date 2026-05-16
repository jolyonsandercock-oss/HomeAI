"""u106-breakfast-email.py — Compose + send the 5pm breakfast email.

Version C voice (atmospheric/marketing-rich).
HTML form with radio buttons.
Per-guest columns (2-col responsive grid for 2 guests; auto for more).
Submit POSTs to https://jolybox.tailc27dff.ts.net/api/breakfast/submit

DRY_RUN=1 by default — emails go ONLY to the addresses listed in
TEST_RECIPIENTS, not to actual guests.

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
BASE_URL = os.environ.get('BASE_URL', 'https://jolybox.tailc27dff.ts.net')
SECRET = os.environ.get('BREAKFAST_TOKEN_SECRET', 'u106-rotate-me-please-1234567890')

TEST_RECIPIENTS = [
    'jolyon.sandercock@gmail.com',
    'kitchen@malthousetintagel.com',
]


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


# Menu structure — matches the A5 print proof
MENU = [
    {'category': 'continental', 'label': 'Continental & Cereal', 'items': [
        ('granola',     'Luxury granola with natural yoghurt'),
        ('berries',     'Summer berry compote with natural yoghurt'),
        ('cornflakes',  'Crunchy nut cornflakes with semi-skimmed milk'),
        ('croissant',   'Freshly baked croissant, jam & butter'),
    ]},
    {'category': 'light', 'label': 'Light Breakfast', 'items': [
        ('sausage_sw',  'Sausage sandwich'),
        ('bacon_sw',    'Bacon sandwich'),
        ('eggs_bacon',  'Scrambled eggs & bacon on toast'),
        ('salmon_avo',  'Beetroot-cured salmon, smashed avocado & poached egg on toast'),
    ]},
    {'category': 'full', 'label': 'Full Breakfast', 'items': [
        ('cornish',     'Full Cornish (bacon, sausage, hogs pudding, fried egg, tomato, mushrooms, beans, hash brown)'),
        ('veggie',      'Full Vegetarian (veggie sausage, hash brown, fried egg, tomato, mushrooms, beans)'),
        ('vegan',       'Full Vegan (vegan sausage, beans, hash browns, tomatoes, mushrooms)'),
    ]},
]

DRINKS = ['Tea', 'Coffee', 'Both', 'None — water only']
TIMES  = ['08:00', '08:15', '08:30', '08:45', '09:00']


def render_html(booking_id: int, guest_count: int, first: str,
                room: str, checkin_day: str, service_date: str,
                weather: str, tides: str, activities: str, specials: str,
                table_offer: str) -> str:
    """Return full HTML email body with form."""
    token = make_token(booking_id, service_date)
    action = f"{BASE_URL}/api/breakfast/submit"

    # Multi-column guest sections
    col_class = "two-col" if guest_count == 2 else ("three-col" if guest_count >= 3 else "one-col")
    guest_blocks = []
    for g in range(1, max(guest_count, 1) + 1):
        radio_dish = []
        for cat in MENU:
            radio_dish.append(f'<div class="cat">{cat["label"]}</div>')
            for code, label in cat['items']:
                radio_dish.append(
                    f'<label class="opt"><input type="radio" name="g{g}_dish" value="{label}"> {label}</label>')
        radio_drink = ''.join(
            f'<label class="opt"><input type="radio" name="g{g}_drink" value="{d}"> {d}</label>'
            for d in DRINKS)
        guest_blocks.append(f"""
        <div class="guest">
          <div class="guest-h">Guest {g}{' (you)' if g == 1 else ''}</div>
          <div class="sec-h">Hot drink</div>
          {radio_drink}
          <div class="sec-h">Dish</div>
          {''.join(radio_dish)}
          <label class="textfield">Allergies / notes
            <input type="text" name="g{g}_notes" placeholder="e.g. gluten-free, no mushrooms">
          </label>
        </div>""")

    time_radios = ''.join(
        f'<label class="time-opt"><input type="radio" name="service_time" value="{t}"{" checked" if t == "08:30" else ""}> {t}</label>'
        for t in TIMES)

    return f"""<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body {{ font-family: Georgia, 'Times New Roman', serif; max-width: 720px; margin: 0 auto;
          padding: 24px; background: #fafafa; color: #2a2a2a; line-height: 1.6; }}
  h1 {{ font-size: 22px; color: #18189b; margin: 0 0 8px 0; }}
  .intro {{ font-size: 15px; color: #555; }}
  .brief {{ background: #fff; border-left: 3px solid #18189b; padding: 12px 16px; margin: 20px 0; font-size: 14px; }}
  .brief b {{ color: #18189b; }}
  form {{ background: #fff; padding: 20px; border: 1px solid #ddd; border-radius: 6px; }}
  .grid {{ display: grid; gap: 18px; }}
  .grid.one-col {{ grid-template-columns: 1fr; }}
  .grid.two-col {{ grid-template-columns: 1fr 1fr; }}
  .grid.three-col {{ grid-template-columns: 1fr 1fr 1fr; }}
  .guest {{ background: #fbfbfb; border: 1px solid #e5e5e5; border-radius: 4px; padding: 14px; }}
  .guest-h {{ font-weight: bold; font-size: 16px; color: #18189b; margin-bottom: 10px;
              border-bottom: 1px solid #eee; padding-bottom: 6px; }}
  .sec-h {{ font-weight: bold; font-size: 13px; margin-top: 12px; margin-bottom: 4px;
            text-transform: uppercase; letter-spacing: 0.04em; color: #666; }}
  .cat   {{ font-style: italic; color: #888; margin: 6px 0 2px 0; font-size: 12px; }}
  label.opt {{ display: block; padding: 4px 0; font-size: 14px; cursor: pointer; }}
  label.opt:hover {{ background: #f0f0f0; }}
  label.opt input {{ margin-right: 8px; }}
  label.textfield {{ display: block; margin-top: 8px; font-size: 13px; color: #555; }}
  label.textfield input {{ display: block; width: 100%; padding: 8px;
                            border: 1px solid #ccc; border-radius: 3px; margin-top: 4px;
                            font-size: 14px; }}
  .time-row {{ margin: 16px 0; padding: 12px; background: #f6f6f6; border-radius: 4px; }}
  label.time-opt {{ display: inline-block; margin-right: 16px; font-size: 14px; cursor: pointer; }}
  label.time-opt input {{ margin-right: 6px; }}
  .submit-row {{ text-align: center; margin-top: 24px; }}
  button {{ background: #18189b; color: #fff; padding: 14px 36px; font-size: 16px;
            border: 0; border-radius: 4px; cursor: pointer; font-weight: bold; }}
  button:hover {{ background: #0d0d6b; }}
  .table-offer {{ background: #fff7ed; border: 1px solid #fbbf24; padding: 14px;
                   border-radius: 4px; margin: 20px 0; font-size: 14px; }}
  .specials {{ background: #fff; border: 1px dashed #888; padding: 12px; border-radius: 4px;
                margin: 12px 0 20px 0; font-size: 14px; }}
  .specials b {{ color: #18189b; }}
  footer {{ margin-top: 30px; color: #888; font-size: 12px; text-align: center; }}
</style></head>
<body>

<h1>A {checkin_day.lower()} kind of breakfast, {first}</h1>

<p class="intro">
The light over the Atlantic tomorrow looks like {weather.lower()},
and the cliff path back from Boscastle catches the morning sun
beautifully at this time of year.
</p>

<div class="brief">
  <b>Tomorrow's brief</b> ({service_date})<br>
  <b>Weather:</b> {weather}<br>
  <b>Tides:</b> {tides}<br>
  <b>Locals:</b> {activities}
</div>

<p>Breakfast is served 8-9am downstairs. Here's what's on:</p>

{('<div class="specials"><b>Chef specials tomorrow:</b><br>' + specials + '</div>') if specials else ''}

<form action="{action}" method="POST">
  <input type="hidden" name="t" value="{token}">

  <div class="time-row">
    <b>What time would you like breakfast?</b><br>
    {time_radios}
  </div>

  <div class="grid {col_class}">
    {''.join(guest_blocks)}
  </div>

  <div class="submit-row">
    <button type="submit">Lock in our breakfast</button>
  </div>
</form>

{f'<div class="table-offer">{table_offer}</div>' if table_offer else ''}

<footer>
  Sent from the Olde Malthouse Inn ({room}). Reply directly to this
  email if you'd rather just type it out — info@malthousetintagel.com.<br>
  01840 770461 · malthousetintagel.com
</footer>

</body></html>"""


def send_email(account: str, to: str, subject: str, html: str, text: str = None):
    payload = {
        'to': to, 'subject': subject,
        'body_text': text or 'Please open this in an HTML-capable email client.',
        'body_html': html,
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

    if TEST:
        # Build ONE sample email using Matthias Stötzner's real booking (Garden Suite, tonight)
        sample = await conn.fetchrow("""
            SELECT id, guest_name, room, checkin_date, checkout_date
            FROM accommodation_bookings
            WHERE checkin_date = CURRENT_DATE
              AND status IN ('confirmed','deposit_paid','paid','active')
            ORDER BY id LIMIT 1
        """)
        if not sample:
            print('No sample booking for today')
            return

        service_date = (date.today() + timedelta(days=1)).isoformat()
        weather    = "Mostly sunny 17°C, light SW breeze (live API placeholder)"
        tides      = "Tomorrow high tide 06:42 & 19:18 — low tide perfect for rockpooling 12:30"
        activities = "King Arthur's Castle (5-min walk), Coast Path to Boscastle (2 hrs), Glebe Cliff sunset bench"
        specials   = "Pan-fried local mackerel with samphire — Chef's pick. (placeholder until kitchen@ 10am reply)"
        table_offer = (
            'Looking for dinner tonight? <a href="https://www.malthousetintagel.com/book-a-table" '
            'style="color:#18189b;font-weight:bold">Reserve a table</a> — or '
            "click reply and tell us 1, 2 or 6 people and we will sort it."
        )

        html = render_html(
            booking_id=sample['id'],
            guest_count=2,
            first=first_name(sample['guest_name']),
            room=sample['room'] or 'Garden Suite',
            checkin_day=date.fromisoformat(service_date).strftime('%A'),
            service_date=service_date,
            weather=weather, tides=tides, activities=activities,
            specials=specials, table_offer=table_offer,
        )

        subject = f"A {date.fromisoformat(service_date).strftime('%A').lower()} kind of breakfast, {first_name(sample['guest_name'])}"

        for to_addr in TEST_RECIPIENTS:
            try:
                # For kitchen@ — send AS info@ (workspace alias)
                # For jolyon.sandercock@gmail.com — send from bot per policy
                account = 'bot' if 'sandercock' in to_addr else 'info'
                resp = send_email(account, to_addr, '[TEST] ' + subject, html)
                print(f'  sent to {to_addr} via {account} → {resp.get("message_id")}')
            except Exception as e:
                print(f'  FAILED to {to_addr}: {e}')
    else:
        print('LIVE mode not yet enabled — set TEST=0 to fire to guests.')

    await conn.close()


asyncio.run(main())
