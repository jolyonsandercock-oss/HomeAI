#!/usr/bin/env python3
"""u279-mgmt-email-samples.py — three daily-management-email variants for Jo
to choose from (2026-06-11 request). All real data, u109-v4 styling (tables,
<hr>, 'Wed 11th' dates, colour-coded %). Sent as [SAMPLE A/B/C].

A  One-glance     — KPI strip + exceptions. 15-second read.
B  Day-sheet      — A + arrivals/in-house (with the newly-recovered guest
                    phones), leave today, weather. The operational morning email.
C  Numbers+trend  — A + week-to-date vs last week, month pace, top vendors.

Run: docker exec -i -e VAULT_TOKEN=... homeai-bot-responder python3 - < this
"""
import asyncio
import html
import json
import os
import urllib.request
from datetime import date, timedelta

import asyncpg

VAULT_TOKEN = os.environ['VAULT_TOKEN']
TO = 'jolyon.sandercock@gmail.com'


def vault(path):
    req = urllib.request.Request(f'http://vault:8200/v1/secret/data/{path}',
                                 headers={'X-Vault-Token': VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']


def h(s):
    return html.escape(str(s if s is not None else '—'))


def fmt_day(d: date) -> str:
    n = d.day
    suf = 'th' if 11 <= n <= 13 else {1: 'st', 2: 'nd', 3: 'rd'}.get(n % 10, 'th')
    return d.strftime('%a ') + str(n) + suf


def gbp(x):
    return '—' if x is None else f'£{float(x):,.0f}'


def pct(x, warn=30.0):
    if x is None:
        return '<span style="color:#777">—</span>'
    c = '#c0392b' if float(x) > warn else '#1e8449'
    return f'<span style="color:{c};font-weight:bold">{float(x):.1f}%</span>'


STY = {
    'wrap': 'font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#222;max-width:680px',
    'h2': 'font-size:16px;margin:14px 0 6px',
    'hr': 'border:none;border-top:1px solid #ddd;margin:14px 0',
    'tbl': 'border-collapse:collapse;width:100%;font-size:13px',
    'td': 'padding:4px 8px;border-bottom:1px solid #eee;text-align:left',
    'tdr': 'padding:4px 8px;border-bottom:1px solid #eee;text-align:right',
    'kpi': 'display:inline-block;margin:0 14px 6px 0;font-size:13px',
}


def section(title, body):
    return f'<hr style="{STY["hr"]}"><h2 style="{STY["h2"]}">{h(title)}</h2>{body}'


def table(headers, rows, right_cols=()):
    th = ''.join(f'<th style="{STY["td"]};font-weight:bold">{h(c)}</th>' for c in headers)
    trs = []
    for row in rows:
        tds = []
        for i, c in enumerate(row):
            sty = STY['tdr'] if i in right_cols else STY['td']
            tds.append(f'<td style="{sty}">{c if str(c).startswith("<") else h(c)}</td>')
        trs.append('<tr>' + ''.join(tds) + '</tr>')
    return f'<table style="{STY["tbl"]}"><tr>{th}</tr>{"".join(trs)}</table>'


async def gather(conn):
    """All numbers, each resilient."""
    d = {}
    today = date.today()
    yday = today - timedelta(days=1)
    wk_start = today - timedelta(days=today.weekday())
    lw_start, lw_end = wk_start - timedelta(days=7), wk_start - timedelta(days=1)

    async def one(key, sql, *args):
        try:
            d[key] = await conn.fetchval(sql, *args)
        except Exception:
            d[key] = None

    async def rows(key, sql, *args):
        try:
            d[key] = await conn.fetch(sql, *args)
        except Exception:
            d[key] = []

    await conn.execute("SET app.current_entity='all'")
    # revenue (head_office consolidated — report-exact basis)
    await one('rev_yday', "SELECT sum(value) FROM touchoffice_department_sales WHERE site='head_office' AND report_date=$1", yday)
    await one('rev_wtd', "SELECT sum(value) FROM touchoffice_department_sales WHERE site='head_office' AND report_date BETWEEN $1 AND $2", wk_start, yday)
    await one('rev_lastwk', "SELECT sum(value) FROM touchoffice_department_sales WHERE site='head_office' AND report_date BETWEEN $1 AND $2", lw_start, lw_end)
    await one('rev_mtd', "SELECT sum(value) FROM touchoffice_department_sales WHERE site='head_office' AND report_date >= date_trunc('month',$1::date)", yday)
    # labour (on-costed, report-anchored)
    await one('lab_yday', "SELECT sum(cost_estimate) FROM workforce_shifts WHERE shift_date=$1 AND hours_worked IS NOT NULL", yday)
    await one('lab_wtd', "SELECT sum(cost_estimate) FROM workforce_shifts WHERE shift_date BETWEEN $1 AND $2 AND hours_worked IS NOT NULL", wk_start, yday)
    # rooms
    await one('inhouse', "SELECT count(*) FROM accommodation_bookings WHERE checkin_date<=$1 AND checkout_date>$1 AND status IN ('confirmed','deposit_paid','paid','active')", today)
    await one('arrivals', "SELECT count(*) FROM accommodation_bookings WHERE checkin_date=$1 AND status IN ('confirmed','deposit_paid','paid','active')", today)
    await rows('arrival_rows', """
        SELECT room, guest_name, coalesce(guest_phone,'') phone, coalesce(source,'') src,
               coalesce(adults,0)+coalesce(children,0) pax
          FROM accommodation_bookings
         WHERE checkin_date=$1 AND status IN ('confirmed','deposit_paid','paid','active')
         ORDER BY room""", today)
    # reviews 7d
    await one('rev7_n', "SELECT count(*) FROM guest_reviews WHERE posted_at >= now()-interval '7 days'")
    await one('rev7_avg', "SELECT round(avg(rating),1) FROM guest_reviews WHERE posted_at >= now()-interval '7 days' AND rating IS NOT NULL")
    # leave today
    await rows('leave_rows', """
        SELECT coalesce(u.full_name,'Unknown') nm FROM workforce_shifts s
          LEFT JOIN workforce_users u ON u.external_id=s.user_external_id
         WHERE s.shift_date=$1 AND s.hours_worked IS NULL""", today)
    # weather tomorrow
    await rows('wx', """
        SELECT forecast_date, peak_temp_c, rain_mm FROM weather_forecast
         WHERE forecast_date BETWEEN $1 AND $1+2 ORDER BY forecast_date""", today)
    # spend this week
    await rows('vendors_wk', """
        SELECT coalesce(fc.display_name, vii.vendor_name) v, round(sum(coalesce(vii.net_amount,vii.gross_amount,0))::numeric,0) amt
          FROM vendor_invoice_inbox vii
          LEFT JOIN financial_counterparty fc ON fc.id=vii.counterparty_id
         WHERE vii.received_at >= $1 AND coalesce(vii.is_statement,false)=false
           AND coalesce(vii.net_amount,vii.gross_amount,0) > 0
         GROUP BY 1 ORDER BY 2 DESC LIMIT 5""", wk_start)
    # exceptions
    await one('events_pending', "SELECT count(*) FROM events WHERE status='pending'")
    await one('dl_open', "SELECT count(*) FROM dead_letter WHERE NOT resolved")
    await one('review_q', "SELECT count(*) FROM counterparty_resolution_review_queue WHERE status='open'")
    await one('rota_today', "SELECT count(*) FROM workforce_shifts WHERE shift_date=$1 AND hours_worked IS NOT NULL", today)
    return d


def kpi_strip(d):
    lab_pct = None
    if d['rev_yday'] and d['lab_yday']:
        lab_pct = 100 * float(d['lab_yday']) / float(d['rev_yday'])
    bits = [
        f'<span style="{STY["kpi"]}"><b>Yesterday</b> {gbp(d["rev_yday"])}</span>',
        f'<span style="{STY["kpi"]}"><b>Labour</b> {pct(lab_pct)}</span>',
        f'<span style="{STY["kpi"]}"><b>WTD</b> {gbp(d["rev_wtd"])}</span>',
        f'<span style="{STY["kpi"]}"><b>In-house</b> {h(d["inhouse"])} rooms</span>',
        f'<span style="{STY["kpi"]}"><b>Arrivals</b> {h(d["arrivals"])}</span>',
        f'<span style="{STY["kpi"]}"><b>Reviews 7d</b> {h(d["rev7_n"])} ({h(d["rev7_avg"])}★)</span>',
    ]
    return '<div>' + ''.join(bits) + '</div>'


def exceptions_block(d):
    items = []
    if (d['rota_today'] or 0) == 0:
        items.append('⚠️ <b>No rota published in Tanda for today</b> — staff page is blank.')
    if (d['dl_open'] or 0) > 0:
        items.append(f'⚠️ {d["dl_open"]} unresolved dead-letter event(s).')
    if (d['review_q'] or 0) > 0:
        items.append(f'{d["review_q"]} counterparty review item(s) waiting at /app → review.')
    if not items:
        items.append('✅ No exceptions — pipelines clean, queues empty.')
    return '<br>'.join(items)


def variant_a(d, today):
    body = [f'<div style="{STY["wrap"]}">']
    body.append(kpi_strip(d))
    body.append(section('Exceptions', exceptions_block(d)))
    body.append('</div>')
    return ''.join(body)


def variant_b(d, today):
    body = [f'<div style="{STY["wrap"]}">']
    body.append(kpi_strip(d))
    arr = [[r['room'], f"<b>{h(r['guest_name'])}</b>", r['phone'] or '—', r['src'], r['pax']]
           for r in d['arrival_rows']] or [['—', 'No arrivals today', '', '', '']]
    body.append(section(f'Arrivals — {fmt_day(today)}', table(
        ['Room', 'Guest', 'Phone', 'Source', 'Pax'], arr)))
    lv = ', '.join(h(r['nm']) for r in d['leave_rows']) or 'None'
    body.append(section('On leave today', lv))
    wx = [[fmt_day(r['forecast_date']), f"{r['peak_temp_c']}°C", f"{r['rain_mm']}mm"]
          for r in d['wx']]
    body.append(section('Weather', table(['Day', 'Peak', 'Rain'], wx, right_cols=(1, 2))))
    body.append(section('Exceptions', exceptions_block(d)))
    body.append('</div>')
    return ''.join(body)


def variant_c(d, today):
    body = [f'<div style="{STY["wrap"]}">']
    body.append(kpi_strip(d))
    lab_wtd_pct = None
    if d['rev_wtd'] and d['lab_wtd']:
        lab_wtd_pct = 100 * float(d['lab_wtd']) / float(d['rev_wtd'])
    body.append(section('Trading', table(
        ['', 'Revenue', 'Labour (on-cost)', 'Labour %'],
        [['Yesterday', gbp(d['rev_yday']), gbp(d['lab_yday']),
          pct(100 * float(d['lab_yday']) / float(d['rev_yday'])) if d['rev_yday'] and d['lab_yday'] else '—'],
         ['Week to date', gbp(d['rev_wtd']), gbp(d['lab_wtd']), pct(lab_wtd_pct)],
         ['Last week (full)', gbp(d['rev_lastwk']), '', ''],
         ['Month to date', gbp(d['rev_mtd']), '', '']],
        right_cols=(1, 2, 3))))
    vend = [[h(r['v'])[:40], gbp(r['amt'])] for r in d['vendors_wk']] or [['No invoices yet this week', '']]
    body.append(section('Top spend this week', table(['Vendor', 'Net'], vend, right_cols=(1,))))
    body.append(section('Exceptions', exceptions_block(d)))
    body.append('</div>')
    return ''.join(body)


def send(subject, body_html):
    payload = {'to': TO, 'subject': subject, 'body_html': body_html,
               'body_text': 'HTML email — open in a rich client.'}
    req = urllib.request.Request('http://google-fetch:8011/send/bot',
                                 data=json.dumps(payload).encode(),
                                 headers={'Content-Type': 'application/json'}, method='POST')
    r = urllib.request.urlopen(req, timeout=20)
    print(subject, '->', r.status)


async def main():
    pg = vault('postgres')['password']
    conn = await asyncpg.connect(f'postgresql://postgres:{pg}@homeai-postgres:5432/homeai')
    d = await gather(conn)
    await conn.close()
    today = date.today()
    day = fmt_day(today)
    send(f'[SAMPLE A — one-glance] Daily Management — {day}', variant_a(d, today))
    send(f'[SAMPLE B — day-sheet] Daily Management — {day}', variant_b(d, today))
    send(f'[SAMPLE C — numbers+trend] Daily Management — {day}', variant_c(d, today))


asyncio.run(main())
