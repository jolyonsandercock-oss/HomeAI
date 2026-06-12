#!/usr/bin/env python3
"""u286-caterbook-guest-sync.py — guest email+phone from the Caterbook PMS API.

Discovery 2026-06-12: Caterbook's Angular app drives a clean JSON API
(api.caterbook.net). Auth: POST /api/User/Login {username,password,accountID}
with header application-name:app → raw JWT in the Authorization header
(NO 'Bearer ' prefix). Then:
  GET /api/Property/GetArrivals?date=<'Fri Jun 12 2026'>  → bookingId per arrival
  GET /api/Booking/GetBookingDetails?bookingId=N          → email, phone, phone2

Sync: walk arrivals over [today-WINDOW_BACK, today+WINDOW_FWD], pull details,
fill accommodation_bookings.guest_email/guest_phone (NULLs only — never
overwrite) matched by checkin_date + guest surname (case-insensitive).
READ-ONLY against Caterbook. Idempotent. Run inside playwright container
(has egress + vault):
  docker exec -i -e VAULT_TOKEN=... homeai-playwright python3 - < this
DB writes go through docker exec psql ... no wait — playwright lacks docker.
DB writes are emitted as SQL on stdout marker lines consumed by the wrapper
u286-caterbook-guest-sync.sh. Keep stdout protocol stable.
"""
import json
import os
import time
import urllib.parse
import urllib.request
from datetime import date, timedelta

VT = os.environ["VAULT_TOKEN"]
WINDOW_BACK = int(os.environ.get("WINDOW_BACK", "30"))
WINDOW_FWD = int(os.environ.get("WINDOW_FWD", "120"))


def vault(p):
    r = urllib.request.urlopen(urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{p}", headers={"X-Vault-Token": VT}), timeout=5)
    return json.loads(r.read())["data"]["data"]


def main():
    c = vault("caterbook")
    H = {"Content-Type": "application/json", "application-name": "app",
         "Origin": "https://app.caterbook.net", "Referer": "https://app.caterbook.net/"}
    r = json.loads(urllib.request.urlopen(urllib.request.Request(
        "https://api.caterbook.net/api/User/Login",
        data=json.dumps({"username": c["username"], "password": c["password"],
                         "accountID": str(c["account_id"])}).encode(),
        headers=H, method="POST"), timeout=30).read())
    tok = next((v for v in r.values() if isinstance(v, str) and v.startswith("eyJ")), "")
    if not tok:
        print("FATAL no token"); return
    HA = {**H, "Authorization": tok}

    def get(u):
        return json.loads(urllib.request.urlopen(
            urllib.request.Request(u, headers=HA), timeout=30).read())

    seen_booking_ids = set()
    found = 0
    today = date.today()
    for off in range(-WINDOW_BACK, WINDOW_FWD + 1):
        d = today + timedelta(days=off)
        ds = urllib.parse.quote(d.strftime("%a %b %d %Y"))
        try:
            arrivals = get(f"https://api.caterbook.net/api/Property/GetArrivals?date={ds}")
        except Exception as e:
            print(f"# arrivals {d} failed: {str(e)[:60]}")
            continue
        if not isinstance(arrivals, list):
            arrivals = arrivals.get("data") or []
        for a in arrivals:
            bid = a.get("bookingId")
            if not bid or bid in seen_booking_ids:
                continue
            seen_booking_ids.add(bid)
            try:
                det = get(f"https://api.caterbook.net/api/Booking/GetBookingDetails?bookingId={bid}")
            except Exception as e:
                print(f"# details {bid} failed: {str(e)[:60]}")
                continue
            blob = json.dumps(det)
            # contact fields can nest — find first email/phone anywhere
            def find(obj, key):
                if isinstance(obj, dict):
                    for k, v in obj.items():
                        if k.lower() == key and isinstance(v, str) and v.strip():
                            return v.strip()
                        r2 = find(v, key)
                        if r2:
                            return r2
                elif isinstance(obj, list):
                    for it in obj:
                        r2 = find(it, key)
                        if r2:
                            return r2
                return None
            email = find(det, "email")
            phone = find(det, "phone") or find(det, "phone2")
            booker = (a.get("booker") or "").strip()
            if not (email or phone) or not booker:
                continue
            surname = booker.split()[-1].replace("'", "''")
            email_sql = f"'{email.replace(chr(39), chr(39)*2)}'" if email else "NULL"
            phone_sql = f"'{phone.replace(chr(39), chr(39)*2)}'" if phone else "NULL"
            found += 1
            print("SQL\t"
                  f"UPDATE accommodation_bookings SET "
                  f"guest_email = COALESCE(guest_email, {email_sql}), "
                  f"guest_phone = COALESCE(guest_phone, {phone_sql}) "
                  f"WHERE checkin_date = '{d}' "
                  f"AND lower(guest_name) LIKE '%{surname.lower()}%' "
                  f"AND (guest_email IS NULL OR guest_phone IS NULL);")
            time.sleep(0.3)
        time.sleep(0.2)
    print(f"# done: {len(seen_booking_ids)} bookings inspected, {found} with contacts")


main()
