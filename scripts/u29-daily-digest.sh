#!/bin/bash
# /home_ai/scripts/u29-daily-digest.sh
#
# P10 Daily Digest — fires at 21:00, rolls up the day across the live
# pipelines, sends as email (Gmail API via google-fetch) and Telegram.
#
# Usage:
#   ./scripts/u29-daily-digest.sh              # today
#   ./scripts/u29-daily-digest.sh 2026-05-10   # backfill

set -euo pipefail
DATE="${1:-$(date '+%Y-%m-%d')}"
VAULT_TOKEN=$(docker inspect homeai-google-fetch --format='{{range .Config.Env}}{{println .}}{{end}}' | grep '^VAULT_TOKEN=' | cut -d= -f2-)

docker exec -i -e DATE="$DATE" -e VAULT_TOKEN="$VAULT_TOKEN" homeai-playwright python << 'PYEOF'
import os, asyncio, json, urllib.request, urllib.parse, urllib.error
from datetime import date as _date
import asyncpg

DATE = os.environ["DATE"]
DATE_OBJ = _date.fromisoformat(DATE)
VAULT_TOKEN = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]


def fmt_money(v):
    if v is None: return "—"
    try:    return f"£{float(v):,.2f}"
    except: return "—"


def vault_get(path, field):
    req = urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{path}",
        headers={"X-Vault-Token": VAULT_TOKEN})
    r = urllib.request.urlopen(req, timeout=5)
    return json.loads(r.read())["data"]["data"].get(field)


async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity = 'all'")

    to_sites = await conn.fetch("""
      SELECT s.site,
             (SELECT value    FROM touchoffice_fixed_totals f WHERE f.site=s.site AND f.report_date=$1 AND f.label='NET sales')   AS net,
             (SELECT value    FROM touchoffice_fixed_totals f WHERE f.site=s.site AND f.report_date=$1 AND f.label='GROSS Sales') AS gross,
             (SELECT quantity FROM touchoffice_fixed_totals f WHERE f.site=s.site AND f.report_date=$1 AND f.label='Covers')      AS covers
        FROM (VALUES ('malthouse'),('sandwich')) AS s(site)
    """, DATE_OBJ)

    snap = await conn.fetchrow("""
      SELECT arrivals, stayovers, departures,
             arrivals_count, stayovers_count, departures_count,
             in_house_count, revenue_in_house
        FROM caterbook_daily_snapshots WHERE report_date=$1
    """, DATE_OBJ)

    cb_lists = {"arrivals": [], "stayovers": [], "departures": []}
    if snap:
        for k in cb_lists:
            v = snap[k]
            cb_lists[k] = json.loads(v) if isinstance(v, str) else (v or [])

    kids = await conn.fetch("""
      SELECT c.name, ce.summary
        FROM child_events ce JOIN children c ON c.id=ce.child_id
       WHERE ce.event_date=$1 AND ce.event_type='school_correspondence'
       ORDER BY c.name LIMIT 10
    """, DATE_OBJ)

    firing = await conn.fetchval(
        "SELECT COUNT(*) FROM system_alerts WHERE status='firing' AND acknowledged=false")
    scrape_fails = await conn.fetchval("""
      SELECT COUNT(*) FROM touchoffice_scrapes
       WHERE scraped_at::date=$1 AND success=false
    """, DATE_OBJ)
    uncertain = await conn.fetch("""
      SELECT email_id, gmail_message_id, account, from_address, subject,
             classification, confidence_score
        FROM v_classifier_uncertain
       WHERE received_at::date=$1
         AND already_reviewed=false
       ORDER BY confidence_score ASC, received_at DESC
       LIMIT 5
    """, DATE_OBJ)
    await conn.close()

    pub  = next((r for r in to_sites if r["site"] == "malthouse"), None)
    sand = next((r for r in to_sites if r["site"] == "sandwich"),  None)

    L = [f"Home AI — Daily Digest for {DATE}", "=" * 50, ""]

    L.append("PUB (Malthouse)")
    if pub and pub["net"] is not None:
        L.append(f"  NET   {fmt_money(pub['net'])}   GROSS {fmt_money(pub['gross'])}   covers {int(pub['covers'] or 0)}")
    else:
        L.append("  no TouchOffice data for this date")
    L.append("")

    L.append("SANDWICH BAR (Ice Cream)")
    if sand and sand["net"] is not None:
        L.append(f"  NET   {fmt_money(sand['net'])}   GROSS {fmt_money(sand['gross'])}   covers {int(sand['covers'] or 0)}")
    else:
        L.append("  no TouchOffice data for this date")
    L.append("")

    L.append("ACCOMMODATION (Caterbook)")
    if snap:
        L.append(f"  in-house {snap['in_house_count']}  ·  revenue {fmt_money(snap['revenue_in_house'])}")
        L.append(f"  arrivals {snap['arrivals_count']}  ·  stayovers {snap['stayovers_count']}  ·  departures {snap['departures_count']}")
        if cb_lists["arrivals"]:
            L.append("  ARRIVING:")
            for a in cb_lists["arrivals"]:
                L.append(f"    {a.get('room', '?'):8} {a.get('guest', '?')}  {fmt_money(a.get('balance'))}")
        if cb_lists["departures"]:
            L.append("  DEPARTING:")
            for d in cb_lists["departures"]:
                L.append(f"    {d.get('room', '?'):8} {d.get('guest', '?')}")
    else:
        L.append("  no Caterbook email for this date")
    L.append("")

    if kids:
        L.append("CHILDREN (school correspondence today)")
        for k in kids:
            L.append(f"  {k['name']:22} {(k['summary'] or '')[:60]}")
        L.append("")

    if uncertain:
        L.append("UNCERTAIN CLASSIFICATIONS — top 5 today")
        for u in uncertain:
            src = (u["from_address"] or "?")[:32]
            sub = (u["subject"] or "")[:48]
            L.append(f"  {u['confidence_score']:.2f}  {u['classification']:9}  {src:32}  {sub}")
        L.append("  → http://100.104.82.53/dashboard/invoices  (click ✎ to teach the AI)")
        L.append("")

    L.append("HEALTH")
    L.append(f"  firing+unacked alerts: {firing}    scrape failures today: {scrape_fails}")
    L.append("")
    L.append("— jolyboxbot")

    body_text = "\n".join(L)

    # ── HTML ──
    H = [
        '<html><body style="font-family:system-ui;color:#1e293b;max-width:680px">',
        f'<h2 style="margin-bottom:0.3em">Home AI — Daily Digest</h2>',
        f'<p style="color:#64748b;margin-top:0">{DATE}</p>',
    ]

    H.append('<h3>Pub (Malthouse)</h3>')
    if pub and pub["net"] is not None:
        H.append(f'<p>NET <b>{fmt_money(pub["net"])}</b> · GROSS {fmt_money(pub["gross"])} · covers <b>{int(pub["covers"] or 0)}</b></p>')
    else:
        H.append('<p><i>no TouchOffice data for this date</i></p>')

    H.append('<h3>Sandwich Bar (Ice Cream)</h3>')
    if sand and sand["net"] is not None:
        H.append(f'<p>NET <b>{fmt_money(sand["net"])}</b> · GROSS {fmt_money(sand["gross"])} · covers <b>{int(sand["covers"] or 0)}</b></p>')
    else:
        H.append('<p><i>no TouchOffice data for this date</i></p>')

    H.append('<h3>Accommodation (Caterbook)</h3>')
    if snap:
        H.append(f'<p>In-house <b>{snap["in_house_count"]}</b> · revenue <b>{fmt_money(snap["revenue_in_house"])}</b> · arrivals {snap["arrivals_count"]} · stayovers {snap["stayovers_count"]} · departures {snap["departures_count"]}</p>')
        if cb_lists["arrivals"]:
            H.append('<p><b>Arriving today:</b></p><ul>')
            for a in cb_lists["arrivals"]:
                H.append(f'<li><code>{a.get("room", "?")}</code> {a.get("guest", "?")} — {fmt_money(a.get("balance"))}</li>')
            H.append('</ul>')
        if cb_lists["departures"]:
            H.append('<p><b>Departing today:</b></p><ul>')
            for d in cb_lists["departures"]:
                H.append(f'<li><code>{d.get("room", "?")}</code> {d.get("guest", "?")}</li>')
            H.append('</ul>')
    else:
        H.append('<p><i>no Caterbook email for this date</i></p>')

    if kids:
        H.append('<h3>Children — school mail today</h3><ul>')
        for k in kids:
            H.append(f'<li><b>{k["name"]}</b>: {(k["summary"] or "")[:120]}</li>')
        H.append('</ul>')

    if uncertain:
        H.append('<h3>Uncertain classifications — top 5 today</h3>')
        H.append('<table style="border-collapse:collapse;font-size:0.9em">')
        H.append('<tr style="color:#64748b"><th align="left">conf</th><th align="left">class</th><th align="left">from</th><th align="left">subject</th></tr>')
        for u in uncertain:
            url = f'http://100.104.82.53/dashboard/viewer/email/{u["account"]}/{u["gmail_message_id"]}'
            H.append(
                f'<tr><td style="padding:2px 8px">{u["confidence_score"]:.2f}</td>'
                f'<td style="padding:2px 8px"><b>{u["classification"]}</b></td>'
                f'<td style="padding:2px 8px">{(u["from_address"] or "?")[:32]}</td>'
                f'<td style="padding:2px 8px"><a href="{url}">{(u["subject"] or "")[:60]}</a></td></tr>')
        H.append('</table>')
        H.append('<p style="color:#64748b;font-size:0.85em">→ <a href="http://100.104.82.53/dashboard/invoices">open invoices page</a> and click ✎ on any row to teach the AI.</p>')

    H.append(f'<p style="color:#64748b;font-size:0.85em">firing+unacked alerts: {firing} · scrape failures today: {scrape_fails}</p>')
    H.append('<p style="color:#64748b">— jolyboxbot</p></body></html>')
    body_html = "".join(H)

    # ── Send email ──
    payload = {
        "to": "jolyon.sandercock@gmail.com",
        "subject": f"Daily Digest {DATE} — Malthouse",
        "reply_to": "jolyboxbot@gmail.com",
        "body_text": body_text,
        "body_html": body_html,
    }
    try:
        req = urllib.request.Request(
            "http://google-fetch:8011/send/bot", method="POST",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"})
        r = urllib.request.urlopen(req, timeout=30)
        print("email sent:", json.loads(r.read())["message_id"])
    except urllib.error.HTTPError as e:
        print("email FAILED:", e.code, e.read().decode()[:300])
    except Exception as e:
        print("email FAILED:", e)

    # ── Send Telegram (short version) ──
    try:
        tok  = vault_get("telegram", "bot_token")
        chat = vault_get("telegram", "chat_id")
        short = body_text.split("HEALTH")[0].rstrip()
        if len(short) > 3500:
            short = short[:3500] + "\n...(truncated — see email)"
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{tok}/sendMessage",
            data=urllib.parse.urlencode({"chat_id": chat, "text": short}).encode())
        r = urllib.request.urlopen(req, timeout=15)
        out = json.loads(r.read())
        print("telegram sent: msg_id=" + str(out.get("result", {}).get("message_id")))
    except Exception as e:
        print("telegram FAILED:", e)


asyncio.run(main())
PYEOF
