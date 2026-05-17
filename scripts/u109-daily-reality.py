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


async def weather_and_surf_from_cache(conn, today, tomorrow):
    """Read today + tomorrow forecast from weather_forecast cache. The cache
    is refreshed daily by u46-weather-daily.sh at 07:30 (+ ad-hoc runs).
    Falls back to API only if the cache is empty for the requested date —
    keeps Jo's "poll once" intent."""
    rows = await conn.fetch("""
        SELECT DISTINCT ON (forecast_date)
          forecast_date, fetched_at,
          max_temp_c, min_temp_c, rain_mm,
          weather_code, precipitation_probability, max_wind_mph,
          wave_height_m, wave_period_s, wave_direction_deg
          FROM weather_forecast
         WHERE forecast_date IN ($1, $2)
         ORDER BY forecast_date, fetched_at DESC
    """, today, tomorrow)
    out = {}
    cache_age_s = None
    for r in rows:
        label = 'today' if r['forecast_date'] == today else 'tomorrow'
        if r['fetched_at']:
            age = (asyncio.get_event_loop().time() - 0)  # not used directly
        out[label] = {
            'date':  r['forecast_date'].isoformat(),
            'tmax':  float(r['max_temp_c']) if r['max_temp_c'] is not None else None,
            'tmin':  float(r['min_temp_c']) if r['min_temp_c'] is not None else None,
            'desc':  WMO.get(r['weather_code'], '?') if r['weather_code'] is not None else '?',
            'rain':  r['precipitation_probability'] if r['precipitation_probability'] is not None
                     else (round(float(r['rain_mm']) * 10) if r['rain_mm'] is not None else 0),
            'wind':  float(r['max_wind_mph'] or 0) * 1.609,  # mph→km/h
            'code':  r['weather_code'],
        }
        if cache_age_s is None and r['fetched_at']:
            from datetime import datetime, timezone
            cache_age_s = (datetime.now(timezone.utc) - r['fetched_at']).total_seconds()

    # Build surf dict from the same rows
    surf = {}
    for r in rows:
        label = 'today' if r['forecast_date'] == today else 'tomorrow'
        if r['wave_height_m'] is not None:
            surf[label] = {
                'h':   float(r['wave_height_m']),
                'p':   float(r['wave_period_s'] or 0),
                'dir': int(r['wave_direction_deg']) if r['wave_direction_deg'] is not None else 0,
            }
    return out, surf, cache_age_s


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
    if not w:
        return None, None
    t = w.get('today', {})
    if not t:
        return None, None
    tmax = t.get('tmax') or 0
    rain = t.get('rain') or 0
    wind = t.get('wind') or 0
    code = t.get('code') or 0
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

    # Common allocation fix: when multiple rooms in a single multi-room
    # booking get the same total duplicated, divide by the sibling count.
    # Pattern: same canonical name + same checkin + same checkout + same
    # gross_amount appearing N times. Sibling rows with distinct amounts
    # (per-room pricing) pass through untouched.
    # Postgres doesn't support COUNT(DISTINCT …) OVER, so pre-aggregate
    # group stats then LATERAL-join back.
    ALLOC_CTE = """
        WITH groups AS (
          SELECT guest_name_canonical, checkin_date, checkout_date,
                 COUNT(*) AS sib_count,
                 COUNT(DISTINCT gross_amount) AS sib_distinct_amts
            FROM accommodation_bookings
           WHERE status IN ('confirmed','deposit_paid','paid','active')
           GROUP BY guest_name_canonical, checkin_date, checkout_date
        ),
        siblings AS (
          SELECT b.id,
                 b.guest_name, b.room, b.source, b.payment_status,
                 b.checkin_date, b.checkout_date,
                 (b.checkout_date - b.checkin_date) AS nights,
                 g.sib_count,
                 CASE WHEN g.sib_count > 1 AND g.sib_distinct_amts = 1
                      THEN ROUND((b.gross_amount / g.sib_count)::numeric, 2)
                      ELSE b.gross_amount END AS gross_amount,
                 CASE WHEN g.sib_count > 1 AND g.sib_distinct_amts = 1
                      THEN ROUND((b.total_amount / g.sib_count)::numeric, 2)
                      ELSE b.total_amount END AS total_amount
            FROM accommodation_bookings b
            JOIN groups g
              ON g.guest_name_canonical = b.guest_name_canonical
             AND g.checkin_date = b.checkin_date
             AND g.checkout_date = b.checkout_date
           WHERE b.status IN ('confirmed','deposit_paid','paid','active')
        )
        SELECT id, guest_name, room, source, payment_status,
               checkin_date, checkout_date, nights, sib_count,
               gross_amount, total_amount
        """
    arrivals = await conn.fetch(
        ALLOC_CTE + " FROM siblings WHERE checkin_date = $1 ORDER BY room, id", today)
    staythroughs = await conn.fetch(
        ALLOC_CTE + " FROM siblings WHERE checkin_date < $1 AND checkout_date > $1 "
        "ORDER BY checkout_date, room", today)
    departures = await conn.fetch(
        ALLOC_CTE + " FROM siblings WHERE checkout_date = $1 ORDER BY room", today)
    covers = await conn.fetch("""
        SELECT id, source_ref, reservation_at, guest_name, party_size, booking_type
          FROM restaurant_reservations
         WHERE reservation_at::date = $1
           AND status IN ('confirmed','enquiry','arrived')
         ORDER BY reservation_at
    """, today)
    cross = await conn.fetch("SELECT * FROM v_today_stay_dine_crosslink")
    tom_arrivals = await conn.fetch(
        ALLOC_CTE + " FROM siblings WHERE checkin_date = $1 ORDER BY room", tomorrow)

    kpi = await conn.fetchrow("SELECT * FROM v_today_kpis_work")

    # Roster + rollup → TODAY (the day ahead). Cost/income vs target → YESTERDAY.
    yest = today - timedelta(days=1)

    SHIFT_PEOPLE_SQL = """
        SELECT
          COALESCE(NULLIF(u.preferred_name,''), u.full_name, 'unknown') AS name,
          d.team,
          to_char(s.start_time AT TIME ZONE 'Europe/London', 'HH24:MI') AS start_h,
          to_char(s.end_time   AT TIME ZONE 'Europe/London', 'HH24:MI') AS end_h,
          EXTRACT(HOUR FROM (s.start_time AT TIME ZONE 'Europe/London'))::int AS start_hr,
          s.hours_worked,
          COALESCE(NULLIF(s.cost_estimate, 0), s.hours_worked * COALESCE(u.base_pay_rate, 11.44)) AS cost_planned
          FROM workforce_shifts s
          LEFT JOIN workforce_users u ON u.external_id = s.user_external_id
          LEFT JOIN workforce_departments d ON d.external_id = s.department_external_id
         WHERE s.shift_date = $1
         ORDER BY s.start_time, name
    """
    shifts_people = await conn.fetch(SHIFT_PEOPLE_SQL, today)
    # If Tanda hasn't pushed today's published rota yet, show that state
    # honestly rather than substituting yesterday's data.
    rota_published = bool(shifts_people)

    shifts_team_today = await conn.fetch("""
        SELECT team, department_name, hours, cost_with_oncost, staff_count, report_date
          FROM v_daily_labour_by_team
         WHERE report_date = $1 ORDER BY cost_with_oncost DESC NULLS LAST
    """, today)
    shifts_team_yest = await conn.fetch("""
        SELECT team, department_name, hours, cost_with_oncost, staff_count, report_date
          FROM v_daily_labour_by_team
         WHERE report_date = $1 ORDER BY cost_with_oncost DESC NULLS LAST
    """, yest)
    sht = shifts_team_today          # used for today's rollup display
    shift_date = today
    sht_yest = shifts_team_yest      # used for the yesterday cost/income table

    # Yesterday's sales by department + site (the only ratio we show now)
    sales_rows = await conn.fetch("""
        SELECT site, department, SUM(value)::numeric(10,2) net_sales
          FROM touchoffice_department_sales
         WHERE report_date = $1
         GROUP BY site, department
    """, yest)
    sales_map = {}            # site → total
    sales_by_cat = {}         # category (wet/food/accom/cafe) → total
    for r in sales_rows:
        site, dept = r['site'], (r['department'] or '').upper()
        v = float(r['net_sales'])
        sales_map[site] = sales_map.get(site, 0) + v
        if site == 'malthouse':
            if 'ALCOHOL' in dept or 'HOT DRINKS' in dept:
                sales_by_cat['wet'] = sales_by_cat.get('wet', 0) + v
            elif 'FOOD' in dept:
                sales_by_cat['food'] = sales_by_cat.get('food', 0) + v
            elif 'ACCOM' in dept:
                sales_by_cat['accom'] = sales_by_cat.get('accom', 0) + v
            # KITCHEN INT (interdept transfers) intentionally ignored
        elif site == 'sandwich':
            sales_by_cat['cafe'] = sales_by_cat.get('cafe', 0) + v
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

    wx, surf, wx_cache_age = await weather_and_surf_from_cache(conn, today, tomorrow)
    wkind, wtext = weather_warning(wx) if wx else (None, None)

    # U111 — revenue forecast for tomorrow
    forecast_rows = await conn.fetch("SELECT * FROM v_revenue_forecast_tomorrow")

    # U121 — obligations next 14 days
    obligations = await conn.fetch("""
        SELECT due_date::date AS due_date, source, label, kind
          FROM v_obligations
         WHERE due_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 14
         ORDER BY due_date, source LIMIT 20
    """)

    # U124-B — repeat-guest detector (arriving today or tomorrow)
    repeat_arrivals = await conn.fetch("""
        SELECT DISTINCT ON (known_as)
               booking_name, known_as, room, checkin_date,
               prior_visits_completed, lifetime_revenue, segment, preferred_room
          FROM v_repeat_arrivals
         WHERE checkin_date <= CURRENT_DATE + 1
         ORDER BY known_as, lifetime_revenue DESC
    """)

    # U114 — AI usage last 24h (cost + cache hit rate per service)
    ai_usage_rows = await conn.fetch("""
        SELECT
          service,
          model_used,
          COUNT(*)                                AS calls,
          SUM(prompt_tokens)                      AS in_fresh,
          SUM(completion_tokens)                  AS out_tok,
          SUM(COALESCE(cache_creation_tokens,0))  AS cache_w,
          SUM(COALESCE(cache_read_tokens,0))      AS cache_r
        FROM ai_usage
        WHERE timestamp >= NOW() - INTERVAL '24 hours'
          AND service IS NOT NULL
        GROUP BY service, model_used
        ORDER BY SUM(prompt_tokens) DESC NULLS LAST
    """)

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
    if wx:
        for lbl, d in (('Today', today), ('Tomorrow', tomorrow)):
            key = 'today' if lbl == 'Today' else 'tomorrow'
            w = wx.get(key)
            if not w:
                continue
            s = surf.get(key, {})
            surf_cell = (f"{s['h']:.1f}m @ {s['p']:.0f}s {deg_to_compass(s['dir'])} "
                         f"<span style='color:#666'>· {surf_quality(s['h'], s['p'])}</span>"
                         if s else '<span style="color:#999">—</span>')
            out_line = (f'<td style="{STY["td"]}"><strong>{lbl}</strong></td>'
                        f'<td style="{STY["td"]}">{(w["tmin"] or 0):.0f}–{(w["tmax"] or 0):.0f}°C</td>'
                        f'<td style="{STY["td"]}">{int(w["rain"] or 0)}%</td>'
                        f'<td style="{STY["td"]}">{w["wind"]:.0f} km/h</td>'
                        f'<td style="{STY["td"]}">{h(w["desc"])}</td>'
                        f'<td style="{STY["td"]}">{surf_cell}</td>')
            wx_body.append(f'<tr>{out_line}</tr>')
    else:
        wx_body.append(f'<tr><td style="{STY["td"]}" colspan="6">'
                       f'<em style="color:#999">Weather cache empty — re-run '
                       f'u46-weather-daily.sh.</em></td></tr>')
    wx_body.append('</table>')
    cache_note = ''
    if wx_cache_age is not None:
        mins = int(wx_cache_age / 60)
        cache_note = (f'<p style="color:#999;font-size:11px;margin:4px 0 0 0">'
                      f'Cached {mins} min ago · refreshed daily 07:30 by u46-weather-daily.</p>')
    out.append(section('Weather + surf', None, '\n'.join(wx_body) + cache_note))
    out.append(f'<p style="{STY["empty"]}">Tide times: source integration pending (no free '
               'API responded without auth).</p>')

    # ── Tomorrow revenue forecast (weather-conditioned) ─────────────────
    if forecast_rows and any(r['forecast_avg'] for r in forecast_rows):
        cat_labels = {
            'food':       'Kitchen / food',
            'wet':        'FoH / drinks',
            'accom':      'Accommodation',
            'icecream':   'Cafe — ice cream',
            'cafe-other': 'Cafe — other',
        }
        rows_html = []
        total = 0.0
        for r in forecast_rows:
            label = cat_labels.get(r['category'], r['category'])
            avg = float(r['forecast_avg']) if r['forecast_avg'] else 0
            med = float(r['forecast_median']) if r['forecast_median'] else 0
            total += avg
            rows_html.append(
                f'<tr>'
                f'<td style="{STY["td"]}"><strong>{h(label)}</strong></td>'
                f'<td style="{STY["td"]}">£{avg:,.0f}</td>'
                f'<td style="{STY["td"]};color:#666">£{med:,.0f}</td>'
                f'<td style="{STY["td"]};color:#888;font-size:12px">{r["sample_days"]} days</td>'
                f'</tr>')
        first = forecast_rows[0]
        sub = (f'Based on tomorrow forecast: '
               f'<strong>{(first["max_temp_c"] or 0):.0f}°C</strong>, '
               f'<strong>{int(first["precipitation_probability"] or 0)}% rain</strong>, '
               f'band <strong>{h(first["band"])}</strong>. '
               f'Matched against last 90 days, same day-of-week.')
        body = (f'<p style="color:#666;font-size:13px;margin:0 0 6px 0">{sub}</p>'
                f'<table style="{STY["tbl"]}">'
                f'<tr><th style="{STY["th"]}">Category</th>'
                f'<th style="{STY["th"]}">Predicted (avg)</th>'
                f'<th style="{STY["th"]}">Median</th>'
                f'<th style="{STY["th"]}">Sample</th></tr>'
                + '\n'.join(rows_html)
                + f'<tr style="background:#f8f8f8">'
                f'<td style="{STY["td"]}"><strong>Total predicted</strong></td>'
                f'<td style="{STY["td"]}"><strong>£{total:,.0f}</strong></td>'
                f'<td style="{STY["td"]}" colspan="2"></td></tr>'
                + '</table>')
        out.append(section(f'Forecast — {fmt_day(tomorrow)}', None, body))

    def nights_summary(rows, kind):
        """Bookings × total nights summary line."""
        if not rows:
            return ''
        if kind == 'stay':
            # nights remaining = checkout − today
            n = sum((r['checkout_date'] - today).days for r in rows)
            return f'<strong>{len(rows)}</strong> bookings · <strong>{n}</strong> nights remaining'
        else:
            n = sum(r['nights'] or 0 for r in rows)
            return f'<strong>{len(rows)}</strong> bookings · <strong>{n}</strong> nights total'

    def alloc_badge(sib_count):
        if sib_count and sib_count > 1:
            return (' <span style="color:#888;font-size:11px;'
                    'background:#f3f4f6;padding:1px 5px;border-radius:3px" '
                    f'title="Total split across {sib_count} sibling rooms">'
                    f'÷{sib_count}</span>')
        return ''

    # Arrivals
    cross_ids = {x['booking_id'] for x in cross}
    if arrivals:
        rows = []
        for a in arrivals:
            star = ' ★' if a['id'] in cross_ids else ''
            src = source_label(a['source'])
            src_html = f'<span style="color:#888;font-size:12px">{h(src)}</span>' if src else ''
            nights_cell = f'{a["nights"]}n'
            rows.append(
                f'<tr>'
                f'<td style="{STY["td"]}"><strong>{h(a["guest_name"])}</strong>{star}</td>'
                f'<td style="{STY["td"]}">{h(a["room"])}</td>'
                f'<td style="{STY["td"]};text-align:center">{nights_cell}</td>'
                f'<td style="{STY["td"]}">{pay_badge(a["payment_status"], a["gross_amount"])}'
                f'{alloc_badge(a.get("sib_count"))}</td>'
                f'<td style="{STY["td"]}">{src_html}</td>'
                f'</tr>')
        body = (f'<p style="color:#666;font-size:13px;margin:0 0 6px 0">{nights_summary(arrivals, "arr")}</p>'
                f'<table style="{STY["tbl"]}">'
                f'<tr><th style="{STY["th"]}">Guest</th>'
                f'<th style="{STY["th"]}">Room</th>'
                f'<th style="{STY["th"]};text-align:center">Nights</th>'
                f'<th style="{STY["th"]}">Payment</th>'
                f'<th style="{STY["th"]}">Source</th></tr>'
                + '\n'.join(rows) + '</table>')
    else:
        body = f'<p style="{STY["empty"]}">No arrivals today.</p>'
    out.append(section('Arriving tonight', len(arrivals), body))

    # Stay-throughs
    if staythroughs:
        rows = []
        for s in staythroughs:
            star = ' ★' if s['id'] in cross_ids else ''
            remaining = (s['checkout_date'] - today).days
            rows.append(
                f'<tr>'
                f'<td style="{STY["td"]}"><strong>{h(s["guest_name"])}</strong>{star}</td>'
                f'<td style="{STY["td"]}">{h(s["room"])}</td>'
                f'<td style="{STY["td"]};text-align:center">{remaining}n</td>'
                f'<td style="{STY["td"]}">checks out <strong>{fmt_day(s["checkout_date"])}</strong></td>'
                f'</tr>')
        body = (f'<p style="color:#666;font-size:13px;margin:0 0 6px 0">{nights_summary(staythroughs, "stay")}</p>'
                f'<table style="{STY["tbl"]}">'
                f'<tr><th style="{STY["th"]}">Guest</th>'
                f'<th style="{STY["th"]}">Room</th>'
                f'<th style="{STY["th"]};text-align:center">Left</th>'
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
                f'<td style="{STY["td"]};text-align:center">{d["nights"]}n</td>'
                f'<td style="{STY["td"]}">{pay_badge(d["payment_status"], amt)}'
                f'{alloc_badge(d.get("sib_count"))}</td>'
                f'</tr>')
        body = (f'<p style="color:#666;font-size:13px;margin:0 0 6px 0">{nights_summary(departures, "dep")}</p>'
                f'<table style="{STY["tbl"]}">'
                f'<tr><th style="{STY["th"]}">Guest</th>'
                f'<th style="{STY["th"]}">Room</th>'
                f'<th style="{STY["th"]};text-align:center">Stay</th>'
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

    # Roster — TODAY (the day ahead). One row per department; each shift as
    # its own column; cost-per-row at the end. Total + sales target at the
    # bottom.
    DEPT_LABELS = {
        'kitchen':        'Kitchen',
        'front_of_house': 'Front of house',
        'accommodation':  'Housekeeping',
        'cafe':           'Cafe',
    }
    dept_shifts = {k: [] for k in DEPT_LABELS}
    for p in shifts_people:
        team = (p['team'] or '').lower()
        if team in dept_shifts:
            dept_shifts[team].append(p)

    max_cols = max((len(v) for v in dept_shifts.values()), default=0)
    today_target_pub  = target_map.get('malthouse', 0)
    today_target_cafe = target_map.get('sandwich', 0)
    today_target_sales = today_target_pub + today_target_cafe

    if max_cols == 0:
        body = (f'<p style="{STY["banner_warn"]}">'
                f'<strong>Rota not published</strong> for {fmt_day(today)}. '
                f'Publish in Tanda or check why the 02:15 / 12:00 sync did not '
                f'pull a forward window for today.</p>')
    else:
        def cell_for(p):
            if not p:
                return f'<td style="{STY["td"]};color:#ccc">—</td>'
            nm = (p['name'] or '?').replace('  ', ' ').strip()
            times = (f'{h(p["start_h"])}–{h(p["end_h"])}'
                     if p['start_h'] and p['end_h'] else
                     '<span style="color:#999">no times</span>')
            return (f'<td style="{STY["td"]};white-space:nowrap">'
                    f'<strong>{h(nm)}</strong><br>'
                    f'<span style="color:#666;font-size:12px">{times}</span></td>')

        rows = []
        grand_cost = 0.0
        for team_key, label in DEPT_LABELS.items():
            people = dept_shifts[team_key]
            dept_cost = sum(float(p['cost_planned'] or 0) for p in people)
            grand_cost += dept_cost
            cells = ''.join(cell_for(p if i < len(people) else None)
                            for i, p in enumerate(people + [None] * (max_cols - len(people))))
            rows.append(
                f'<tr>'
                f'<td style="{STY["td"]};white-space:nowrap"><strong>{h(label)}</strong></td>'
                f'{cells}'
                f'<td style="{STY["td"]};text-align:right;white-space:nowrap">'
                f'<strong>£{dept_cost:,.0f}</strong></td>'
                f'</tr>')

        # Total + sales target rows
        rows.append(
            f'<tr style="background:#f8f8f8">'
            f'<td style="{STY["td"]}"><strong>Labour total</strong></td>'
            f'<td style="{STY["td"]};color:#777;font-size:12px" colspan="{max_cols}">planned for {fmt_day(today)}</td>'
            f'<td style="{STY["td"]};text-align:right"><strong>£{grand_cost:,.0f}</strong></td>'
            f'</tr>')
        if today_target_sales > 0:
            tgt_ratio = grand_cost / today_target_sales * 100
            tgt_colour = '#dc2626' if tgt_ratio > 30 else '#16a34a'
            rows.append(
                f'<tr style="background:#f8f8f8">'
                f'<td style="{STY["td"]}"><strong>Sales target</strong></td>'
                f'<td style="{STY["td"]};color:#777;font-size:12px" colspan="{max_cols}">'
                f'avg same day-of-week × 1.05 · ratio if hit: '
                f'<span style="color:{tgt_colour};font-weight:bold">{tgt_ratio:.1f}%</span></td>'
                f'<td style="{STY["td"]};text-align:right"><strong>£{today_target_sales:,.0f}</strong></td>'
                f'</tr>')

        header = (f'<tr><th style="{STY["th"]}">Dept</th>'
                  + ''.join(f'<th style="{STY["th"]}">Shift {i+1}</th>' for i in range(max_cols))
                  + f'<th style="{STY["th"]};text-align:right">Cost</th></tr>')
        body = (f'<table style="{STY["tbl"]}">' + header + '\n'.join(rows) + '</table>')

    out.append(section(f'Roster — {fmt_day(today)}', None, body))

    # Cost/income ratio — YESTERDAY + per-team labour split.
    # Pub broken into FoH/drinks · Kitchen/food · Housekeeping/accom.
    # Use sht_yest (yesterday's actual costs) since today's costs are not
    # finalised until u47-tanda-timesheets-sync runs at 02:20.
    team_cost = {t: 0.0 for t in ('kitchen','front_of_house','accommodation','cafe')}
    for s in sht_yest:
        t = (s['team'] or '').lower()
        if t in team_cost:
            team_cost[t] += float(s['cost_with_oncost'] or 0)

    food_cost   = team_cost['kitchen']
    wet_cost    = team_cost['front_of_house']
    accom_cost  = team_cost['accommodation']
    cafe_cost   = team_cost['cafe']
    pub_cost    = food_cost + wet_cost + accom_cost
    total_cost  = pub_cost + cafe_cost

    food_sales  = sales_by_cat.get('food', 0)
    wet_sales   = sales_by_cat.get('wet', 0)
    accom_sales = sales_by_cat.get('accom', 0)
    cafe_sales  = sales_by_cat.get('cafe', 0)
    pub_sales   = food_sales + wet_sales + accom_sales
    total_sales = pub_sales + cafe_sales

    pub_target  = target_map.get('malthouse', 0)
    cafe_target = target_map.get('sandwich', 0)
    total_target = pub_target + cafe_target

    pub_budget_labour   = pub_target  * LABOUR_PCT_TARGET
    cafe_budget_labour  = cafe_target * LABOUR_PCT_TARGET
    total_budget_labour = pub_budget_labour + cafe_budget_labour

    def vs(actual, target):
        if target <= 0:
            return '<span style="color:#777">—</span>'
        diff = actual - target
        if diff >= 0:
            return (f'<span style="color:#16a34a;font-weight:bold">+£{diff:,.0f}</span> '
                    f'<span style="color:#666;font-size:12px">vs tgt</span>')
        return (f'<span style="color:#dc2626;font-weight:bold">−£{abs(diff):,.0f}</span> '
                f'<span style="color:#666;font-size:12px">vs tgt</span>')

    def vs_cost(actual, budget):
        if budget <= 0:
            return '<span style="color:#777">—</span>'
        diff = actual - budget
        if diff <= 0:
            return (f'<span style="color:#16a34a;font-weight:bold">−£{abs(diff):,.0f}</span> '
                    f'<span style="color:#666;font-size:12px">vs bud</span>')
        return (f'<span style="color:#dc2626;font-weight:bold">+£{diff:,.0f}</span> '
                f'<span style="color:#666;font-size:12px">vs bud</span>')

    def cat_row(label, sub, sales, target, cost, budget, indent=False):
        td_label = (f'<td style="{STY["td"]}{";padding-left:24px" if indent else ""}">'
                    f'<strong>{label}</strong>'
                    + (f'<br><span style="color:#888;font-size:12px">{sub}</span>' if sub else '')
                    + '</td>')
        return (f'<tr>'
                f'{td_label}'
                f'<td style="{STY["td"]}"><strong>£{sales:,.0f}</strong><br>{vs(sales, target)}</td>'
                f'<td style="{STY["td"]}">£{target:,.0f}</td>'
                f'<td style="{STY["td"]}"><strong>£{cost:,.0f}</strong><br>{vs_cost(cost, budget)}</td>'
                f'<td style="{STY["td"]}">£{budget:,.0f}</td>'
                f'<td style="{STY["td"]}">{fmt_pct(cost, sales)}</td></tr>')

    def total_row(label, sales, target, cost, budget, bold=True):
        s_tag = '<strong>' if bold else ''
        e_tag = '</strong>' if bold else ''
        return (f'<tr style="background:#f8f8f8">'
                f'<td style="{STY["td"]}"><strong>{label}</strong></td>'
                f'<td style="{STY["td"]}">{s_tag}£{sales:,.0f}{e_tag}<br>{vs(sales, target)}</td>'
                f'<td style="{STY["td"]}">{s_tag}£{target:,.0f}{e_tag}</td>'
                f'<td style="{STY["td"]}">{s_tag}£{cost:,.0f}{e_tag}<br>{vs_cost(cost, budget)}</td>'
                f'<td style="{STY["td"]}">{s_tag}£{budget:,.0f}{e_tag}</td>'
                f'<td style="{STY["td"]}">{fmt_pct(cost, sales)}</td></tr>')

    # Pub sub-target split based on last 28d category mix
    cat_mix_rows = await conn.fetch("""
        SELECT department, SUM(value)::numeric(12,2) total
          FROM touchoffice_department_sales
         WHERE site='malthouse'
           AND report_date BETWEEN $1::date - INTERVAL '28 days' AND $1::date - INTERVAL '1 day'
         GROUP BY department
    """, yest)
    mix_total = sum(float(r['total']) for r in cat_mix_rows) or 1
    mix = {'wet': 0.0, 'food': 0.0, 'accom': 0.0}
    for r in cat_mix_rows:
        d = (r['department'] or '').upper()
        v = float(r['total'])
        if 'ALCOHOL' in d or 'HOT DRINKS' in d:    mix['wet']   += v
        elif 'FOOD'  in d:                          mix['food']  += v
        elif 'ACCOM' in d:                          mix['accom'] += v
    for k in mix: mix[k] /= mix_total
    target_wet   = pub_target * mix['wet']
    target_food  = pub_target * mix['food']
    target_accom = pub_target * mix['accom']

    body = (f'<p style="color:#666;font-size:13px;margin:0 0 6px 0">'
            f'Sales + labour for <strong>{fmt_day(yest)}</strong>. '
            f'Target = avg sales same day-of-week (last 8 weeks) × 1.05. '
            f'Sub-targets split by last-28-day category mix. '
            f'Budgeted labour = {int(LABOUR_PCT_TARGET*100)}% of target sales '
            f'(amber line = 30%).</p>'
            f'<table style="{STY["tbl"]}">'
            f'<tr><th style="{STY["th"]}">Centre</th>'
            f'<th style="{STY["th"]}">Sales</th>'
            f'<th style="{STY["th"]}">Target</th>'
            f'<th style="{STY["th"]}">Labour cost</th>'
            f'<th style="{STY["th"]}">Budget</th>'
            f'<th style="{STY["th"]}">Ratio</th></tr>'

            # Pub category split
            + cat_row('FoH / drinks',        'alcohol + hot drinks',  wet_sales,   target_wet,   wet_cost,   target_wet   * LABOUR_PCT_TARGET, indent=True)
            + cat_row('Kitchen / food',      'food sales',            food_sales,  target_food,  food_cost,  target_food  * LABOUR_PCT_TARGET, indent=True)
            + cat_row('Housekeeping / accom','accom revenue',         accom_sales, target_accom, accom_cost, target_accom * LABOUR_PCT_TARGET, indent=True)
            + total_row('Pub — subtotal',    pub_sales, pub_target, pub_cost, pub_budget_labour)

            + cat_row('Cafe', 'cafe team', cafe_sales, cafe_target, cafe_cost, cafe_budget_labour)

            + total_row('Combined', total_sales, total_target, total_cost, total_budget_labour)
            + '</table>')
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

    # U124-B — repeat guest welcome-back alert
    if repeat_arrivals:
        rows_html = []
        for r in repeat_arrivals:
            badge = {
                'vip':      '<span style="color:#f59e0b;font-weight:bold">★ VIP</span>',
                'frequent': '<span style="color:#16a34a;font-weight:bold">↻ frequent</span>',
                'regular':  '<span style="color:#16a34a">↻ regular</span>',
            }.get(r['segment'], '↻')
            pref = (f' (prefers <em>{h(r["preferred_room"])}</em>)'
                    if r['preferred_room'] and r['preferred_room'] != r['room'] else '')
            arr = 'today' if r['checkin_date'] == today else 'tomorrow'
            rows_html.append(
                f'<tr>'
                f'<td style="{STY["td"]}">{badge}</td>'
                f'<td style="{STY["td"]}"><strong>{h(r["known_as"])}</strong>{pref}</td>'
                f'<td style="{STY["td"]}">{h(r["room"])}</td>'
                f'<td style="{STY["td"]};text-align:right">£{float(r["lifetime_revenue"] or 0):,.0f}</td>'
                f'<td style="{STY["td"]};text-align:center">{r["prior_visits_completed"]}</td>'
                f'<td style="{STY["td"]}">arriving {h(arr)}</td>'
                f'</tr>')
        body = (f'<p style="color:#666;font-size:13px;margin:0 0 6px 0">'
                f'Returning guests — worth a personal welcome / room upgrade nudge.</p>'
                f'<table style="{STY["tbl"]}">'
                f'<tr><th style="{STY["th"]}">Segment</th>'
                f'<th style="{STY["th"]}">Guest</th>'
                f'<th style="{STY["th"]}">Room</th>'
                f'<th style="{STY["th"]};text-align:right">Lifetime</th>'
                f'<th style="{STY["th"]};text-align:center">Prior</th>'
                f'<th style="{STY["th"]}">When</th></tr>'
                + '\n'.join(rows_html) + '</table>')
        out.append(section('Welcome back — repeat guests', None, body))

    # Obligations next 14 days (U121)
    if obligations:
        rows_html = []
        for r in obligations:
            delta = (r['due_date'] - today).days
            day_label = ('Today' if delta == 0 else
                         'Tomorrow' if delta == 1 else
                         f'{fmt_day(r["due_date"])}')
            colour = ('#dc2626' if delta <= 3 else
                      '#d97706' if delta <= 7 else '#666')
            rows_html.append(
                f'<tr>'
                f'<td style="{STY["td"]};white-space:nowrap;color:{colour};font-weight:bold">{h(day_label)}</td>'
                f'<td style="{STY["td"]}"><strong>{h(r["label"])}</strong></td>'
                f'<td style="{STY["td"]};color:#666;font-size:12px">{h(r["kind"])}</td>'
                f'</tr>')
        body = (f'<table style="{STY["tbl"]}">'
                f'<tr><th style="{STY["th"]}">When</th>'
                f'<th style="{STY["th"]}">What</th>'
                f'<th style="{STY["th"]}">Type</th></tr>'
                + '\n'.join(rows_html) + '</table>')
        out.append(section('Obligations — next 14 days', None, body))

    # AI usage rollup (U114)
    if ai_usage_rows:
        # Anthropic public pricing (USD/MTok). GBP = USD × 0.79 approx.
        # Cache write = 25% premium on base input; cache read = 10% of base.
        PRICES = {
            'claude-sonnet-4-6':            {'in': 3.0,  'out': 15.0},
            'claude-haiku-4-5-20251001':    {'in': 0.80, 'out': 4.0},
            'claude-opus-4-7':              {'in': 15.0, 'out': 75.0},
        }
        GBP = 0.79

        def cost_for(model, in_fresh, out_tok, cache_w, cache_r):
            p = PRICES.get(model, {'in': 1.0, 'out': 5.0})
            cents = (
                (in_fresh / 1e6) * p['in']                +
                (cache_w  / 1e6) * p['in'] * 1.25         +
                (cache_r  / 1e6) * p['in'] * 0.10         +
                (out_tok  / 1e6) * p['out']
            ) * GBP * 100  # → pence
            return cents

        rows = []
        total_p = 0
        total_in = total_w = total_r = total_out = total_calls = 0
        for r in ai_usage_rows:
            in_f = int(r['in_fresh'] or 0)
            cw = int(r['cache_w'] or 0)
            cr = int(r['cache_r'] or 0)
            o  = int(r['out_tok'] or 0)
            calls = int(r['calls'])
            c_p = cost_for(r['model_used'], in_f, o, cw, cr)
            input_total = in_f + cw + cr
            hit_pct = (cr / input_total * 100) if input_total else 0
            hit_html = (f'<span style="color:#16a34a;font-weight:bold">{hit_pct:.0f}%</span>'
                        if hit_pct >= 30 else f'<span style="color:#777">{hit_pct:.0f}%</span>')
            rows.append(
                f'<tr>'
                f'<td style="{STY["td"]}"><strong>{h(r["service"])}</strong><br>'
                f'<span style="color:#888;font-size:12px">{h(r["model_used"])}</span></td>'
                f'<td style="{STY["td"]};text-align:right">{calls}</td>'
                f'<td style="{STY["td"]};text-align:right">{in_f + cw:,}</td>'
                f'<td style="{STY["td"]};text-align:right">{cr:,}</td>'
                f'<td style="{STY["td"]};text-align:center">{hit_html}</td>'
                f'<td style="{STY["td"]};text-align:right">{c_p:.1f}p</td>'
                f'</tr>')
            total_p += c_p; total_in += in_f; total_w += cw; total_r += cr
            total_out += o; total_calls += calls
        total_input = total_in + total_w + total_r
        overall_hit = (total_r / total_input * 100) if total_input else 0
        rows.append(
            f'<tr style="background:#f8f8f8">'
            f'<td style="{STY["td"]}"><strong>Total</strong></td>'
            f'<td style="{STY["td"]};text-align:right"><strong>{total_calls}</strong></td>'
            f'<td style="{STY["td"]};text-align:right"><strong>{total_in + total_w:,}</strong></td>'
            f'<td style="{STY["td"]};text-align:right"><strong>{total_r:,}</strong></td>'
            f'<td style="{STY["td"]};text-align:center"><strong>{overall_hit:.0f}%</strong></td>'
            f'<td style="{STY["td"]};text-align:right"><strong>£{total_p/100:.2f}</strong></td>'
            f'</tr>')
        body = (f'<p style="color:#666;font-size:13px;margin:0 0 6px 0">'
                f'Anthropic spend last 24h. Cache reads cost 10% of base input; '
                f'high hit-rate ≈ small spend. Effective Sonnet input ≈ '
                f'£{(3.0 * GBP * 0.10):.2f}/MTok on cache hit.</p>'
                f'<table style="{STY["tbl"]}">'
                f'<tr><th style="{STY["th"]}">Service</th>'
                f'<th style="{STY["th"]};text-align:right">Calls</th>'
                f'<th style="{STY["th"]};text-align:right">In (fresh + write)</th>'
                f'<th style="{STY["th"]};text-align:right">Cache reads</th>'
                f'<th style="{STY["th"]};text-align:center">Hit</th>'
                f'<th style="{STY["th"]};text-align:right">Cost</th></tr>'
                + '\n'.join(rows) + '</table>')
        out.append(section('AI usage — last 24h', None, body))

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
