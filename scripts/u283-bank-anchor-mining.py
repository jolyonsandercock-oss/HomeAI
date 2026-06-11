#!/usr/bin/env python3
"""u283-bank-anchor-mining.py — mine recurring bank-narrative stems as
candidate counterparty anchors (resolver phase 2 groundwork). REPORT-ONLY:
writes nothing to counterparty_anchor; emails Jo the top candidates for a
one-pass approval. Run inside bot-responder (PG_DSN + vault access).
"""
import asyncio
import html
import json
import os
import re
import urllib.request

import asyncpg

VAULT_TOKEN = os.environ['VAULT_TOKEN']
TO = 'jolyon.sandercock@gmail.com'


def vault(path):
    req = urllib.request.Request(f'http://vault:8200/v1/secret/data/{path}',
                                 headers={'X-Vault-Token': VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']


STEM_RE = re.compile(r'[0-9]{4,}|[*#]|\b\d{2}[A-Z]{3}\b')


def stem(desc: str) -> str:
    """Narrative → stable stem: uppercase, strip refs/dates/numbers."""
    s = (desc or '').upper()
    s = STEM_RE.sub(' ', s)
    s = re.sub(r'\s+', ' ', s).strip()
    return s[:60]


async def main():
    pg = vault('postgres')['password']
    conn = await asyncpg.connect(f'postgresql://postgres:{pg}@homeai-postgres:5432/homeai')
    await conn.execute("SET app.current_entity='all'")
    rows = await conn.fetch("""
        SELECT description, count(*) n, count(DISTINCT entity_id) ents,
               min(transaction_date) mn, max(transaction_date) mx,
               round(sum(abs(amount))::numeric,0) vol
          FROM bank_transactions
         WHERE coalesce(description,'') <> ''
         GROUP BY description""")
    stems: dict[str, dict] = {}
    for r in rows:
        st = stem(r['description'])
        if len(st) < 5:
            continue
        d = stems.setdefault(st, {'n': 0, 'vol': 0, 'ents': set(), 'mn': r['mn'], 'mx': r['mx'], 'ex': r['description']})
        d['n'] += r['n']
        d['vol'] += float(r['vol'] or 0)
        d['mn'] = min(d['mn'], r['mn'])
        d['mx'] = max(d['mx'], r['mx'])

    # candidate counterparty by name-similarity to financial_counterparty
    fcs = await conn.fetch("SELECT id, display_name FROM financial_counterparty WHERE status='active'")
    fc_by_token = {}
    for f in fcs:
        for tok in re.findall(r'[A-Z]{4,}', (f['display_name'] or '').upper()):
            fc_by_token.setdefault(tok, set()).add((f['id'], f['display_name']))

    cands = []
    for st, d in stems.items():
        if d['n'] < 3:
            continue
        matches = set()
        for tok in re.findall(r'[A-Z]{4,}', st):
            matches |= fc_by_token.get(tok, set())
        suggestion = ''
        if len(matches) == 1:
            fid, fname = next(iter(matches))
            suggestion = f'{fname} (#{fid})'
        cands.append((d['n'], d['vol'], st, suggestion, d['mn'], d['mx']))
    cands.sort(key=lambda x: -x[1])
    top = cands[:50]
    await conn.close()

    rows_html = ''.join(
        f'<tr><td style="padding:3px 8px;border-bottom:1px solid #eee">{html.escape(st)}</td>'
        f'<td style="padding:3px 8px;border-bottom:1px solid #eee;text-align:right">{n}</td>'
        f'<td style="padding:3px 8px;border-bottom:1px solid #eee;text-align:right">£{vol:,.0f}</td>'
        f'<td style="padding:3px 8px;border-bottom:1px solid #eee">{html.escape(sug) or "<i>no unambiguous match</i>"}</td>'
        f'<td style="padding:3px 8px;border-bottom:1px solid #eee">{mn:%b %y}–{mx:%b %y}</td></tr>'
        for n, vol, st, sug, mn, mx in top)
    body = (
        '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;max-width:760px">'
        '<p><b>Bank counterparty anchor candidates</b> — recurring narrative stems '
        '(≥3 occurrences), sorted by money volume. Nothing has been written; reply '
        'with the stems to approve (or "approve all unambiguous") and the resolver '
        'gets bank_reference anchors for them — bank attribution then starts in review mode.</p>'
        '<table style="border-collapse:collapse;font-size:12px;width:100%">'
        '<tr><th style="text-align:left;padding:3px 8px">Narrative stem</th>'
        '<th style="text-align:right;padding:3px 8px">Txns</th>'
        '<th style="text-align:right;padding:3px 8px">Volume</th>'
        '<th style="text-align:left;padding:3px 8px">Suggested counterparty</th>'
        '<th style="text-align:left;padding:3px 8px">Span</th></tr>'
        f'{rows_html}</table></div>')
    payload = {'to': TO, 'subject': f'[Home AI] Bank anchor candidates — top {len(top)} recurring narratives',
               'body_html': body, 'body_text': 'HTML email — open in a rich client.'}
    req = urllib.request.Request('http://google-fetch:8011/send/bot',
                                 data=json.dumps(payload).encode(),
                                 headers={'Content-Type': 'application/json'}, method='POST')
    r = urllib.request.urlopen(req, timeout=20)
    print(f'mined {len(cands)} stems, emailed top {len(top)} -> {r.status}')


asyncio.run(main())
