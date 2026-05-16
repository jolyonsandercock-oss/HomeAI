"""u109-daily-reality.py — Comprehensive daily reality-check email.

Pulls live from:
  - v_today_kpis_work
  - accommodation_bookings (arrivals / stays / departures)
  - restaurant_reservations (tonight covers)
  - v_today_stay_dine_crosslink (VIPs in both)
  - v_daily_labour_by_team (shift costs)
  - touchoffice_department_sales (yesterday's takings)
  - vendor_invoice_inbox (deliveries pending)
  - open-meteo (weather)

Output: a clean fixed-width plain-text summary, one line per entry,
clearly aligned. Sent FROM jolyboxbot TO jolyon.sandercock@gmail.com.

TEST mode — never sends to guests.
"""
import urllib.request, json, asyncio, os, re
from datetime import date, timedelta
import asyncpg

VAULT_TOKEN = os.environ['VAULT_TOKEN']

def vault(path):
    req = urllib.request.Request(f'http://vault:8200/v1/secret/data/{path}',
                                  headers={'X-Vault-Token': VAULT_TOKEN})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())['data']['data']


# Open-Meteo WMO weather codes → short labels
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
    """Returns dict { 'today': {...}, 'tomorrow': {...} } from open-meteo."""
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
            }
        return out
    except Exception as e:
        return {'error': str(e)[:80]}


def first_name(full):
    m = re.match(r'([A-Z][a-z]+)', full or '')
    return m.group(1) if m else (full.split()[0] if full and full.split() else '?')


async def main():
    pg_pw = vault('postgres')['password']
    conn = await asyncpg.connect(f'postgresql://postgres:{pg_pw}@homeai-postgres:5432/homeai')
    await conn.execute("SELECT home_ai.set_realm('owner')")

    today = date.today()
    tomorrow = today + timedelta(days=1)
    yesterday = today - timedelta(days=1)

    # ── DATA ─────────────────────────────────────────────────────────────
    arrivals = await conn.fetch("""
        SELECT id, guest_name, room, source, gross_amount, payment_status
          FROM accommodation_bookings
         WHERE checkin_date = $1
           AND status IN ('confirmed','deposit_paid','paid','active')
         ORDER BY room, id
    """, today)
    staythroughs = await conn.fetch("""
        SELECT id, guest_name, room, source, checkout_date
          FROM accommodation_bookings
         WHERE checkin_date < $1 AND checkout_date > $1
           AND status IN ('confirmed','deposit_paid','paid','active')
         ORDER BY checkout_date, room
    """, today)
    departures = await conn.fetch("""
        SELECT id, guest_name, room, source
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
        SELECT guest_name, room, source, gross_amount
          FROM accommodation_bookings
         WHERE checkin_date = $1
           AND status IN ('confirmed','deposit_paid','paid','active')
         ORDER BY room
    """, tomorrow)

    # Headline KPIs
    kpi = await conn.fetchrow("SELECT * FROM v_today_kpis_work")

    # Shifts — use yesterday since today often not yet synced
    shifts_today = await conn.fetch("""
        SELECT team, department_name, hours, cost_with_oncost, staff_count
          FROM v_daily_labour_by_team
         WHERE report_date = $1 ORDER BY cost_with_oncost DESC NULLS LAST
    """, today)
    shifts_yest = await conn.fetch("""
        SELECT team, department_name, hours, cost_with_oncost, staff_count
          FROM v_daily_labour_by_team
         WHERE report_date = $1 ORDER BY cost_with_oncost DESC NULLS LAST
    """, yesterday)

    # Yesterday's till
    sales_yest = await conn.fetch("""
        SELECT site, SUM(value)::numeric(10,2) net_sales, COUNT(*) rows
          FROM touchoffice_department_sales
         WHERE report_date = $1
         GROUP BY site ORDER BY net_sales DESC
    """, yesterday)

    # Deliveries pending — any delivery_date in next 2 days
    deliveries = await conn.fetch("""
        SELECT v.id, v.vendor_name, v.vendor_domain, v.delivery_date,
               COALESCE(v.gross_amount, v.amount_seen) AS amount
          FROM vendor_invoice_inbox v
         WHERE v.delivery_date BETWEEN $1 AND $2
           AND v.status NOT IN ('duplicate','ignored','superseded')
         ORDER BY v.delivery_date, v.vendor_name
    """, today, today + timedelta(days=1))

    # Today's order confirmation = yesterday's pub+cafe sales (already pulled above)

    # Weather
    wx = weather_today_tomorrow()

    # ── COMPOSE ──────────────────────────────────────────────────────────
    L = []
    L.append(f"DAILY REALITY — {today.strftime('%A %d %B %Y')}")
    L.append("═" * 76)
    L.append("")

    L.append("WEATHER (Tintagel)")
    if 'error' in wx:
        L.append(f"  weather API error: {wx['error']}")
    else:
        for label in ('today', 'tomorrow'):
            w = wx[label]
            L.append(f"  {label.capitalize():9s}  {w['tmin']:.0f}-{w['tmax']:.0f}°C   "
                     f"{int(w['rain']):3d}% rain   {w['wind']:.0f} km/h wind   {w['desc']}")
    L.append("")

    L.append("HEADLINE")
    L.append(f"  Cash on hand        £{int(kpi['cash_on_hand']):>7,}")
    L.append(f"  Open actions        {kpi['open_actions_count']:>4}")
    L.append(f"  Tonight bookings    {kpi['bookings_today']:>4}        £{int(kpi['bookings_today_revenue']):>5,}")
    L.append(f"  Tonight covers      {len(covers):>4}        {sum(c['party_size'] or 0 for c in covers)} pax")
    L.append("")

    # ──────── ARRIVALS ────────
    L.append(f"ARRIVING TONIGHT ({len(arrivals)})")
    cross_names = {x['booking_id'] for x in cross}
    for a in arrivals:
        star = " ★" if a['id'] in cross_names else "  "
        pay = a['payment_status'] if a['payment_status'] and a['payment_status'] != 'unknown' else ''
        L.append(f"  {star} {(a['guest_name'] or '?'):26s}  {(a['room'] or '?'):24s}  "
                 f"{a['source']:17s}  £{a['gross_amount'] or 0:>7,.2f}  {pay}")
    if not arrivals: L.append("    (none)")
    L.append("")

    L.append(f"STAY-THROUGHS ({len(staythroughs)})")
    for s in staythroughs:
        star = " ★" if s['id'] in cross_names else "  "
        L.append(f"  {star} {(s['guest_name'] or '?'):26s}  {(s['room'] or '?'):24s}  "
                 f"{s['source']:17s}  out {s['checkout_date']}")
    if not staythroughs: L.append("    (none)")
    L.append("")

    L.append(f"DEPARTING TODAY ({len(departures)})")
    for d in departures:
        L.append(f"     {(d['guest_name'] or '?'):26s}  {(d['room'] or '?'):24s}  {d['source']}")
    if not departures: L.append("    (none)")
    L.append("")

    # ──────── COVERS ────────
    L.append(f"DINING TONIGHT ({len(covers)} covers · {sum(c['party_size'] or 0 for c in covers)} pax)")
    cross_res_ids = {x['reservation_id'] for x in cross}
    for c in covers:
        t = c['reservation_at'].strftime('%H:%M') if c['reservation_at'] else '?'
        star = " ★" if c['id'] in cross_res_ids else "  "
        L.append(f"  {star} {t}  {(c['guest_name'] or '?'):26s}  "
                 f"{(c['booking_type'] or '?'):8s}  {(c['party_size'] or 0):>2} pax  "
                 f"{c['source_ref']}")
    if not covers: L.append("    (none)")
    L.append("")

    if cross:
        L.append(f"VIP STAYING + DINING TONIGHT ({len(cross)}) ★")
        for x in cross:
            t = x['reservation_at'].strftime('%H:%M') if x['reservation_at'] else '?'
            L.append(f"  ★ {x['staying_as']:26s} in {(x['room'] or '?'):20s} — "
                     f"dining {t} ({x['party_size']} pax, {x['booking_type']})")
        L.append("")

    # ──────── SHIFTS ────────
    if shifts_today:
        L.append(f"STAFF ON SHIFT TODAY ({today.strftime('%a %d %b')})")
        sht = shifts_today
        label = "today"
    else:
        L.append(f"STAFF ON SHIFT — latest data {yesterday.strftime('%a %d %b')} (today not synced yet)")
        sht = shifts_yest
        label = "yesterday"

    total_h = total_c = total_s = 0
    for s in sht:
        L.append(f"     {(s['team'] or '?'):16s}  {(s['department_name'] or '?'):18s}  "
                 f"{s['hours']:>6.2f}h  £{s['cost_with_oncost'] or 0:>7,.2f}  "
                 f"{s['staff_count']:>2} staff")
        total_h += float(s['hours'] or 0)
        total_c += float(s['cost_with_oncost'] or 0)
        total_s += int(s['staff_count'] or 0)
    if sht:
        L.append(f"     {'─' * 70}")
        L.append(f"     {'TOTAL':36s}  {total_h:>6.2f}h  £{total_c:>7,.2f}  {total_s:>2} staff ({label})")
    L.append("")

    # ──────── SALES ────────
    L.append(f"YESTERDAY'S TILL ({yesterday.strftime('%a %d %b')})")
    sales_map = {r['site']: float(r['net_sales']) for r in sales_yest}
    pub_sales = sales_map.get('malthouse', 0)
    cafe_sales = sales_map.get('sandwich', 0)
    L.append(f"     Pub (malthouse)    £{pub_sales:>9,.2f}")
    L.append(f"     Cafe (sandwich)    £{cafe_sales:>9,.2f}")
    L.append(f"     {'─' * 40}")
    L.append(f"     {'TOTAL':18s} £{pub_sales + cafe_sales:>9,.2f}")
    L.append("")

    # ──────── STAFF COST / INCOME RATIO ────────
    # Map team → pub or cafe, build per-site costs
    pub_cost = sum(float(s['cost_with_oncost'] or 0)
                   for s in shifts_yest
                   if (s['team'] or '').lower() in ('kitchen','front_of_house','accommodation'))
    cafe_cost = sum(float(s['cost_with_oncost'] or 0)
                    for s in shifts_yest
                    if (s['team'] or '').lower() == 'cafe')
    total_cost = pub_cost + cafe_cost

    L.append(f"STAFF COST / INCOME RATIO ({yesterday.strftime('%a %d %b')})")
    def pct(c, s): return f"{(c / s * 100):5.1f}%" if s > 0 else '   —'
    L.append(f"     Pub  (kitchen+FOH+accom)  £{pub_cost:>8,.2f}  /  £{pub_sales:>8,.2f}  = {pct(pub_cost, pub_sales)}")
    L.append(f"     Cafe (cafe team)          £{cafe_cost:>8,.2f}  /  £{cafe_sales:>8,.2f}  = {pct(cafe_cost, cafe_sales)}")
    L.append(f"     {'─' * 65}")
    L.append(f"     Combined                  £{total_cost:>8,.2f}  /  £{pub_sales + cafe_sales:>8,.2f}  = {pct(total_cost, pub_sales + cafe_sales)}")
    L.append("")

    # ──────── DELIVERIES ────────
    L.append(f"DELIVERIES PENDING (today + tomorrow)")
    if deliveries:
        for d in deliveries:
            L.append(f"     {d['delivery_date']}  {(d['vendor_name'] or d['vendor_domain'] or '?'):32s}  "
                     f"£{d['amount'] or 0:>8,.2f}")
    else:
        L.append("     None with extracted delivery dates.")
        L.append("     (Most invoices don't have delivery_date set — only set when")
        L.append("      Haiku line-extraction succeeds. u61 cron at :20 keeps draining.)")
    L.append("")

    # ──────── TOMORROW ────────
    L.append(f"TOMORROW'S ARRIVALS ({len(tom_arrivals)}) — {tomorrow.strftime('%a %d %b')}")
    for a in tom_arrivals:
        L.append(f"     {(a['guest_name'] or '?'):26s}  {(a['room'] or '?'):28s}  "
                 f"{a['source']:17s}  £{a['gross_amount'] or 0:>7,.2f}")
    if not tom_arrivals: L.append("     (none yet)")
    L.append("")

    L.append("═" * 76)
    L.append("All workflows in TEST mode. No guest-facing emails fired.")

    body = '\n'.join(L)
    print(body)

    payload = {
        'to': 'jolyon.sandercock@gmail.com',
        'subject': (f"[Home AI] Daily reality — {today.strftime('%a %d %b')}"
                    f" · {kpi['bookings_today']} arrivals · {len(covers)} covers"),
        'body_text': body,
    }
    req = urllib.request.Request('http://google-fetch:8011/send/bot',
        data=json.dumps(payload).encode(),
        headers={'Content-Type': 'application/json'}, method='POST')
    r = urllib.request.urlopen(req, timeout=15)
    print(f'\n\nsend: {r.status}, msg_id: {json.loads(r.read()).get("message_id")}')

    await conn.close()

asyncio.run(main())
