"""u109-daily-reality.py — v4 HTML daily reality email.

Changes from v3 (per Jo 2026-05-16 feedback):
  - HTML tables (was plain text)
  - Bold guest names + section titles
  - <hr> line separators between sections
  - Date format "Wed 16th" (abbreviated day + ordinal)
  - REMOVED: cash, open actions, 'hotel_email' label, DMN ref,
             yesterday's till section
  - ADDED: payment status + chargeable amount on departure line
  - ADDED: empty rooms to sell / clean today
  - ADDED: weather warning banner (negative for rain/cold, positive for sun)
  - ADDED: surf report (open-meteo marine) for Trebarwith Strand
  - Colour-coded % (red bold > 30%, green bold <= 30%)
  - Tide times deferred — no source available without auth

Sent FROM jolyboxbot TO jolyon.sandercock@gmail.com only.
TEST mode lock — never sends to guests.
"""
import urllib.request, json, asyncio, os, re, html
from datetime import date, timedelta
import asyncpg

VAULT_TOKEN = os.environ['VAULT_TOKEN']


def vault(path):
    req = urllib.request.Request(
        f'http://vault:8200/v1/secret/data/{path}',
        headers={'X-Vault-Token': VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']


# ─── known rooms (used to derive "empty" set) ─────────────────────────────
# Drawn from accommodation_bookings DISTINCT room values, deduped to a
# canonical owner-side list.
ROOMS_MASTER = [
    'Room 1 - Double Room',
    'Room 2 - Family Room',
    'Room 3 - Double Room',
    'Room 4 - Single Room',
    'Room 5 - Double Room',
    'Room 6 - Double Room',
    'Room 7 - Twin Room',
    'Room 8 - Double Room',
    'Garden Suite',
    'The Flat',
]


def canon_room(s):
    """Map free-text room strings to a canonical room name. Returns None
    if the row doesn't match a known room (probably noise)."""
    if not s:
        return None
    s = s.strip()
    m = re.match(r'(?:View on (?:Airbnb|Agoda|Booking)\s+)?(Room\s*\d+)', s, re.I)
    if m:
        n = m.group(1).replace(' ', '')[4:]
        # Find the master entry that starts with this room number
        for r in ROOMS_MASTER:
            if r.startswith(f'Room {n} '):
                return r
    if 'garden' in s.lower():
        return 'Garden Suite'
    if 'flat' in s.lower() or 'the f' in s.lower():
        return 'The Flat'
    return None


# Open-Meteo WMO codes → labels
WMO = {0:'clear', 1:'mainly clear', 2:'partly cloudy', 3:'overcast',
       45:'fog', 48:'rime fog', 51:'light drizzle', 53:'drizzle', 55:'heavy drizzle',
       56:'freezing drizzle', 57:'freezing drizzle',
       61:'light rain', 63:'rain', 65:'heavy rain',
       66:'freezing rain', 67:'freezing rain',
       71:'light snow', 73:'snow', 75:'heavy snow', 77:'snow grains',
       80:'rain showers', 81:'heavy showers', 82:'violent showers',
       85:'snow showers', 86:'heavy snow showers',
       95:'thunderstorm', 96:'thunderstorm + hail', 99:'severe thunderstorm + hail'}


def weather_today_tomorrow():
    try:
        url = ('https://api.open-meteo.com/v1/forecast?latitude=50.66&longitude=-4.75'
               '&daily=temperature_2m_max,temperature_2m_min,weather_code,'
               'precipitation_probability_max,wind_speed_10m_max'
               '&timezone=Europe%2FLondon&forecast_days=2')
        d = json.loads(urllib.request.urlopen(url, timeout=8).read())['daily']
        out = {}
        for label, idx in (('today', 0), ('tomorrow', 1)):
            out[label] = {
                'date':  d['time'][idx],
                'tmax':  d['temperature_2m_max'][idx],
                'tmin':  d['temperature_2m_min'][idx],
                'desc':  WMO.get(d['weather_code'][idx], '?'),
                'rain':  d['precipitation_probability_max'][idx],
                'wind':  d['wind_speed_10m_max'][idx],
                'code':  d['weather_code'][idx],
            }
        return out
    except Exception as e:
        return {'error': str(e)[:80]}


def surf_today_tomorrow():
    """Open-Meteo marine — Trebarwith Strand approx (50.66 N 4.75 W)."""
    try:
        url = ('https://marine-api.open-meteo.com/v1/marine?latitude=50.66&longitude=-4.75'
               '&daily=wave_height_max,wave_period_max,wave_direction_dominant'
               '&timezone=Europe%2FLondon&forecast_days=2')
        d = json.loads(urllib.request.urlopen(url, timeout=8).read())['daily']
        out = {}
        for label, idx in (('today', 0), ('tomorrow', 1)):
            out[label] = {
                'h':  d['wave_height_max'][idx],
                'p':  d['wave_period_max'][idx],
                'dir': d['wave_direction_dominant'][idx],
            }
        return out
    except Exception as e:
        return {'error': str(e)[:80]}


def deg_to_compass(deg):
    if deg is None:
        return '?'
    dirs = ['N','NNE','NE','ENE','E','ESE','SE','SSE',
            'S','SSW','SW','WSW','W','WNW','NW','NNW']
    return dirs[int((deg + 11.25) % 360 // 22.5)]


def surf_quality(h, p):
    if h is None or p is None:
        return 'unknown'
    if h < 0.6: return 'flat'
    if h < 1.0: return 'small but clean' if p >= 8 else 'small'
    if h < 1.5: return 'rideable' if p >= 8 else 'mushy'
    if h < 2.5: return 'good surf' if p >= 8 else 'choppy'
    return 'big — experienced only' if p >= 9 else 'big and messy'


def weather_warning(w):
    """Returns (kind, text) for a banner. kind ∈ {'good','warn',None}."""
    if 'error' in w:
        return None, None
    t = w.get('today', {})
    tmax, rain, wind, code = t.get('tmax', 0), t.get('rain', 0), t.get('wind', 0), t.get('code', 0)
    # Negative warnings
    if rain >= 70 or code in (65, 67, 75, 82, 86, 95, 96, 99):
        return 'warn', f"Wet day expected ({rain}% rain, {t.get('desc','?')}). Push indoor activities; expect cancellations for cliff walks."
    if tmax < 8:
        return 'warn', f"Cold day ({tmax:.0f}°C max). Confirm heating + push hot lunches."
    if wind >= 50:
        return 'warn', f"Strong wind ({wind:.0f} km/h). Outdoor seating likely unusable."
    # Positive
    if tmax >= 21 and rain <= 25:
        return 'good', f"Warm sunny day ({tmax:.0f}°C, {rain}% rain). Push beer garden, coast walks, ice-cream pairings."
    if tmax >= 17 and rain <= 35:
        return 'good', f"Pleasant day ({tmax:.0f}°C, {rain}% rain). Decent for outdoor service."
    return None, None


def ordinal(n):
    if 11 <= (n % 100) <= 13:
        return f"{n}th"
    return f"{n}{ {1:'st',2:'nd',3:'rd'}.get(n%10,'th') }"


def fmt_day(d):
    """Wed 16th"""
    return f"{d.strftime('%a')} {ordinal(d.day)}"


def fmt_pct(c, s):
    """Colour + bold span: red > 30%, green <= 30%."""
    if s <= 0:
        return '<span style="color:#777">—</span>'
    p = c / s * 100
    colour = '#dc2626' if p > 30 else '#16a34a'
    return f'<span style="color:{colour};font-weight:bold">{p:.1f}%</span>'


def source_label(src):
    """Friendly source label. Hides 'hotel_email' per Jo's request — just
    returns empty for hotel_email rows."""
    if not src:
        return ''
    if src == 'hotel_email':
        return ''
    m = {
        'caterbook_pdf':     'Caterbook',
        'caterbook_airbnb':  'Airbnb',
        'caterbook_agoda':   'Agoda',
        'caterbook_booking': 'Booking.com',
        'caterbook_expedia': 'Expedia',
        'caterbook_direct':  'Direct',
        'direct_airbnb':     'Airbnb',
        'collins':           'Collins',
        'dmn':               'DMN',
    }
    return m.get(src, src)


def pay_badge(status, amount):
    """Departure line payment + amount cell."""
    s = (status or '').lower()
    if s in ('paid', 'paid_in_full'):
        colour = '#16a34a'
        label = 'paid'
    elif s in ('deposit_paid', 'partial'):
        colour = '#d97706'
        label = 'deposit'
    elif s == 'unpaid':
        colour = '#dc2626'
        label = 'unpaid'
    else:
        colour = '#777'
        label = s or '?'
    amt = f"£{amount:,.2f}" if amount else '—'
    return f'<span style="color:{colour};font-weight:bold">{html.escape(label)}</span> · {amt}'


def h(s):
    return html.escape(str(s)) if s is not None else ''


# ─── HTML helpers ─────────────────────────────────────────────────────────
STY = {
    'wrap':  'font-family:-apple-system,Segoe UI,Roboto,sans-serif;'
             'max-width:780px;margin:0 auto;padding:18px;color:#222;line-height:1.45',
    'h1':    'font-size:22px;font-weight:700;color:#111;margin:0 0 4px 0',
    'sub':   'color:#666;font-size:13px;margin:0 0 16px 0',
    'h2':    'font-size:15px;font-weight:700;color:#111;'
             'text-transform:uppercase;letter-spacing:.06em;margin:0 0 6px 0',
    'cnt':   'color:#666;font-size:13px;font-weight:400;text-transform:none;'
             'letter-spacing:0;margin-left:6px',
    'hr':    'border:0;border-top:1px solid #ddd;margin:18px 0',
    'tbl':   'width:100%;border-collapse:collapse;font-size:14px',
    'th':    'text-align:left;font-weight:700;color:#555;padding:6px 8px;'
             'border-bottom:1px solid #ddd;font-size:12px;text-transform:uppercase;'
             'letter-spacing:.04em',
    'td':    'padding:6px 8px;border-bottom:1px solid #f0f0f0;vertical-align:top',
    'banner_warn':'background:#fef2f2;border-left:4px solid #dc2626;'
             'padding:10px 14px;margin:0 0 16px 0;color:#7f1d1d;border-radius:4px',
    'banner_good':'background:#f0fdf4;border-left:4px solid #16a34a;'
             'padding:10px 14px;margin:0 0 16px 0;color:#14532d;border-radius:4px',
    'banner_info':'background:#eff6ff;border-left:4px solid #2563eb;'
             'padding:10px 14px;margin:0 0 16px 0;color:#1e3a8a;border-radius:4px',
    'empty': 'color:#999;font-style:italic;font-size:13px;margin:4px 0',
    'foot':  'color:#888;font-size:12px;margin-top:18px;padding-top:12px;'
             'border-top:1px solid #ddd',
}


def section(title, count, body):
    title_html = (f'<h2 style="{STY["h2"]}">{h(title)}'
                  + (f'<span style="{STY["cnt"]}">({count})</span>' if count is not None else '')
                  + '</h2>')
    return f'<hr style="{STY["hr"]}">\n{title_html}\n{body}'


async def main():
    pg_pw = vault('postgres')['password']
    conn = await asyncpg.connect(f'postgresql://postgres:{pg_pw}@homeai-postgres:5432/homeai')
    await conn.execute("SELECT home_ai.set_realm('owner')")

    today = date.today()
    tomorrow = today + timedelta(days=1)

    arrivals = await conn.fetch("""
        SELECT id, guest_name, room, source, gross_amount, payment_status
          FROM accommodation_bookings
         WHERE checkin_date = $1
           AND status IN ('confirmed','deposit_paid','paid','active')
         ORDER BY room, id
    """, today)
    staythroughs = await conn.fetch("""
        SELECT id, guest_name, room, source, checkout_date, gross_amount, payment_status
          FROM accommodation_bookings
         WHERE checkin_date < $1 AND checkout_date > $1
           AND status IN ('confirmed','deposit_paid','paid','active')
         ORDER BY checkout_date, room
    """, today)
    departures = await conn.fetch("""
        SELECT id, guest_name, room, source, gross_amount, total_amount, payment_status
          FROM accommodation_bookings
         WHERE checkout_date = $1
           AND status IN ('confirmed','deposit_paid','paid','active')
         ORDER BY room
    """, today)
    covers = await conn.fetch("""
        SELECT id, source_ref, reservation_at, guest_name, party_size, booking_type
          FROM restaurant_reservations
         WHERE reservation_at::date = $1
           AND status IN ('confirmed','enquiry','arrived')
         ORDER BY reservation_at
    """, today)
    cross = await conn.fetch("SELECT * FROM v_today_stay_dine_crosslink")
    tom_arrivals = await conn.fetch("""
        SELECT guest_name, room, source, gross_amount, payment_status
          FROM accommodation_bookings
         WHERE checkin_date = $1
           AND status IN ('confirmed','deposit_paid','paid','active')
         ORDER BY room
    """, tomorrow)

    kpi = await conn.fetchrow("SELECT * FROM v_today_kpis_work")

    # Cost/income ratio + shift roster anchored on YESTERDAY (Jo 2026-05-16:
    # "make the cost/income for the previous day").
    yest = today - timedelta(days=1)

    shifts_team = await conn.fetch("""
        SELECT team, department_name, hours, cost_with_oncost, staff_count, report_date
          FROM v_daily_labour_by_team
         WHERE report_date = $1 ORDER BY cost_with_oncost DESC NULLS LAST
    """, yest)
    sht = shifts_team
    shift_date = yest

    # Per-person shifts yesterday, with names + start/end + team — for
    # service-period roster (breakfast / lunch / dinner / housekeeping / cafe).
    shifts_people = await conn.fetch("""
        SELECT
          COALESCE(NULLIF(u.preferred_name,''), u.full_name, 'unknown') AS name,
          d.team,
          to_char(s.start_time AT TIME ZONE 'Europe/London', 'HH24:MI') AS start_h,
          to_char(s.end_time   AT TIME ZONE 'Europe/London', 'HH24:MI') AS end_h,
          EXTRACT(HOUR FROM (s.start_time AT TIME ZONE 'Europe/London'))::int AS start_hr,
          s.hours_worked
          FROM workforce_shifts s
          LEFT JOIN workforce_users u ON u.external_id = s.user_external_id
          LEFT JOIN workforce_departments d ON d.external_id = s.department_external_id
         WHERE s.shift_date = $1
         ORDER BY s.start_time, name
    """, yest)

    # Yesterday's sales (the only ratio we show now)
    sales_rows = await conn.fetch("""
        SELECT site, SUM(value)::numeric(10,2) net_sales
          FROM touchoffice_department_sales
         WHERE report_date = $1
         GROUP BY site
    """, yest)
    sales_map = {r['site']: float(r['net_sales']) for r in sales_rows}
    sales_date = yest

    # Target sales — last 8 same-DOW averages × 1.05 (push for growth).
    # Target labour cost = 28% of target sales (Jo's amber = 30%).
    dow_target_rows = await conn.fetch("""
        WITH same_dow AS (
          SELECT site, report_date, SUM(value) AS day_total
            FROM touchoffice_department_sales
           WHERE EXTRACT(DOW FROM report_date) = EXTRACT(DOW FROM $1::date)
             AND report_date BETWEEN $1::date - INTERVAL '8 weeks' AND $1::date - INTERVAL '1 day'
           GROUP BY site, report_date
        )
        SELECT site, ROUND(AVG(day_total)::numeric, 2) AS avg_dow
          FROM same_dow GROUP BY site
    """, yest)
    target_map = {r['site']: float(r['avg_dow']) * 1.05 for r in dow_target_rows}
    LABOUR_PCT_TARGET = 0.28  # decision: target = 28%, amber line = 30%

    deliveries = await conn.fetch("""
        SELECT v.id, v.vendor_name, v.vendor_domain, v.delivery_date,
               COALESCE(v.gross_amount, v.amount_seen) AS amount
          FROM vendor_invoice_inbox v
         WHERE v.delivery_date BETWEEN $1 AND $2
           AND v.status NOT IN ('duplicate','ignored','superseded')
         ORDER BY v.delivery_date, v.vendor_name
    """, today, today + timedelta(days=1))

    wx   = weather_today_tomorrow()
    surf = surf_today_tomorrow()
    wkind, wtext = weather_warning(wx)

    # ── Room state today ────────────────────────────────────────────────
    # occupied_tonight: someone is in the room tonight (arrival or stay-through)
    # departing_today: someone left this morning — needs turnover
    # to_sell: empty tonight (master − occupied_tonight)
    # turnover_with_arrival: cleaned before today's arrival
    # turnover_no_arrival: cleaned and available to sell
    occupied_tonight = set()
    for r in list(arrivals) + list(staythroughs):
        c = canon_room(r['room'])
        if c:
            occupied_tonight.add(c)
    departing_today = set()
    for d in departures:
        c = canon_room(d['room'])
        if c:
            departing_today.add(c)
    to_sell = [r for r in ROOMS_MASTER if r not in occupied_tonight]
    turnover_with_arrival = sorted(departing_today & occupied_tonight)
    turnover_no_arrival   = sorted(departing_today - occupied_tonight)

    # ── Build HTML ──────────────────────────────────────────────────────
    out = [f'<div style="{STY["wrap"]}">']
    out.append(f'<h1 style="{STY["h1"]}">Daily reality — {fmt_day(today)} {today.strftime("%B %Y")}</h1>')
    out.append(f'<p style="{STY["sub"]}">Olde Malthouse · Tintagel · TEST mode (no guest emails sent)</p>')

    # Weather banner
    if wkind == 'warn':
        out.append(f'<div style="{STY["banner_warn"]}"><strong>⚠ Weather:</strong> {h(wtext)}</div>')
    elif wkind == 'good':
        out.append(f'<div style="{STY["banner_good"]}"><strong>☀ Weather:</strong> {h(wtext)}</div>')

    # Weather + surf table
    wx_body = ['<table style="' + STY["tbl"] + '">',
               f'<tr><th style="{STY["th"]}">When</th>'
               f'<th style="{STY["th"]}">Temp</th>'
               f'<th style="{STY["th"]}">Rain</th>'
               f'<th style="{STY["th"]}">Wind</th>'
               f'<th style="{STY["th"]}">Conditions</th>'
               f'<th style="{STY["th"]}">Swell (Trebarwith)</th></tr>']
    if 'error' not in wx:
        for lbl, d in (('Today', today), ('Tomorrow', tomorrow)):
            key = 'today' if lbl == 'Today' else 'tomorrow'
            w = wx[key]
            s = surf.get(key, {}) if 'error' not in surf else {}
            surf_cell = (f"{s['h']:.1f}m @ {s['p']:.0f}s {deg_to_compass(s['dir'])} "
                         f"<span style='color:#666'>· {surf_quality(s['h'], s['p'])}</span>"
                         if s else '<span style="color:#999">—</span>')
            out_line = (f'<td style="{STY["td"]}"><strong>{lbl}</strong></td>'
                        f'<td style="{STY["td"]}">{w["tmin"]:.0f}–{w["tmax"]:.0f}°C</td>'
                        f'<td style="{STY["td"]}">{int(w["rain"])}%</td>'
                        f'<td style="{STY["td"]}">{w["wind"]:.0f} km/h</td>'
                        f'<td style="{STY["td"]}">{h(w["desc"])}</td>'
                        f'<td style="{STY["td"]}">{surf_cell}</td>')
            wx_body.append(f'<tr>{out_line}</tr>')
    wx_body.append('</table>')
    out.append(section('Weather + surf', None, '\n'.join(wx_body)))
    out.append(f'<p style="{STY["empty"]}">Tide times: source integration pending (no free '
               'API responded without auth).</p>')

    # Arrivals
    if arrivals:
        cross_ids = {x['booking_id'] for x in cross}
        rows = []
        for a in arrivals:
            star = ' ★' if a['id'] in cross_ids else ''
            src = source_label(a['source'])
            src_html = f'<span style="color:#888;font-size:12px">{h(src)}</span>' if src else ''
            rows.append(
                f'<tr>'
                f'<td style="{STY["td"]}"><strong>{h(a["guest_name"])}</strong>{star}</td>'
                f'<td style="{STY["td"]}">{h(a["room"])}</td>'
                f'<td style="{STY["td"]}">{pay_badge(a["payment_status"], a["gross_amount"])}</td>'
                f'<td style="{STY["td"]}">{src_html}</td>'
                f'</tr>')
        body = (f'<table style="{STY["tbl"]}">'
                f'<tr><th style="{STY["th"]}">Guest</th>'
                f'<th style="{STY["th"]}">Room</th>'
                f'<th style="{STY["th"]}">Payment</th>'
                f'<th style="{STY["th"]}">Source</th></tr>'
                + '\n'.join(rows) + '</table>')
    else:
        body = f'<p style="{STY["empty"]}">No arrivals today.</p>'
    out.append(section('Arriving tonight', len(arrivals), body))

    # Stay-throughs
    if staythroughs:
        cross_ids = {x['booking_id'] for x in cross}
        rows = []
        for s in staythroughs:
            star = ' ★' if s['id'] in cross_ids else ''
            rows.append(
                f'<tr>'
                f'<td style="{STY["td"]}"><strong>{h(s["guest_name"])}</strong>{star}</td>'
                f'<td style="{STY["td"]}">{h(s["room"])}</td>'
                f'<td style="{STY["td"]}">checks out <strong>{fmt_day(s["checkout_date"])}</strong></td>'
                f'</tr>')
        body = (f'<table style="{STY["tbl"]}">'
                f'<tr><th style="{STY["th"]}">Guest</th>'
                f'<th style="{STY["th"]}">Room</th>'
                f'<th style="{STY["th"]}">Departing</th></tr>'
                + '\n'.join(rows) + '</table>')
    else:
        body = f'<p style="{STY["empty"]}">Nobody mid-stay.</p>'
    out.append(section('Stay-throughs', len(staythroughs), body))

    # Departures
    if departures:
        rows = []
        for d in departures:
            amt = d['total_amount'] or d['gross_amount']
            rows.append(
                f'<tr>'
                f'<td style="{STY["td"]}"><strong>{h(d["guest_name"])}</strong></td>'
                f'<td style="{STY["td"]}">{h(d["room"])}</td>'
                f'<td style="{STY["td"]}">{pay_badge(d["payment_status"], amt)}</td>'
                f'</tr>')
        body = (f'<table style="{STY["tbl"]}">'
                f'<tr><th style="{STY["th"]}">Guest</th>'
                f'<th style="{STY["th"]}">Room</th>'
                f'<th style="{STY["th"]}">Payment</th></tr>'
                + '\n'.join(rows) + '</table>')
    else:
        body = f'<p style="{STY["empty"]}">No departures today.</p>'
    out.append(section(f'Departing — {fmt_day(today)}', len(departures), body))

    # Empty rooms + housekeeping
    body_parts = []
    if to_sell:
        body_parts.append(
            f'<p><strong>To sell tonight</strong> ({len(to_sell)}):<br>'
            + ', '.join(f'<span style="font-weight:600">{h(r)}</span>' for r in to_sell)
            + '</p>')
    else:
        body_parts.append(f'<p style="{STY["empty"]}">All rooms occupied tonight.</p>')
    if turnover_with_arrival:
        body_parts.append(
            f'<p><strong>To clean before arrival</strong> ({len(turnover_with_arrival)}):<br>'
            + ', '.join(f'<span style="font-weight:600;color:#dc2626">{h(r)}</span>'
                        for r in turnover_with_arrival)
            + '</p>')
    if turnover_no_arrival:
        body_parts.append(
            f'<p><strong>To clean (no arrival — open for sale)</strong> '
            f'({len(turnover_no_arrival)}):<br>'
            + ', '.join(f'<span style="font-weight:600;color:#d97706">{h(r)}</span>'
                        for r in turnover_no_arrival)
            + '</p>')
    out.append(section('Rooms — sell + clean', None, '\n'.join(body_parts)))

    # Dining tonight
    if covers:
        cross_res = {x['reservation_id'] for x in cross}
        rows = []
        for c in covers:
            t = c['reservation_at'].strftime('%H:%M') if c['reservation_at'] else '?'
            star = ' ★' if c['id'] in cross_res else ''
            bt = (c['booking_type'] or '').replace('_', ' ')
            rows.append(
                f'<tr>'
                f'<td style="{STY["td"]}">{h(t)}</td>'
                f'<td style="{STY["td"]}"><strong>{h(c["guest_name"])}</strong>{star}</td>'
                f'<td style="{STY["td"]}">{c["party_size"] or 0} pax</td>'
                f'<td style="{STY["td"]}">{h(bt)}</td>'
                f'</tr>')
        pax_total = sum(c['party_size'] or 0 for c in covers)
        body = (f'<table style="{STY["tbl"]}">'
                f'<tr><th style="{STY["th"]}">Time</th>'
                f'<th style="{STY["th"]}">Guest</th>'
                f'<th style="{STY["th"]}">Party</th>'
                f'<th style="{STY["th"]}">Type</th></tr>'
                + '\n'.join(rows) + '</table>'
                + f'<p style="color:#666;font-size:13px;margin-top:6px">'
                  f'<strong>{len(covers)}</strong> bookings · <strong>{pax_total}</strong> pax</p>')
    else:
        body = f'<p style="{STY["empty"]}">No reservations on the book.</p>'
    out.append(section('Dining tonight', len(covers), body))

    # VIP cross-link
    if cross:
        rows = []
        for x in cross:
            t = x['reservation_at'].strftime('%H:%M') if x['reservation_at'] else '?'
            rows.append(
                f'<tr>'
                f'<td style="{STY["td"]}">★ <strong>{h(x["staying_as"])}</strong></td>'
                f'<td style="{STY["td"]}">{h(x["room"])}</td>'
                f'<td style="{STY["td"]}">dining {h(t)} · {x["party_size"]} pax · '
                f'{h((x["booking_type"] or "").replace("_"," "))}</td>'
                f'</tr>')
        body = f'<table style="{STY["tbl"]}">' + '\n'.join(rows) + '</table>'
        out.append(section('VIP — staying AND dining tonight', len(cross), body))

    # Staff roster by service period (breakfast / lunch / dinner / housekeeping / cafe)
    #   - Breakfast = pub kitchen+FOH starting before 10:00
    #   - Lunch     = pub kitchen+FOH starting 10:00–14:00
    #   - Dinner    = pub kitchen+FOH starting 14:00 or later
    #   - Housekeeping = team='accommodation' (any time)
    #   - Cafe         = team='cafe' (any time)
    buckets = {
        'Breakfast — Kitchen':   [], 'Breakfast — Front of house': [],
        'Lunch — Kitchen':       [], 'Lunch — Front of house':     [],
        'Dinner — Kitchen':      [], 'Dinner — Front of house':    [],
        'Housekeeping':          [],
        'Cafe':                  [],
    }
    for p in shifts_people:
        team = (p['team'] or '').lower()
        sh = p['start_hr']
        label_team = 'Kitchen' if team == 'kitchen' else 'Front of house'
        if team == 'accommodation':
            buckets['Housekeeping'].append(p)
        elif team == 'cafe':
            buckets['Cafe'].append(p)
        elif team in ('kitchen', 'front_of_house'):
            if sh is None:
                period = 'Dinner'
            elif sh < 10:
                period = 'Breakfast'
            elif sh < 14:
                period = 'Lunch'
            else:
                period = 'Dinner'
            buckets[f'{period} — {label_team}'].append(p)

    def fmt_person(p):
        nm = (p['name'] or '?').replace('  ', ' ').strip()
        if p['start_h'] and p['end_h']:
            return f'<strong>{h(nm)}</strong> <span style="color:#666">{h(p["start_h"])}–{h(p["end_h"])}</span>'
        return f'<strong>{h(nm)}</strong> <span style="color:#999">(no times)</span>'

    roster_rows = []
    for label, people in buckets.items():
        if not people:
            continue
        cell = ' · '.join(fmt_person(p) for p in people)
        roster_rows.append(
            f'<tr>'
            f'<td style="{STY["td"]};white-space:nowrap"><strong>{h(label)}</strong></td>'
            f'<td style="{STY["td"]}">{cell}</td>'
            f'<td style="{STY["td"]};text-align:right;color:#666">{len(people)}</td>'
            f'</tr>')
    if roster_rows:
        body = (f'<table style="{STY["tbl"]}">'
                f'<tr><th style="{STY["th"]}">Service</th>'
                f'<th style="{STY["th"]}">On shift</th>'
                f'<th style="{STY["th"]};text-align:right">N</th></tr>'
                + '\n'.join(roster_rows) + '</table>')
    else:
        body = f'<p style="{STY["empty"]}">No shifts logged for {fmt_day(yest)}.</p>'
    out.append(section(f'Roster — {fmt_day(yest)}', None, body))

    # Hours/cost rollup by team
    if sht:
        total_h = total_c = total_s = 0
        rows = []
        for s in sht:
            total_h += float(s['hours'] or 0)
            total_c += float(s['cost_with_oncost'] or 0)
            total_s += int(s['staff_count'] or 0)
            rows.append(
                f'<tr>'
                f'<td style="{STY["td"]}"><strong>{h(s["team"])}</strong></td>'
                f'<td style="{STY["td"]}">{h(s["department_name"])}</td>'
                f'<td style="{STY["td"]}">{float(s["hours"] or 0):.2f}h</td>'
                f'<td style="{STY["td"]}">£{float(s["cost_with_oncost"] or 0):,.2f}</td>'
                f'<td style="{STY["td"]}">{s["staff_count"] or 0}</td>'
                f'</tr>')
        rows.append(
            f'<tr style="background:#f8f8f8">'
            f'<td style="{STY["td"]}" colspan="2"><strong>Total — {fmt_day(shift_date)}</strong></td>'
            f'<td style="{STY["td"]}"><strong>{total_h:.2f}h</strong></td>'
            f'<td style="{STY["td"]}"><strong>£{total_c:,.2f}</strong></td>'
            f'<td style="{STY["td"]}"><strong>{total_s}</strong></td>'
            f'</tr>')
        body = (f'<table style="{STY["tbl"]}">'
                f'<tr><th style="{STY["th"]}">Team</th>'
                f'<th style="{STY["th"]}">Dept</th>'
                f'<th style="{STY["th"]}">Hours</th>'
                f'<th style="{STY["th"]}">Cost</th>'
                f'<th style="{STY["th"]}">Staff</th></tr>'
                + '\n'.join(rows) + '</table>')
        out.append(section(f'Labour rollup — {fmt_day(shift_date)}', None, body))

    # Cost/income ratio — YESTERDAY (Jo's preferred lens) + budget + target
    pub_cost = sum(float(s['cost_with_oncost'] or 0) for s in sht
                   if (s['team'] or '').lower() in ('kitchen','front_of_house','accommodation'))
    cafe_cost = sum(float(s['cost_with_oncost'] or 0) for s in sht
                    if (s['team'] or '').lower() == 'cafe')
    pub_sales = sales_map.get('malthouse', 0)
    cafe_sales = sales_map.get('sandwich', 0)
    pub_target = target_map.get('malthouse', 0)
    cafe_target = target_map.get('sandwich', 0)
    pub_budget_labour  = pub_target  * LABOUR_PCT_TARGET
    cafe_budget_labour = cafe_target * LABOUR_PCT_TARGET
    total_cost = pub_cost + cafe_cost
    total_sales = pub_sales + cafe_sales
    total_target = pub_target + cafe_target
    total_budget_labour = pub_budget_labour + cafe_budget_labour

    def vs(actual, target):
        if target <= 0:
            return '<span style="color:#777">—</span>'
        diff = actual - target
        if diff >= 0:
            return (f'<span style="color:#16a34a;font-weight:bold">+£{diff:,.0f}</span> '
                    f'<span style="color:#666;font-size:12px">vs target</span>')
        return (f'<span style="color:#dc2626;font-weight:bold">−£{abs(diff):,.0f}</span> '
                f'<span style="color:#666;font-size:12px">vs target</span>')

    def vs_cost(actual, budget):
        if budget <= 0:
            return '<span style="color:#777">—</span>'
        diff = actual - budget
        # Under budget = green, over budget = red
        if diff <= 0:
            return (f'<span style="color:#16a34a;font-weight:bold">−£{abs(diff):,.0f}</span> '
                    f'<span style="color:#666;font-size:12px">vs budget</span>')
        return (f'<span style="color:#dc2626;font-weight:bold">+£{diff:,.0f}</span> '
                f'<span style="color:#666;font-size:12px">vs budget</span>')

    body = (f'<p style="color:#666;font-size:13px;margin:0 0 6px 0">'
            f'Sales + labour for <strong>{fmt_day(yest)}</strong>. '
            f'Target = avg sales same day-of-week (last 8 weeks) × 1.05. '
            f'Budgeted labour = {int(LABOUR_PCT_TARGET*100)}% of target sales '
            f'(amber line {fmt_pct(0.3, 1.0).split(">")[1].split("<")[0]} = 30%).'
            f'</p>'
            f'<table style="{STY["tbl"]}">'
            f'<tr><th style="{STY["th"]}">Centre</th>'
            f'<th style="{STY["th"]}">Sales</th>'
            f'<th style="{STY["th"]}">Target</th>'
            f'<th style="{STY["th"]}">Labour cost</th>'
            f'<th style="{STY["th"]}">Budget</th>'
            f'<th style="{STY["th"]}">Ratio</th></tr>'

            f'<tr><td style="{STY["td"]}"><strong>Pub</strong><br>'
            f'<span style="color:#888;font-size:12px">kitchen + FOH + accom</span></td>'
            f'<td style="{STY["td"]}"><strong>£{pub_sales:,.0f}</strong><br>{vs(pub_sales, pub_target)}</td>'
            f'<td style="{STY["td"]}">£{pub_target:,.0f}</td>'
            f'<td style="{STY["td"]}"><strong>£{pub_cost:,.0f}</strong><br>{vs_cost(pub_cost, pub_budget_labour)}</td>'
            f'<td style="{STY["td"]}">£{pub_budget_labour:,.0f}</td>'
            f'<td style="{STY["td"]}">{fmt_pct(pub_cost, pub_sales)}</td></tr>'

            f'<tr><td style="{STY["td"]}"><strong>Cafe</strong><br>'
            f'<span style="color:#888;font-size:12px">cafe team</span></td>'
            f'<td style="{STY["td"]}"><strong>£{cafe_sales:,.0f}</strong><br>{vs(cafe_sales, cafe_target)}</td>'
            f'<td style="{STY["td"]}">£{cafe_target:,.0f}</td>'
            f'<td style="{STY["td"]}"><strong>£{cafe_cost:,.0f}</strong><br>{vs_cost(cafe_cost, cafe_budget_labour)}</td>'
            f'<td style="{STY["td"]}">£{cafe_budget_labour:,.0f}</td>'
            f'<td style="{STY["td"]}">{fmt_pct(cafe_cost, cafe_sales)}</td></tr>'

            f'<tr style="background:#f8f8f8">'
            f'<td style="{STY["td"]}"><strong>Combined</strong></td>'
            f'<td style="{STY["td"]}"><strong>£{total_sales:,.0f}</strong><br>{vs(total_sales, total_target)}</td>'
            f'<td style="{STY["td"]}"><strong>£{total_target:,.0f}</strong></td>'
            f'<td style="{STY["td"]}"><strong>£{total_cost:,.0f}</strong><br>{vs_cost(total_cost, total_budget_labour)}</td>'
            f'<td style="{STY["td"]}"><strong>£{total_budget_labour:,.0f}</strong></td>'
            f'<td style="{STY["td"]}">{fmt_pct(total_cost, total_sales)}</td></tr>'
            f'</table>')
    out.append(section(f'Sales + labour vs target — {fmt_day(yest)}', None, body))

    # Deliveries
    if deliveries:
        rows = []
        for d in deliveries:
            rows.append(
                f'<tr>'
                f'<td style="{STY["td"]}">{fmt_day(d["delivery_date"])}</td>'
                f'<td style="{STY["td"]}"><strong>{h(d["vendor_name"] or d["vendor_domain"])}</strong></td>'
                f'<td style="{STY["td"]}">£{float(d["amount"] or 0):,.2f}</td>'
                f'</tr>')
        body = (f'<table style="{STY["tbl"]}">'
                f'<tr><th style="{STY["th"]}">Date</th>'
                f'<th style="{STY["th"]}">Vendor</th>'
                f'<th style="{STY["th"]}">Amount</th></tr>'
                + '\n'.join(rows) + '</table>')
    else:
        body = (f'<p style="{STY["empty"]}">No deliveries with extracted dates. '
                'Most invoices arrive without delivery_date — u61 cron at :20 keeps filling these in.</p>')
    out.append(section('Deliveries — today + tomorrow', len(deliveries), body))

    # Tomorrow's arrivals
    if tom_arrivals:
        rows = []
        for a in tom_arrivals:
            src = source_label(a['source'])
            src_html = f'<span style="color:#888;font-size:12px">{h(src)}</span>' if src else ''
            rows.append(
                f'<tr>'
                f'<td style="{STY["td"]}"><strong>{h(a["guest_name"])}</strong></td>'
                f'<td style="{STY["td"]}">{h(a["room"])}</td>'
                f'<td style="{STY["td"]}">{pay_badge(a["payment_status"], a["gross_amount"])}</td>'
                f'<td style="{STY["td"]}">{src_html}</td>'
                f'</tr>')
        body = (f'<table style="{STY["tbl"]}">'
                f'<tr><th style="{STY["th"]}">Guest</th>'
                f'<th style="{STY["th"]}">Room</th>'
                f'<th style="{STY["th"]}">Payment</th>'
                f'<th style="{STY["th"]}">Source</th></tr>'
                + '\n'.join(rows) + '</table>')
    else:
        body = f'<p style="{STY["empty"]}">No arrivals booked for tomorrow yet.</p>'
    out.append(section(f'Tomorrow — {fmt_day(tomorrow)}', len(tom_arrivals), body))

    out.append(f'<p style="{STY["foot"]}">All workflows in TEST mode. '
               'No guest-facing emails fired. Tonight bookings on the book: '
               f'<strong>{kpi["bookings_today"]}</strong> for '
               f'<strong>£{int(kpi["bookings_today_revenue"]):,}</strong>.</p>')
    out.append('</div>')

    html_body = '\n'.join(out)

    payload = {
        'to': 'jolyon.sandercock@gmail.com',
        'subject': (f"[Home AI] Daily reality — {fmt_day(today)}"
                    f" · {kpi['bookings_today']} arrivals · {len(covers)} covers"),
        'body_html': html_body,
        'body_text': (f"Daily reality — {fmt_day(today)}. "
                      f"{kpi['bookings_today']} arrivals, {len(covers)} covers, "
                      f"{len(to_sell)} empty rooms to sell. "
                      "Open the HTML version for the full breakdown."),
    }
    req = urllib.request.Request(
        'http://google-fetch:8011/send/bot',
        data=json.dumps(payload).encode(),
        headers={'Content-Type': 'application/json'},
        method='POST')
    r = urllib.request.urlopen(req, timeout=15)
    resp = json.loads(r.read())
    print(f'send: {r.status}, msg_id: {resp.get("message_id")}')

    await conn.close()


asyncio.run(main())
