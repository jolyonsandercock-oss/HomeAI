#!/usr/bin/env python3
"""
u160-breakfast-send.py — 5pm breakfast pre-order email sender.

Finds guests staying tonight (checkout_date > today AND checkin_date <= today)
who haven't yet received a breakfast email for tomorrow's date.

Sends each guest an email with a unique token link to /breakfast?stay=<token>.
Token is sha256(booking_id + guest_email + secret).

TEST MODE: All emails go to pounana@gmail.com instead of the real guest email.
Email mentions a physical form is available in the room.

Runs from host cron at 17:00 UTC daily:
  0 17 * * * python3 /home_ai/scripts/u160-breakfast-send.py >> /home_ai/logs/u160-breakfast-send.log 2>&1
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from datetime import date, timedelta

import requests

# ─── Config ─────────────────────────────────────────────────────
GOOGLE_FETCH_URL = "http://homeai-google-fetch:8011"
SEND_ACCOUNT = "info"       # sends as info@malthousetintagel.com
REPLY_TO = "info@malthousetintagel.com"
FROM_NAME = "The Malthouse Tintagel"

# SECRET used for token generation — change if tokens need to be invalidated
TOKEN_SECRET = os.environ.get("BREAKFAST_TOKEN_SECRET", "")
if not TOKEN_SECRET:
    raise SystemExit("BREAKFAST_TOKEN_SECRET missing/empty — Vault secret/breakfast, mirrored in /home_ai/.env (U250)")

# TEST MODE — all emails go here instead of guest emails
TEST_EMAIL = "pounana@gmail.com"
TEST_MODE = True  # Set to False for production

# ─── SQL helpers ────────────────────────────────────────────────
def psql(sql: str) -> str:
    """Run a SQL query via docker exec psql and return stdout."""
    r = subprocess.run(
        ["docker", "exec", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai",
         "-t", "-A", "-c", sql],
        capture_output=True, text=True, timeout=30
    )
    if r.returncode != 0:
        print(f"psql error: {r.stderr}", file=sys.stderr)
        sys.exit(1)
    return r.stdout.strip()


def psql_json(sql: str) -> list[dict]:
    """Run SQL with JSON output and parse."""
    r = subprocess.run(
        ["docker", "exec", "homeai-postgres", "psql", "-U", "postgres", "-d", "homeai",
         "-t", "-A", "-c", sql],
        capture_output=True, text=True, timeout=30
    )
    if r.returncode != 0:
        print(f"psql error: {r.stderr}", file=sys.stderr)
        sys.exit(1)
    rows = []
    for line in r.stdout.strip().split("\n"):
        line = line.strip()
        if line:
            rows.append(json.loads(line))
    return rows


def generate_token(booking_id: int, guest_email: str) -> str:
    """Generate a unique token for a booking."""
    raw = f"{booking_id}:{guest_email}:{TOKEN_SECRET}"
    return hashlib.sha256(raw.encode()).hexdigest()


def send_email(to_email: str, subject: str, body: str) -> dict:
    """Send email via google-fetch service."""
    payload = {
        "to": to_email,
        "subject": subject,
        "body_text": body,
        "reply_to": REPLY_TO,
        "bcc": "jolyon.sandercock@gmail.com" if to_email == "jo.wood103@gmail.com" else None,
    }
    try:
        r = requests.post(
            f"{GOOGLE_FETCH_URL}/send/{SEND_ACCOUNT}",
            json=payload,
            timeout=60
        )
        r.raise_for_status()
        return r.json()
    except requests.RequestException as e:
        print(f"Email send failed: {e}", file=sys.stderr)
        return {"error": str(e)}


def main():
    today = date.today()
    tomorrow = today + timedelta(days=1)
    today_str = today.isoformat()
    tomorrow_str = tomorrow.isoformat()

    print(f"=== u160-breakfast-send.py — {today_str} ===")

    # Find guests staying tonight: checkin <= today AND checkout > today
    # AND not already sent for tomorrow
    guests = psql_json(f"""
        SELECT json_build_object(
            'booking_id', ab.id,
            'guest_name', ab.guest_name,
            'room', ab.room,
            'guest_email', ab.guest_email,
            'adults', ab.adults,
            'children', ab.children,
            'checkin', ab.checkin_date,
            'checkout', ab.checkout_date
        ) AS row
        FROM accommodation_bookings ab
        WHERE ab.checkin_date <= '{today_str}'::date
          AND ab.checkout_date > '{today_str}'::date
          AND ab.status IN ('confirmed', 'deposit_paid', 'paid', 'active')
          AND ab.guest_email IS NOT NULL
          AND ab.guest_email != ''
          AND NOT EXISTS (
            SELECT 1 FROM breakfast_email_sends bes
            WHERE bes.accommodation_booking_id = ab.id
              AND bes.service_date = '{tomorrow_str}'::date
          )
        ORDER BY ab.room
    """)

    if not guests:
        print("No guests need breakfast emails today.")
        return

    print(f"Found {len(guests)} guests to send breakfast emails.")

    for g in guests:
        row = g["row"]
        booking_id = row["booking_id"]
        guest_name = row["guest_name"] or "Guest"
        room = row["room"] or "your room"
        guest_email = row["guest_email"]
        adults = row["adults"] or 0
        children = row["children"] or 0
        guest_count = adults + children

        # Generate token
        token = generate_token(booking_id, guest_email)

        # Determine target email
        target_email = TEST_EMAIL if TEST_MODE else guest_email
        if TEST_MODE:
            print(f"  TEST MODE: {guest_name} ({room}) -> {target_email} (real: {guest_email})")

        # Build email
        link = f"https://jolybox.tailc27dff.ts.net/app/breakfast?stay={token}"
        subject = f"Breakfast pre-order for {tomorrow_str} — The Malthouse"
        body = f"""Hello {guest_name},

We hope you're enjoying your stay at The Malthouse Tintagel!

Please pre-order your breakfast for tomorrow morning ({tomorrow_str}) using the link below:

  {link}

You can select your dish, hot drink, and note any allergies or dietary requirements.

Orders must be in by 6am on the day of breakfast.

A physical breakfast order form is also available in your room if you prefer.

Warm regards,
The Malthouse Tintagel
"""

        # Insert send record
        try:
            psql(f"""
                INSERT INTO breakfast_email_sends
                  (accommodation_booking_id, email_token, service_date,
                   guest_email, guest_count, realm)
                VALUES
                  ({booking_id}, '{token}', '{tomorrow_str}',
                   '{guest_email}', {guest_count}, 'work')
                ON CONFLICT (accommodation_booking_id, service_date) DO NOTHING
            """)
        except Exception as e:
            print(f"  DB insert error for {guest_name}: {e}", file=sys.stderr)
            continue

        # Send email
        result = send_email(target_email, subject, body)
        if "message_id" in result:
            msg_id = result["message_id"]
            print(f"  Sent to {guest_name} ({room}): {msg_id}")
            # Update gmail_message_id
            psql(f"""
                UPDATE breakfast_email_sends
                SET gmail_message_id = '{msg_id}'
                WHERE email_token = '{token}'
            """)
        else:
            print(f"  Failed to send to {guest_name}: {result.get('error', 'unknown')}")

    print("=== Done ===")


if __name__ == "__main__":
    main()
