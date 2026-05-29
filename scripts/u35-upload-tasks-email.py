#!/usr/bin/env python3
"""u35-upload-tasks-email.py — emails Jo a checklist of manual data items
that need uploading: dojo CSVs, bank statements, card statements, mortgage
statements, ordered by staleness. Same source as u35-manual-data-freshness
but as an HTML email he can act on at his desk.

Sends via google-fetch (POST /send/bot from jolyboxbot@). Runs on the host;
the HTTP send is shelled into homeai-bot-responder which lives on the
ai-internal docker network with google-fetch.
"""

import datetime as dt
import html
import json
import subprocess
import sys


SQL = r"""
WITH src AS (
  SELECT 'Dojo CSVs' AS source, '(daily drop)' AS label,
         MAX(transaction_date) AS last_dated,
         (CURRENT_DATE - MAX(transaction_date)) AS days_stale,
         1::int AS warn_d, 2::int AS stale_d,
         'csv'::text AS kind
    FROM dojo_transactions
  UNION ALL
  SELECT 'Bank — ' || ba.bank_name, ba.account_name,
         MAX(bt.transaction_date),
         (CURRENT_DATE - MAX(bt.transaction_date)),
         CASE ba.account_type WHEN 'current' THEN 7 WHEN 'credit_card' THEN 40 ELSE 30 END,
         CASE ba.account_type WHEN 'current' THEN 30 WHEN 'credit_card' THEN 70 ELSE 90 END,
         'bank'
    FROM bank_accounts ba
    LEFT JOIN bank_transactions bt ON bt.bank_account_id = ba.id
   WHERE ba.exclude_from_freshness = false
   GROUP BY ba.id, ba.bank_name, ba.account_name, ba.account_type
  UNION ALL
  SELECT 'Card — ' || ba.bank_name, ba.account_name,
         MAX(cs.period_end),
         (CURRENT_DATE - MAX(cs.period_end)),
         40, 70, 'card'
    FROM bank_accounts ba
    LEFT JOIN card_statements cs ON cs.bank_account_id = ba.id
   WHERE ba.account_type = 'credit_card'
     AND ba.account_name NOT ILIKE '%dormant%'
     AND ba.account_name NOT ILIKE '%predecessor%'
   GROUP BY ba.id, ba.bank_name, ba.account_name
  UNION ALL
  SELECT 'Mortgage — ' || ma.lender, ma.account_ref,
         MAX(msp.period_end),
         (CURRENT_DATE - MAX(msp.period_end)),
         40, 90, 'mortgage'
    FROM mortgage_accounts ma
    LEFT JOIN mortgage_statement_periods msp ON msp.mortgage_account_id = ma.id
   WHERE ma.closed_date IS NULL
     AND ma.exclude_from_freshness = false
   GROUP BY ma.id, ma.lender, ma.account_ref
)
SELECT source, label,
       COALESCE(last_dated::text, ''),
       COALESCE(days_stale::text, ''),
       CASE
         WHEN last_dated IS NULL THEN 'never'
         WHEN days_stale > stale_d THEN 'stale'
         WHEN days_stale > warn_d THEN 'warn'
         ELSE 'ok'
       END AS status,
       kind
  FROM src
 WHERE last_dated IS NULL OR days_stale > warn_d
 ORDER BY (kind),
          CASE WHEN last_dated IS NULL THEN 99999 ELSE days_stale END DESC;
"""


STY = {
    'wrap':  ('font-family:-apple-system,Segoe UI,Roboto,sans-serif;'
              'max-width:780px;margin:0 auto;padding:18px;color:#222;line-height:1.45'),
    'h1':    'font-size:22px;font-weight:700;color:#111;margin:0 0 4px 0',
    'sub':   'color:#666;font-size:13px;margin:0 0 16px 0',
    'h2':    ('font-size:15px;font-weight:700;color:#111;'
              'text-transform:uppercase;letter-spacing:.06em;margin:0 0 6px 0'),
    'hr':    'border:0;border-top:1px solid #ddd;margin:18px 0',
    'tbl':   'width:100%;border-collapse:collapse;font-size:14px',
    'th':    ('text-align:left;font-weight:700;color:#555;padding:6px 8px;'
              'border-bottom:1px solid #ddd;font-size:12px;text-transform:uppercase;'
              'letter-spacing:.04em'),
    'td':    'padding:6px 8px;border-bottom:1px solid #f0f0f0;vertical-align:top',
    'banner_warn': ('background:#fef2f2;border-left:4px solid #dc2626;'
                    'padding:10px 14px;margin:0 0 16px 0;color:#7f1d1d;border-radius:4px'),
    'banner_good': ('background:#f0fdf4;border-left:4px solid #16a34a;'
                    'padding:10px 14px;margin:0 0 16px 0;color:#14532d;border-radius:4px'),
    'foot':  ('color:#888;font-size:12px;margin-top:18px;padding-top:12px;'
              'border-top:1px solid #ddd'),
    'pill_stale': ('display:inline-block;padding:2px 8px;border-radius:10px;'
                   'background:#fee2e2;color:#991b1b;font-size:11px;font-weight:700'),
    'pill_warn':  ('display:inline-block;padding:2px 8px;border-radius:10px;'
                   'background:#fef3c7;color:#92400e;font-size:11px;font-weight:700'),
    'pill_never': ('display:inline-block;padding:2px 8px;border-radius:10px;'
                   'background:#e5e7eb;color:#374151;font-size:11px;font-weight:700'),
}


KIND_HEADERS = {
    'csv':      ('Dojo — drop CSVs into /home_ai/data/dojo-inbox/',
                 'Export from Dojo dashboard → "Export transactions" → CSV → '
                 'drop into the inbox dir. Daily cron at 05:30 sweeps and imports.'),
    'bank':     ('Bank statements — upload to Paperless with the matching tag',
                 'Download PDF or CSV from NatWest online banking → upload to '
                 'Paperless → tag with the account.'),
    'card':     ('Credit card statements — upload to Paperless',
                 'Download monthly statement PDF from RBS Mastercard → upload to '
                 'Paperless → tag with the card.'),
    'mortgage': ('Mortgage statements — upload to Paperless',
                 'Download from Principality Commercial → upload to Paperless → '
                 'tag with the account ref. Image-only scans get vision-OCR.'),
}


def fetch_rows():
    proc = subprocess.run(
        ['docker', 'exec', 'homeai-postgres',
         'psql', '-U', 'postgres', '-d', 'homeai', '-tA', '-F', '|', '-c', SQL],
        check=True, capture_output=True, text=True,
    )
    out = []
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split('|')
        if len(parts) != 6:
            continue
        source, label, last_dated, days_stale, status, kind = parts
        out.append({
            'source': source, 'label': label,
            'last_dated': last_dated, 'days_stale': days_stale,
            'status': status, 'kind': kind,
        })
    return out


def pill(status):
    if status == 'stale':
        return f'<span style="{STY["pill_stale"]}">stale</span>'
    if status == 'warn':
        return f'<span style="{STY["pill_warn"]}">warn</span>'
    return f'<span style="{STY["pill_never"]}">never</span>'


def fmt_date(s):
    if not s:
        return '—'
    try:
        d = dt.date.fromisoformat(s)
        return d.strftime('%-d %b %Y')
    except ValueError:
        return s


def fmt_age(days_str):
    if not days_str:
        return '—'
    try:
        n = int(days_str)
    except ValueError:
        return days_str
    if n >= 365:
        return f'{n}d (~{n // 365}y)'
    if n >= 30:
        return f'{n}d (~{n // 30}mo)'
    return f'{n}d'


def section(title, blurb, body):
    return (f'<hr style="{STY["hr"]}">'
            f'<h2 style="{STY["h2"]}">{html.escape(title)}</h2>'
            f'<p style="{STY["sub"]}">{html.escape(blurb)}</p>'
            f'{body}')


def render(rows):
    today = dt.date.today()
    parts = [f'<div style="{STY["wrap"]}">']
    parts.append(f'<h1 style="{STY["h1"]}">Upload tasks — {today.strftime("%a %-d %b %Y")}</h1>')

    stale_n = sum(1 for r in rows if r['status'] == 'stale')
    warn_n  = sum(1 for r in rows if r['status'] == 'warn')
    never_n = sum(1 for r in rows if r['status'] == 'never')

    if not rows:
        parts.append(f'<div style="{STY["banner_good"]}"><strong>✓ All caught up.</strong> '
                     'No manual data uploads needed today.</div>')
    else:
        parts.append(
            f'<div style="{STY["banner_warn"]}">'
            f'<strong>{len(rows)} item{"s" if len(rows)!=1 else ""} to upload</strong> · '
            f'{stale_n} stale · {warn_n} warn · {never_n} never imported. '
            'Each section below lists what to grab and where to put it.'
            '</div>'
        )

    by_kind = {}
    for r in rows:
        by_kind.setdefault(r['kind'], []).append(r)

    for kind in ('csv', 'bank', 'card', 'mortgage'):
        items = by_kind.get(kind, [])
        if not items:
            continue
        title, blurb = KIND_HEADERS[kind]
        rows_html = []
        rows_html.append(
            f'<table style="{STY["tbl"]}">'
            f'<tr>'
            f'<th style="{STY["th"]}">Account</th>'
            f'<th style="{STY["th"]}">Last data</th>'
            f'<th style="{STY["th"]}">Age</th>'
            f'<th style="{STY["th"]}">Status</th>'
            f'</tr>'
        )
        for it in items:
            rows_html.append(
                f'<tr>'
                f'<td style="{STY["td"]}">'
                f'☐ <strong>{html.escape(it["source"])}</strong><br>'
                f'<span style="color:#666;font-size:13px">{html.escape(it["label"])}</span>'
                f'</td>'
                f'<td style="{STY["td"]}">{html.escape(fmt_date(it["last_dated"]))}</td>'
                f'<td style="{STY["td"]}">{html.escape(fmt_age(it["days_stale"]))}</td>'
                f'<td style="{STY["td"]}">{pill(it["status"])}</td>'
                f'</tr>'
            )
        rows_html.append('</table>')
        parts.append(section(title, blurb, '\n'.join(rows_html)))

    parts.append(
        f'<p style="{STY["foot"]}">Generated by u35-upload-tasks-email. '
        'Daily Telegram summary fires at 08:00 (u35-manual-data-freshness). '
        'Thresholds: bank current 7/30d, credit card 40/70d, mortgage 40/90d, dojo 1/2d.'
        '</p>'
    )
    parts.append('</div>')
    return '\n'.join(parts), stale_n, warn_n, never_n


SEND_SHIM = r"""
import json, sys, urllib.request
payload = json.load(sys.stdin)
req = urllib.request.Request(
    'http://google-fetch:8011/send/bot',
    data=json.dumps(payload).encode(),
    headers={'Content-Type': 'application/json'},
    method='POST',
)
r = urllib.request.urlopen(req, timeout=15)
resp = json.loads(r.read())
print(f'status={r.status} msg_id={resp.get("message_id")}')
"""


def send_email(payload):
    proc = subprocess.run(
        ['docker', 'exec', '-i', 'homeai-bot-responder', 'python3', '-c', SEND_SHIM],
        input=json.dumps(payload), check=True, capture_output=True, text=True,
    )
    return proc.stdout.strip()


def main():
    rows = fetch_rows()
    html_body, stale_n, warn_n, never_n = render(rows)
    today = dt.date.today().strftime('%a %-d %b')
    subject = (f'[Home AI] Upload tasks — {today} · '
               f'{len(rows)} items ({stale_n} stale, {warn_n} warn, {never_n} never)')
    if not rows:
        subject = f'[Home AI] Upload tasks — {today} · ✓ all caught up'
    text_body = (
        f'{len(rows)} manual-data items to upload today. '
        f'{stale_n} stale, {warn_n} warn, {never_n} never imported. '
        'Open the HTML version for the checklist.'
    )
    payload = {
        'to': 'jolyon.sandercock@gmail.com',
        'subject': subject,
        'body_html': html_body,
        'body_text': text_body,
    }
    res = send_email(payload)
    print(f'sent: {res} ({len(rows)} rows)')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as e:
        print(f'✗ subprocess failed: {e}\nstderr: {e.stderr}', file=sys.stderr)
        sys.exit(1)
