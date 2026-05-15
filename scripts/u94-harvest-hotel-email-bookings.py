"""u94-harvest-hotel-email-bookings.py — backfill accommodation_bookings
from `bookings@hotel-email.com` "New Booking Received" emails.

Runs inside homeai-bot-responder container (has vault + google-fetch access).
Idempotent on (source='hotel_email', source_ref=booking_reference).

Usage: docker exec homeai-bot-responder python3 /tmp/u94-harvester.py [days_back]
       days_back defaults to 1100 (~36 months).
"""
from __future__ import annotations
import os, sys, re, json, base64, asyncio, urllib.request, urllib.parse
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
    return json.loads(urllib.request.urlopen(url, timeout=30).read())


def message_body_text(msg: dict) -> str:
    """Walk message parts; return first text/plain we find, fall back to HTML stripped."""
    def walk(part):
        mime = (part.get('mimeType') or '').lower()
        body = part.get('body', {}) or {}
        if mime.startswith('text/plain') and body.get('data'):
            b = body['data']; pad = '=' * (-len(b) % 4)
            return base64.urlsafe_b64decode(b + pad).decode('utf-8', errors='replace')
        if mime.startswith('text/html') and body.get('data'):
            b = body['data']; pad = '=' * (-len(b) % 4)
            html = base64.urlsafe_b64decode(b + pad).decode('utf-8', errors='replace')
            # HTML strip with newline-preserving tag handling
            html = re.sub(r'<(br|/p|/div|/tr|/li|/td)[^>]*>', '\n', html, flags=re.I)
            html = re.sub(r'<[^>]+>', ' ', html)
            # collapse multi-space, preserve newlines
            html = re.sub(r'[ \t]+', ' ', html)
            return html
        for sub in (part.get('parts') or []):
            t = walk(sub)
            if t: return t
        return None
    return walk(msg.get('payload') or {}) or ''


# ── Parser for "Booking Reference : NNNN" emails ──────────────────────────
# Single-room shape:
#   Booking Reference : 8700
#   Lead Guest : louisephillips
#   Arriving : 23/04/2026 Departing : 24/04/2026
#   Room Type : Room 4 - Single Room Rateplan : Bed & Breakfast
#   Deposit paid : 0.00 Balance due on Arrival : 172.50
#
# Multi-room: the (Arriving/Departing/Room Type/Rateplan) block repeats.
# We capture each room as a separate booking row (with shared lead guest,
# distinct source_ref like 8700-r1, 8700-r2 etc.).

# Booking ref: digits terminated by a recognised next-field word. \b doesn't help
# because the source text has no spaces between fields ("8850Lead Guest ..." is
# one continuous word). Use lookahead for the next known field.
REF_RE      = re.compile(r'Booking\s+Reference\s*[:=]\s*(\d{2,10})(?=Lead|Arriving|\s|$)', re.I)
GUEST_RE    = re.compile(r'Lead\s+Guest\s*[:=]\s*([^\r\n]+?)(?=Arriving|Email|Phone|$)', re.I)
DEPOSIT_RE  = re.compile(r'Deposit\s+paid\s*[:=]\s*([\d.,]+)', re.I)
BALANCE_RE  = re.compile(r'Balance\s+due[^:]*[:=]\s*([\d.,]+)', re.I)

ROOM_BLOCK_RE = re.compile(
    r'Arriving\s*[:=]\s*(\d{2}/\d{2}/\d{4})\s*Departing\s*[:=]\s*(\d{2}/\d{2}/\d{4})'
    r'\s*Room\s+Type\s*[:=]\s*(.+?)\s*Rateplan\s*[:=]\s*(.+?)'
    r'(?=\s*(?:Arriving|Deposit|Balance|$))',
    re.I | re.S)

def parse_uk_date(s: str):
    d, m, y = s.split('/')
    return datetime(int(y), int(m), int(d)).date()

def num(s: str) -> float:
    return float(s.replace(',', ''))


def parse_booking_email(body: str) -> dict | None:
    body = body.replace('\r', '')
    m_ref = REF_RE.search(body)
    if not m_ref:
        return None
    booking_ref = m_ref.group(1).strip()

    m_guest = GUEST_RE.search(body)
    guest = m_guest.group(1).strip() if m_guest else None

    m_dep = DEPOSIT_RE.search(body)
    m_bal = BALANCE_RE.search(body)
    deposit = num(m_dep.group(1)) if m_dep else None
    balance = num(m_bal.group(1)) if m_bal else None

    rooms = []
    for m in ROOM_BLOCK_RE.finditer(body):
        rooms.append({
            'arriving':  parse_uk_date(m.group(1)),
            'departing': parse_uk_date(m.group(2)),
            'room_type': (m.group(3) or '').strip().rstrip(' Rateplan').strip(),
            'rateplan':  ((m.group(4) or '').strip() if m.group(4) else None),
        })

    return {
        'booking_ref': booking_ref,
        'guest_name':  guest,
        'deposit':     deposit,
        'balance_due': balance,
        'total':       (deposit or 0) + (balance or 0) if (deposit is not None or balance is not None) else None,
        'rooms':       rooms,
    }


async def main():
    days_back = int(sys.argv[1] if len(sys.argv) > 1 else 1100)
    print(f'== U94 T1 hotel-email harvester ==')
    print(f'days_back = {days_back}  (~{days_back/30.5:.0f} months)')

    pg_pw = vault('postgres')['password']
    conn = await asyncpg.connect(f'postgresql://postgres:{pg_pw}@homeai-postgres:5432/homeai')

    total_seen = 0
    total_inserted = 0
    total_messages = 0
    total_skipped_existing = 0
    total_parse_fail = 0

    # /messages endpoint caps at 100 and doesn't paginate. Slice by 30-day
    # windows working back from today; each slice should be ≤100 results for
    # a single sender.
    window = 30
    batch = 0
    for older in range(0, days_back, window):
        newer = max(older - window, 0)
        # Use Gmail's `newer_than:X` + `older_than:Y` operators in days.
        q = f'from:bookings@hotel-email.com older_than:{newer}d newer_than:{older + window}d'
        batch += 1
        params = {'account': 'info', 'max_results': 100, 'q': q}
        res = gf_get('/messages', **params)
        msgs = res.get('messages', [])
        if not msgs:
            continue
        print(f'  batch {batch} ({newer}d..{older + window}d): {len(msgs)} stubs')
        for stub in msgs:
            mid = stub.get('id')
            if not mid: continue
            total_seen += 1
            try:
                msg = gf_get(f'/message/info/{mid}')
            except Exception as e:
                total_parse_fail += 1
                continue

            headers = {h['name'].lower(): h['value']
                       for h in (msg.get('payload', {}).get('headers') or [])}
            received_raw = headers.get('date', '')
            try:
                received_at = datetime.strptime(received_raw[:31].strip(),
                    '%a, %d %b %Y %H:%M:%S %z')
            except Exception:
                received_at = datetime.now(timezone.utc)

            body = message_body_text(msg)
            parsed = parse_booking_email(body)
            if not parsed:
                total_parse_fail += 1
                continue

            ref = parsed['booking_ref']
            rooms = parsed['rooms']
            if not rooms:
                total_parse_fail += 1
                continue

            # Insert/upsert one row per room. source_ref = ref-rN for multi-room
            async with conn.transaction():
                await conn.execute("SET LOCAL app.current_entity = '1'")
                await conn.execute("SELECT home_ai.set_realm('work')")

                for i, room in enumerate(rooms, 1):
                    src_ref = ref if len(rooms) == 1 else f'{ref}-r{i}'
                    existing = await conn.fetchval(
                        "SELECT id FROM accommodation_bookings WHERE source='hotel_email' AND source_ref=$1",
                        src_ref)
                    if existing:
                        total_skipped_existing += 1
                        booking_id = existing
                    else:
                        booking_id = await conn.fetchval("""
                            INSERT INTO accommodation_bookings
                                (entity_id, source, source_ref, status,
                                 guest_name, room, checkin_date, checkout_date,
                                 meal_plan, gross_amount, total_amount,
                                 source_email_id, source_account, booking_type,
                                 payment_status, raw_text, realm)
                            VALUES (1, 'hotel_email', $1, 'confirmed',
                                    $2, $3, $4, $5, $6, $7, $8,
                                    $9, 'info', 'accommodation',
                                    $10, $11, 'work')
                            RETURNING id
                        """, src_ref, parsed['guest_name'], room['room_type'],
                             room['arriving'], room['departing'], room['rateplan'],
                             parsed['total'], parsed['total'],
                             mid,
                             ('deposit_paid' if (parsed['deposit'] or 0) > 0 else 'unpaid'),
                             body[:5000])
                        total_inserted += 1

                    # Always link the message (one inbound email → one booking_id)
                    await conn.execute("""
                        INSERT INTO booking_messages
                            (booking_id, gmail_account, gmail_message_id, received_at,
                             from_address, subject, body_excerpt, direction, realm)
                        VALUES ($1, 'info', $2, $3, $4, $5, $6, 'inbound', 'work')
                        ON CONFLICT (gmail_account, gmail_message_id) DO NOTHING
                    """, booking_id, mid, received_at,
                         headers.get('from', ''),
                         headers.get('subject', ''),
                         body[:1000])
                    total_messages += 1

    await conn.close()
    print(f'\n== U94 T1 summary ==')
    print(f'  seen          : {total_seen}')
    print(f'  inserted      : {total_inserted}')
    print(f'  skipped_dup   : {total_skipped_existing}')
    print(f'  parse_fail    : {total_parse_fail}')
    print(f'  msg-links     : {total_messages}')

asyncio.run(main())
