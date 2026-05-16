"""u96-harvest-airbnb-bookings.py — Harvest Airbnb reservation confirmations
from info / admin / jo Gmail accounts.

Pattern observed (2026-05-16 audit):
  Subject: "Reservation confirmed - {NAME} arrives {Mon DD}"
  From:    "Airbnb <automated@airbnb.com>"
  Body:    "...NEW BOOKING CONFIRMED! {NAME} ARRIVES {MON DD}..."
  Body:    URL with confirmation code HM[A-Z0-9]{8} (e.g. HMKSTKWPRF)

Status mapping:
  "Reservation confirmed"        → status=confirmed
  "Reservation cancelled"        → status=cancelled
  "Reservation alteration"       → status=modified (record but keep latest)

Idempotency: source='airbnb', source_ref=<confirmation code>.

Usage:
  docker exec homeai-bot-responder python3 /tmp/u96.py [days_back=1100]
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


def message_body_text(msg: dict) -> str:
    def walk(part):
        mime = (part.get('mimeType') or '').lower()
        body = part.get('body', {}) or {}
        if mime.startswith('text/plain') and body.get('data'):
            b = body['data']; pad = '=' * (-len(b) % 4)
            return base64.urlsafe_b64decode(b + pad).decode('utf-8', errors='replace')
        if mime.startswith('text/html') and body.get('data'):
            b = body['data']; pad = '=' * (-len(b) % 4)
            raw = base64.urlsafe_b64decode(b + pad).decode('utf-8', errors='replace')
            raw = re.sub(r'<[^>]+>', ' ', raw)
            return html_mod.unescape(raw)
        for sub in (part.get('parts') or []):
            t = walk(sub)
            if t: return t
        return None
    return walk(msg.get('payload') or {}) or ''


CONF_CODE_RE = re.compile(r'\b(HM[A-Z0-9]{8})\b')
GUEST_DATE_RE = re.compile(
    r'Reservation\s+(confirmed|cancelled|cancellation|alteration|altered)'
    r'(?:\s*-\s*|\s+for\s+)([^\s,]+(?:\s+[A-Za-z\'-]+)*)\s+arrives\s+'
    r'([A-Z][a-z]+\s+\d{1,2})',
    re.I)


def parse_airbnb(subject: str, body: str, received: datetime) -> dict | None:
    sub = subject or ''
    # First — find confirmation code (best idempotency key)
    code = None
    for src in (sub, body):
        m = CONF_CODE_RE.search(src or '')
        if m:
            code = m.group(1)
            break
    if not code:
        return None  # not an actionable reservation email

    # Determine status from subject
    sub_lower = sub.lower()
    if 'cancelled' in sub_lower or 'cancellation' in sub_lower:
        status = 'cancelled'
    elif 'altered' in sub_lower or 'alteration' in sub_lower or 'change of plans' in sub_lower:
        status = 'modified'
    else:
        status = 'confirmed'

    # Try to parse guest + arrival from subject
    guest, arr_date = None, None
    m = re.search(r'-\s*([^-]+?)\s+arrives\s+([A-Z][a-z]+\s+\d{1,2})', sub)
    if m:
        guest = m.group(1).strip()
        arr_text = m.group(2)
        # Map "May 22" → 2026-05-22 (use year of email receipt; bump to next
        # year if month < receipt month and arrival > 6 months ago)
        try:
            month_day = datetime.strptime(arr_text + f' {received.year}', '%b %d %Y')
            # If arrival is "in the past by more than 6 months", roll forward
            if (month_day.date() - received.date()).days < -180:
                month_day = month_day.replace(year=received.year + 1)
            arr_date = month_day.date()
        except ValueError:
            arr_date = None

    return {
        'source_ref':    code,
        'guest_name':    guest,
        'arrival_date':  arr_date,
        'status':        status,
        'raw_subject':   sub,
    }


async def main():
    days_back = int(sys.argv[1] if len(sys.argv) > 1 else 1100)
    print(f'== U96 Airbnb harvester ==')
    print(f'days_back = {days_back}  (~{days_back/30.5:.0f} months)')

    pg_pw = vault('postgres')['password']
    conn = await asyncpg.connect(f'postgresql://postgres:{pg_pw}@homeai-postgres:5432/homeai')
    await conn.execute("SELECT home_ai.set_realm('owner')")

    accounts = ['info', 'admin', 'jo']
    window = 30
    seen, inserted, updated, skipped, parse_fail = 0, 0, 0, 0, 0

    for account in accounts:
        print(f'\n── {account} —')
        for older_days in range(0, days_back, window):
            x, y = older_days, older_days + window
            q = f'from:automated@airbnb.com older_than:{x}d newer_than:{y}d'
            res = gf_get('/messages', account=account, max_results=100, q=q)
            msgs = res.get('messages', [])
            if not msgs:
                continue
            for stub in msgs:
                mid = stub.get('id')
                if not mid: continue
                seen += 1
                msg = gf_get(f'/message/{account}/{mid}')
                if not msg:
                    continue
                headers = {h['name'].lower(): h['value']
                           for h in (msg.get('payload', {}).get('headers') or [])}
                subject = headers.get('subject') or ''
                body = message_body_text(msg)[:5000]
                received_raw = headers.get('date', '')
                try:
                    received_at = datetime.strptime(received_raw[:31].strip(),
                        '%a, %d %b %Y %H:%M:%S %z')
                except Exception:
                    received_at = datetime.now(timezone.utc)
                parsed = parse_airbnb(subject, body, received_at)
                if not parsed:
                    parse_fail += 1
                    continue

                # Upsert: if same source_ref exists, update status only
                # (latest wins — cancellations replace confirmations).
                existing = await conn.fetchrow(
                    "SELECT id, status FROM accommodation_bookings "
                    "WHERE source='airbnb' AND source_ref=$1", parsed['source_ref'])
                if existing:
                    # Update if status changed
                    if existing['status'] != parsed['status']:
                        await conn.execute("""
                            UPDATE accommodation_bookings
                               SET status = $1, source_email_id = $2
                             WHERE id = $3
                        """, parsed['status'], mid, existing['id'])
                        updated += 1
                    else:
                        skipped += 1
                    continue

                async with conn.transaction():
                    await conn.execute("SET LOCAL app.current_entity = '1'")
                    await conn.execute("""
                        INSERT INTO accommodation_bookings
                            (entity_id, source, source_ref, status,
                             guest_name, checkin_date,
                             source_email_id, source_account, booking_type,
                             raw_text, realm)
                        VALUES (1, 'airbnb', $1, $2,
                                $3, $4,
                                $5, $6, 'accommodation',
                                $7, 'work')
                    """, parsed['source_ref'], parsed['status'],
                         parsed['guest_name'], parsed['arrival_date'],
                         mid, account, body[:5000])
                    inserted += 1
            print(f'    batch {x}d..{y}d: seen={seen} ins={inserted} upd={updated} '
                  f'skip={skipped} parse_fail={parse_fail}', flush=True)

    await conn.close()
    print(f'\n== Summary ==')
    print(f'  seen        = {seen}')
    print(f'  inserted    = {inserted}')
    print(f'  updated     = {updated}')
    print(f'  skipped_dup = {skipped}')
    print(f'  parse_fail  = {parse_fail}')


asyncio.run(main())
