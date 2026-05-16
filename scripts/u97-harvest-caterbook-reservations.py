"""u97-harvest-caterbook-reservations.py — Harvest OTA reservations
forwarded via Caterbook's "New Reservation" emails.

All OTA bookings (Airbnb, Agoda, Ctrip etc) flow through Caterbook and
appear in info@ with a structured "New Reservation - {channel} for {name}
{reservation_id}_L-{property_id}" subject + body containing channel,
property, status, nightly prices, total.

Idempotency: source='caterbook', source_ref=<reservation_id>_L-<property>.

Usage:
  docker exec homeai-bot-responder python3 /tmp/u97.py [days_back=1100]
"""
from __future__ import annotations
import os, sys, re, json, base64, html as html_mod, asyncio
import urllib.request, urllib.parse
from datetime import datetime, timezone

import asyncpg

VAULT_TOKEN = os.environ['VAULT_TOKEN']
GF = 'http://google-fetch:8011'


def vault(path: str) -> dict:
    req = urllib.request.Request(f'http://vault:8200/v1/secret/data/{path}',
                                  headers={'X-Vault-Token': VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']


def gf_get(path: str, **params) -> dict:
    qs = '&'.join(f'{k}={urllib.parse.quote(str(v))}' for k, v in params.items())
    url = f'{GF}{path}' + (f'?{qs}' if qs else '')
    try:
        return json.loads(urllib.request.urlopen(url, timeout=30).read())
    except Exception:
        return {}


def message_text(msg: dict) -> str:
    """Return collapsed plain text from the message body."""
    def walk(part):
        mime = (part.get('mimeType') or '').lower()
        body = part.get('body', {}) or {}
        b = body.get('data')
        if mime.startswith('text/plain') and b:
            raw = base64.urlsafe_b64decode((b + '====').encode()).decode('utf-8', errors='replace')
            return raw
        if mime.startswith('text/html') and b:
            raw = base64.urlsafe_b64decode((b + '====').encode()).decode('utf-8', errors='replace')
            raw = re.sub(r'<[^>]+>', ' ', raw)
            return html_mod.unescape(raw)
        for sub in (part.get('parts') or []):
            t = walk(sub)
            if t: return t
        return None
    return re.sub(r'\s+', ' ', walk(msg.get('payload') or {}) or '').strip()


# ── Parsers ─────────────────────────────────────────────────────────────────

# Subject: "New Reservation  -  {channel} for {Name} {ref}_L-{prop}"
SUBJECT_RE = re.compile(
    r'New\s+Reservation\s*-\s*(?P<channel>\S+)\s+for\s+(?P<guest>.+?)\s+'
    r'(?P<ref>[A-Za-z0-9]+)_L-(?P<prop>\d+)',
    re.I)

# Body: "Check in 22 May 2026 - 25 May 2026"
CHECKIN_RE = re.compile(
    r'Check\s*in\s+(\d{1,2}\s+[A-Za-z]+\s+\d{4})\s*-\s*(\d{1,2}\s+[A-Za-z]+\s+\d{4})',
    re.I)

# Body: nightly prices "2026-05-22 ... GBP 166.06"
NIGHT_RE = re.compile(r'(\d{4}-\d{2}-\d{2})\s+\S[^G]*GBP\s+([\d.,]+)', re.I)

# Body: "Total GBP 498.17"
TOTAL_RE = re.compile(r'Total\s+GBP\s+([\d.,]+)', re.I)

# Body: "Status" — usually "Confirmed" appears right after the ref
STATUS_RE = re.compile(r'(Confirmed|Cancelled|Pending|Tentative)', re.I)

# Body: room/property name appears after "Channel Collect" or similar
ROOM_RE = re.compile(r'(?:Channel Collect|View on \S+)\s+(.+?)\s+Check\s*in', re.I)

# Body: "Adults : 3 Children : 0"
PARTY_RE = re.compile(r'Adults?\s*:?\s*(\d+)\s+Children?\s*:?\s*(\d+)', re.I)


def normalise_channel(raw: str) -> str:
    raw = raw.lower().strip()
    if 'airbnb' in raw:    return 'airbnb'
    if 'agoda'  in raw:    return 'agoda'
    if 'ctrip'  in raw or 'trip.com' in raw: return 'ctrip'
    if 'expedia' in raw:   return 'expedia'
    if 'booking' in raw:   return 'booking_com'
    if 'oyo'    in raw:    return 'oyo'
    return raw.replace('.', '_')


def parse_caterbook_reservation(subject: str, body: str) -> dict | None:
    sm = SUBJECT_RE.search(subject or '')
    if not sm:
        return None
    channel_raw = sm.group('channel')
    channel = normalise_channel(channel_raw)
    guest = sm.group('guest').strip()
    ref = f"{sm.group('ref')}_L-{sm.group('prop')}"

    body = body or ''

    # Status
    status_m = STATUS_RE.search(body[:500])  # status appears early
    status = (status_m.group(1).lower() if status_m else 'confirmed')
    status_map = {
        'confirmed': 'confirmed',
        'pending':   'confirmed',  # OTA-side pending → still book it
        'tentative': 'confirmed',
        'cancelled': 'cancelled',
    }
    status = status_map.get(status, 'confirmed')

    # Check-in / check-out dates
    cm = CHECKIN_RE.search(body)
    checkin, checkout = None, None
    if cm:
        try:
            checkin  = datetime.strptime(cm.group(1), '%d %B %Y').date()
            checkout = datetime.strptime(cm.group(2), '%d %B %Y').date()
        except ValueError:
            pass

    # Total
    total = None
    tm = TOTAL_RE.search(body)
    if tm:
        try: total = float(tm.group(1).replace(',', ''))
        except: pass

    # Room
    room = None
    rm = ROOM_RE.search(body)
    if rm:
        room = rm.group(1).strip()[:120]

    # Party
    adults, children = 0, 0
    pm = PARTY_RE.search(body)
    if pm:
        adults = int(pm.group(1)); children = int(pm.group(2))

    return {
        'channel':  channel,
        'guest':    guest,
        'ref':      ref,
        'status':   status,
        'checkin':  checkin,
        'checkout': checkout,
        'total':    total,
        'room':     room,
        'adults':   adults,
        'children': children,
    }


async def main():
    days_back = int(sys.argv[1] if len(sys.argv) > 1 else 1100)
    print(f'== U97 Caterbook reservation harvester ==')
    print(f'days_back = {days_back}  (~{days_back/30.5:.0f} months)', flush=True)

    pg_pw = vault('postgres')['password']
    conn = await asyncpg.connect(f'postgresql://postgres:{pg_pw}@homeai-postgres:5432/homeai')
    await conn.execute("SELECT home_ai.set_realm('owner')")

    window = 30
    stats = {'seen': 0, 'inserted': 0, 'updated': 0, 'skipped': 0, 'parse_fail': 0}
    by_channel = {}

    for older_days in range(0, days_back, window):
        x, y = older_days, older_days + window
        q = f'from:caterbook.net "New Reservation" older_than:{x}d newer_than:{y}d'
        res = gf_get('/messages', account='info', max_results=100, q=q)
        msgs = res.get('messages', [])
        if not msgs: continue
        for stub in msgs:
            mid = stub.get('id')
            if not mid: continue
            stats['seen'] += 1
            msg = gf_get(f'/message/info/{mid}')
            if not msg: continue
            headers = {h['name'].lower(): h['value']
                       for h in (msg.get('payload', {}).get('headers') or [])}
            subject = headers.get('subject') or ''
            body = message_text(msg)[:6000]
            parsed = parse_caterbook_reservation(subject, body)
            if not parsed:
                stats['parse_fail'] += 1
                continue
            source = f"caterbook_{parsed['channel']}"
            by_channel[source] = by_channel.get(source, 0) + 1

            existing = await conn.fetchrow(
                "SELECT id, status FROM accommodation_bookings "
                "WHERE source=$1 AND source_ref=$2", source, parsed['ref'])
            if existing:
                if existing['status'] != parsed['status']:
                    await conn.execute(
                        "UPDATE accommodation_bookings SET status=$1, source_email_id=$2 WHERE id=$3",
                        parsed['status'], mid, existing['id'])
                    stats['updated'] += 1
                else:
                    stats['skipped'] += 1
                continue

            async with conn.transaction():
                await conn.execute("SET LOCAL app.current_entity = '1'")
                await conn.execute("""
                    INSERT INTO accommodation_bookings
                        (entity_id, source, source_ref, status,
                         guest_name, room, checkin_date, checkout_date,
                         gross_amount, total_amount,
                         source_email_id, source_account, booking_type,
                         raw_text, realm)
                    VALUES (1, $1, $2, $3,
                            $4, $5, $6, $7,
                            $8, $8,
                            $9, 'info', 'accommodation',
                            $10, 'work')
                """, source, parsed['ref'], parsed['status'],
                     parsed['guest'], parsed['room'],
                     parsed['checkin'], parsed['checkout'],
                     parsed['total'], mid, body[:4000])
                stats['inserted'] += 1
        print(f'  batch {x}d..{y}d  ins={stats["inserted"]} upd={stats["updated"]} '
              f'skip={stats["skipped"]} parse_fail={stats["parse_fail"]}', flush=True)

    await conn.close()
    print(f'\n== Summary ==')
    for k, v in stats.items():
        print(f'  {k:12s} = {v}')
    print('\nBy channel:')
    for k, v in sorted(by_channel.items(), key=lambda x:-x[1]):
        print(f'  {k:24s} = {v}')


asyncio.run(main())
