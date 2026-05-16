"""u101-harvest-collins-reservations.py — Harvest Collins/DesignMyNight
restaurant booking emails into restaurant_reservations.

Subject: "The Olde Malthouse Inn | Booking Received (DMN ref no. DMN-NNNNN)"
Body shape:
  Hi, You have received a new booking for N guests on Mon DD at HH:MMam/pm.
  Name: Carole Luck
  Email: carole@…
  Phone: 07…
  Booking type: Dinner
  View it in Collins: http://go.collinsbookings.com/<id>

Idempotency: source='collins', source_ref=<DMN ref>.
"""
from __future__ import annotations
import os, sys, re, json, base64, html as html_mod, asyncio
import urllib.request, urllib.parse
from datetime import datetime, timezone
import asyncpg

VAULT_TOKEN = os.environ['VAULT_TOKEN']
GF = 'http://google-fetch:8011'


def vault(path):
    req = urllib.request.Request(f'http://vault:8200/v1/secret/data/{path}',
                                  headers={'X-Vault-Token': VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']


def gf_get(path, **params):
    qs = '&'.join(f'{k}={urllib.parse.quote(str(v))}' for k, v in params.items())
    url = f'{GF}{path}' + (f'?{qs}' if qs else '')
    try: return json.loads(urllib.request.urlopen(url, timeout=20).read())
    except: return {}


def message_text(msg):
    def walk(part):
        mime = (part.get('mimeType') or '').lower()
        b = (part.get('body', {}) or {}).get('data')
        if mime.startswith('text/plain') and b:
            return base64.urlsafe_b64decode((b + '====').encode()).decode('utf-8', errors='replace')
        if mime.startswith('text/html') and b:
            raw = base64.urlsafe_b64decode((b + '====').encode()).decode('utf-8', errors='replace')
            raw = re.sub(r'<[^>]+>', ' ', raw)
            return html_mod.unescape(raw)
        for s in (part.get('parts') or []):
            t = walk(s)
            if t: return t
        return None
    return re.sub(r'\s+', ' ', walk(msg.get('payload') or {}) or '').strip()


REF_RE   = re.compile(r'DMN ref no\.\s*(DMN-\d+)', re.I)
WHEN_RE  = re.compile(
    r'for\s+(\d+)\s+guests?\s+on\s+(\d{1,2}\s+[A-Za-z]+)\s+at\s+([\d:]+(?:am|pm))',
    re.I)
NAME_RE  = re.compile(r'Name:\s*([^\r\n]+?)\s+(?:Email|Phone|Booking)', re.I)
EMAIL_RE = re.compile(r'Email:\s*(\S+@\S+?)\s', re.I)
PHONE_RE = re.compile(r'Phone:\s*(\+?[\d\s]+?)\s+(?:Booking|Name|Email)', re.I)
TYPE_RE  = re.compile(r'Booking\s*type:\s*([A-Za-z]+)', re.I)
URL_RE   = re.compile(r'(http://go\.collinsbookings\.com/\w+)')


def parse_collins(subject, body, received: datetime):
    rm = REF_RE.search(subject + ' ' + body)
    if not rm:
        return None
    ref = rm.group(1)

    # Status from subject
    sub_lower = subject.lower()
    if 'enquiry' in sub_lower:
        status = 'enquiry'
    elif 'cancelled' in sub_lower:
        status = 'cancelled'
    else:
        status = 'confirmed'

    wm = WHEN_RE.search(body)
    party = None
    reservation_at = None
    if wm:
        try:
            party = int(wm.group(1))
            # "12 Jun at 07:00pm" - assume current year, roll forward if past
            dt_str = f"{wm.group(2)} {received.year} {wm.group(3).upper()}"
            dt = datetime.strptime(dt_str, '%d %b %Y %I:%M%p')
            # Roll year if more than 90 days past received_at
            if (dt.date() - received.date()).days < -90:
                dt = dt.replace(year=received.year + 1)
            reservation_at = dt.replace(tzinfo=received.tzinfo or timezone.utc)
        except ValueError:
            pass

    nm = NAME_RE.search(body);   guest_name  = nm.group(1).strip() if nm else None
    em = EMAIL_RE.search(body);  guest_email = em.group(1).strip() if em else None
    pm = PHONE_RE.search(body);  guest_phone = pm.group(1).strip() if pm else None
    tm = TYPE_RE.search(body);   booking_type = tm.group(1).strip() if tm else None
    um = URL_RE.search(body);    collins_url  = um.group(1) if um else None

    return {
        'ref': ref, 'status': status, 'reservation_at': reservation_at,
        'party_size': party, 'guest_name': guest_name, 'guest_email': guest_email,
        'guest_phone': guest_phone, 'booking_type': booking_type,
        'collins_url': collins_url,
    }


async def main():
    days_back = int(sys.argv[1] if len(sys.argv) > 1 else 1100)
    pg_pw = vault('postgres')['password']
    conn = await asyncpg.connect(f'postgresql://postgres:{pg_pw}@homeai-postgres:5432/homeai')
    await conn.execute("SELECT home_ai.set_realm('owner')")

    stats = {'seen': 0, 'inserted': 0, 'updated': 0, 'skipped': 0, 'parse_fail': 0}
    window = 30
    for older_days in range(0, days_back, window):
        x, y = older_days, older_days + window
        for account in ('info', 'admin'):
            q = f'from:noreply@designmynight.com older_than:{x}d newer_than:{y}d'
            res = gf_get('/messages', account=account, max_results=100, q=q)
            msgs = res.get('messages', [])
            if not msgs: continue
            for stub in msgs:
                mid = stub.get('id')
                if not mid: continue
                stats['seen'] += 1
                msg = gf_get(f'/message/{account}/{mid}')
                if not msg: continue
                h = {x['name'].lower(): x['value']
                     for x in msg.get('payload', {}).get('headers', [])}
                subject = h.get('subject') or ''
                body = message_text(msg)[:4000]
                date_raw = h.get('date', '')
                try:
                    received = datetime.strptime(date_raw[:31].strip(),
                                                  '%a, %d %b %Y %H:%M:%S %z')
                except Exception:
                    received = datetime.now(timezone.utc)
                p = parse_collins(subject, body, received)
                if not p:
                    stats['parse_fail'] += 1; continue

                existing = await conn.fetchrow(
                    "SELECT id, status FROM restaurant_reservations "
                    "WHERE source='collins' AND source_ref=$1", p['ref'])
                if existing:
                    if existing['status'] != p['status']:
                        await conn.execute(
                            "UPDATE restaurant_reservations SET status=$1, source_email_id=$2 WHERE id=$3",
                            p['status'], mid, existing['id'])
                        stats['updated'] += 1
                    else:
                        stats['skipped'] += 1
                    continue

                async with conn.transaction():
                    await conn.execute("SET LOCAL app.current_entity = '1'")
                    await conn.execute("""
                        INSERT INTO restaurant_reservations
                            (entity_id, source, source_ref, status,
                             reservation_at, party_size,
                             guest_name, guest_email, guest_phone,
                             booking_type, collins_url,
                             source_email_id, source_account, raw_text, realm)
                        VALUES (1, 'collins', $1, $2,
                                $3, $4,
                                $5, $6, $7,
                                $8, $9,
                                $10, $11, $12, 'work')
                    """, p['ref'], p['status'],
                         p['reservation_at'], p['party_size'],
                         p['guest_name'], p['guest_email'], p['guest_phone'],
                         p['booking_type'], p['collins_url'],
                         mid, account, body[:4000])
                    stats['inserted'] += 1
        if older_days % 90 == 0:
            print(f'  through {older_days}d: ins={stats["inserted"]} '
                  f'upd={stats["updated"]} skip={stats["skipped"]} '
                  f'parse_fail={stats["parse_fail"]}', flush=True)

    await conn.close()
    print(f'\n== Summary ==')
    for k, v in stats.items():
        print(f'  {k:11s} = {v}')


asyncio.run(main())
