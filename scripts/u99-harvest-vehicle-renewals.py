"""u99-harvest-vehicle-renewals.py — Find insurer / DVLA renewal emails
and record them as vehicle_renewal_signals so the action queue
suppresses noisy due-soon alerts when the insurer's already on it.

Matchers:
  - from:axa-insurance.co.uk  + body has known registration → insurance
  - from:dvla.gov.uk          + body has known registration → road_tax
  - subject contains "renewal" + body has known registration → tentative

Idempotent on (vehicle_id, kind, gmail_message_id).

Usage:
  docker exec homeai-bot-responder python3 /tmp/u99.py [days_back=180]
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
        return json.loads(urllib.request.urlopen(url, timeout=20).read())
    except Exception:
        return {}


def message_text(msg: dict) -> str:
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


async def main():
    days_back = int(sys.argv[1] if len(sys.argv) > 1 else 180)
    pg_pw = vault('postgres')['password']
    conn = await asyncpg.connect(f'postgresql://postgres:{pg_pw}@homeai-postgres:5432/homeai')
    await conn.execute("SELECT home_ai.set_realm('owner')")

    vehicles = await conn.fetch("SELECT id, registration FROM vehicles WHERE registration IS NOT NULL")
    veh_map = {v['registration'].upper(): v['id'] for v in vehicles}
    veh_regs = sorted(veh_map.keys())
    print(f'Tracking {len(veh_regs)} vehicles: {veh_regs}', flush=True)

    # Senders -> kind mapping
    sources = [
        ('axa-insurance.co.uk',     'insurance'),
        ('admiral.com',             'insurance'),
        ('directline.com',          'insurance'),
        ('aviva.co.uk',             'insurance'),
        ('towergate.co.uk',         'insurance'),
        ('hastingsdirect.com',      'insurance'),
        ('lv.com',                  'insurance'),
        ('dvla.gov.uk',             'road_tax'),
        ('vehicle-tax-dvla.service.gov.uk', 'road_tax'),
    ]

    stats = {'seen': 0, 'matched': 0, 'inserted': 0, 'skipped': 0}

    for sender, kind in sources:
        for account in ('jo', 'admin'):
            q = f'from:{sender} newer_than:{days_back}d'
            res = gf_get('/messages', account=account, max_results=100, q=q)
            msgs = res.get('messages', [])
            if not msgs: continue
            for stub in msgs:
                mid = stub.get('id')
                if not mid: continue
                stats['seen'] += 1
                msg = gf_get(f'/message/{account}/{mid}')
                if not msg: continue
                headers = {h['name'].lower(): h['value']
                           for h in (msg.get('payload', {}).get('headers') or [])}
                subj = headers.get('subject') or ''
                body = message_text(msg)[:5000]
                date_raw = headers.get('date', '')
                try:
                    signal_at = datetime.strptime(date_raw[:31].strip(),
                                                   '%a, %d %b %Y %H:%M:%S %z')
                except Exception:
                    signal_at = datetime.now(timezone.utc)

                # Find which registration appears in body or subject
                hay = (subj + ' ' + body).upper()
                for reg in veh_regs:
                    if reg in hay:
                        stats['matched'] += 1
                        snippet = body[:200]
                        # Idempotent insert
                        before = await conn.fetchval(
                            "SELECT 1 FROM vehicle_renewal_signals "
                            "WHERE vehicle_id=$1 AND kind=$2 AND gmail_message_id=$3",
                            veh_map[reg], kind, mid)
                        if before:
                            stats['skipped'] += 1
                            continue
                        await conn.execute("""
                            INSERT INTO vehicle_renewal_signals
                                (vehicle_id, kind, signal_at, source, snippet, gmail_message_id)
                            VALUES ($1, $2, $3, $4, $5, $6)
                        """, veh_map[reg], kind, signal_at, sender, snippet, mid)
                        stats['inserted'] += 1
                        print(f'  + {reg} {kind} @ {signal_at.date()} from {sender}',
                              flush=True)
                        break

    await conn.close()
    print()
    print(f'== Summary ==')
    for k, v in stats.items():
        print(f'  {k:9s} = {v}')


asyncio.run(main())
