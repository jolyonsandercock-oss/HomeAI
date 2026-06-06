"""u95-harvest-all-invoices.py — broad invoice-email harvester.

Per Jo's instruction (2026-05-15): "5000+ invoice emails. Search 'invoice'
and 'overdue' across all inboxes. Surface overdue items from last 7 days."

Strategy:
- Three accounts: jo, info, admin.
- Two query shapes per account:
    1) `invoice OR receipt OR bill` — broad invoice capture
    2) `overdue` — separately flagged, recent ones promoted to mart.exceptions
- Window-slice each query in 30-day chunks (google-fetch /messages caps at 100).
- Insert into vendor_invoice_inbox with idempotency key
  `harvest:<account>:<gmail_message_id>`.
- For "overdue" emails received in last 7 days, also raise a mart.exceptions row
  of kind 'invoice_overdue' so the daily digest + /actions surface it.

Usage:
  docker exec homeai-bot-responder python3 /tmp/u95-harvester.py [days_back]
  days_back defaults to 1100 (~36 months).
"""
from __future__ import annotations
import os, sys, re, html as html_mod, json, base64, asyncio, hashlib
import urllib.request, urllib.parse
from datetime import datetime, timezone, timedelta

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
            raw = re.sub(r'<(br|/p|/div|/tr|/li|/td)[^>]*>', '\n', raw, flags=re.I)
            raw = re.sub(r'<[^>]+>', ' ', raw)
            raw = html_mod.unescape(raw)
            raw = re.sub(r'[ \t]+', ' ', raw)
            return raw
        for sub in (part.get('parts') or []):
            t = walk(sub)
            if t: return t
        return None
    return walk(msg.get('payload') or {}) or ''


def has_attachment(payload: dict) -> bool:
    def walk(p):
        body = p.get('body', {}) or {}
        if body.get('attachmentId'): return True
        for s in (p.get('parts') or []):
            if walk(s): return True
        return False
    return walk(payload or {})


def normalise_sender(from_user: str) -> str:
    if not from_user: return ''
    m = re.search(r'<([^>]+@[^>]+)>', from_user)
    if m: return m.group(1).strip().lower()
    if '@' in from_user: return from_user.strip().lower()
    return ''


def parse_gmail_date(s: str) -> datetime:
    try:
        return datetime.strptime(s[:31].strip(), '%a, %d %b %Y %H:%M:%S %z')
    except Exception:
        return datetime.now(timezone.utc)


# Filter rules to AVOID inserting non-invoice noise as invoices.
# These would otherwise pollute the inbox.
SKIP_SUBJECTS = re.compile(
    r'(your booking|new booking received|booking confirmed|reservation confirmed|'
    r're: invoice query|fwd: invoice quer|unsubscribe|customer survey|'
    r'webinar|newsletter)', re.I)
SKIP_SENDERS = {
    'noreply@designmynight.com',           # Collins restaurant — separate stream
    'bookings@hotel-email.com',            # Hotel bookings — separate stream
    'no-reply@accommodation.caterbook.com',
}


async def harvest_one(conn, account, q, days_back, window=30, tag_overdue=False):
    """Run one (account, query) combination, windowed back days_back days."""
    seen = inserted = skipped_dup = skipped_filtered = overdue_raised = 0

    cutoff_7d = datetime.now(timezone.utc) - timedelta(days=7)

    for older_days in range(0, days_back, window):
        x, y = older_days, older_days + window
        qq = f'{q} older_than:{x}d newer_than:{y}d'
        res = gf_get('/messages', account=account, max_results=100, q=qq)
        msgs = res.get('messages', [])
        if not msgs: continue
        for stub in msgs:
            mid = stub.get('id')
            if not mid: continue
            seen += 1

            idem = f'harvest:{account}:{mid}'
            # vendor_invoice_inbox has UNIQUE on both idempotency_key AND source_email_id.
            # Skip if either matches anything we've already got.
            existing = await conn.fetchval(
                "SELECT id FROM vendor_invoice_inbox WHERE idempotency_key=$1 OR source_email_id=$2",
                idem, mid)
            if existing:
                skipped_dup += 1
                continue

            msg = gf_get(f'/message/{account}/{mid}')
            if not msg:
                continue
            headers = {h['name'].lower(): h['value']
                       for h in (msg.get('payload', {}).get('headers') or [])}
            subject  = headers.get('subject') or ''
            from_raw = headers.get('from') or ''
            sender   = normalise_sender(from_raw)
            domain   = sender.split('@', 1)[1] if '@' in sender else ''
            received = parse_gmail_date(headers.get('date', ''))

            # Skip obvious non-invoice traffic
            if SKIP_SUBJECTS.search(subject):
                skipped_filtered += 1
                continue
            if sender in SKIP_SENDERS:
                skipped_filtered += 1
                continue

            body = message_body_text(msg)[:5000]
            has_pdf = has_attachment(msg.get('payload', {}))

            is_overdue = tag_overdue
            ext_method = 'harvest_overdue' if is_overdue else 'harvest_keyword'

            async with conn.transaction():
                await conn.execute("SET LOCAL app.current_entity = '1'")
                await conn.execute("SELECT home_ai.set_realm('work')")

                # Belt-and-braces: also catch the source_email_id collision via
                # a try-except, in case a concurrent ingester races us.
                try:
                    row_id = await conn.fetchval("""
                        INSERT INTO vendor_invoice_inbox
                            (idempotency_key, source_email_id, account,
                             vendor_domain, vendor_name, subject, body_text,
                             received_at, has_pdf, status, extraction_method,
                             pipeline_version, realm)
                        VALUES ($1, $2, $3,
                                $4, $5, $6, $7,
                                $8, $9, 'new', $10,
                                'u95-harvest', 'work')
                        RETURNING id
                    """, idem, mid, account,
                         domain or 'unknown', from_raw, subject, body,
                         received, has_pdf, ext_method)
                except asyncpg.UniqueViolationError:
                    skipped_dup += 1
                    row_id = None

                if row_id is not None:
                    inserted += 1
                    # If this is an OVERDUE within last 7 days, surface as exception
                    if is_overdue and received > cutoff_7d:
                        await conn.execute("""
                            INSERT INTO mart.exceptions
                                (severity, kind, source, transaction_date, summary, detail, status, realm)
                            VALUES ('high', 'invoice_overdue', $1::text, $2::date, $3::text,
                                    jsonb_build_object('vendor_invoice_inbox_id', $4::bigint, 'from', $5::text),
                                    'open', 'work')
                            ON CONFLICT DO NOTHING
                        """, f'gmail/{account}', received.date(),
                             f'OVERDUE invoice from {sender}: {subject[:80]}',
                             row_id, from_raw)
                        overdue_raised += 1

    return {'seen': seen, 'inserted': inserted, 'skipped_dup': skipped_dup,
            'skipped_filtered': skipped_filtered, 'overdue_raised': overdue_raised}


async def main():
    days_back = int(sys.argv[1] if len(sys.argv) > 1 else 1100)
    print(f'== U95 broad invoice harvester ==')
    print(f'days_back = {days_back}  (~{days_back/30.5:.0f} months)')

    pg_pw = vault('postgres')['password']
    conn = await asyncpg.connect(f'postgresql://postgres:{pg_pw}@homeai-postgres:5432/homeai')

    jobs = [
        # (account, query, tag_overdue)
        ('jo',    'invoice OR receipt OR bill OR statement', False),
        ('info',  'invoice OR receipt OR bill OR statement', False),
        ('admin', 'invoice OR receipt OR bill OR statement', False),
        ('jo',    'overdue',                                True),
        ('info',  'overdue',                                True),
        ('admin', 'overdue',                                True),
    ]

    grand = {'seen': 0, 'inserted': 0, 'skipped_dup': 0,
             'skipped_filtered': 0, 'overdue_raised': 0}
    for account, q, tag_overdue in jobs:
        print(f'\n── {account} / {q!r}  (tag_overdue={tag_overdue})', flush=True)
        stats = await harvest_one(conn, account, q, days_back, tag_overdue=tag_overdue)
        print(f'    seen={stats["seen"]} inserted={stats["inserted"]} '
              f'skipped_dup={stats["skipped_dup"]} skipped_filtered={stats["skipped_filtered"]} '
              f'overdue_raised={stats["overdue_raised"]}', flush=True)
        for k in grand: grand[k] += stats[k]

    print(f'\n== Grand totals ==')
    for k, v in grand.items():
        print(f'  {k:18s} = {v}')
    await conn.close()

asyncio.run(main())
