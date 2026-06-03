#!/usr/bin/env python3
"""
u160-breakfast-kitchen.py — 6am kitchen master summary.

Queries breakfast_orders for today's service_date. Groups by dish with guest
room numbers, allergies, and notes. Sends summary email.

TEST MODE: Sends to pounana@gmail.com instead of kitchen@malthousetintagel.com.

Runs from host cron at 06:00 UTC daily:
  0 6 * * * python3 /home_ai/scripts/u160-breakfast-kitchen.py >> /home_ai/logs/u160-breakfast-kitchen.log 2>&1
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import date
from collections import defaultdict

import requests

# ─── Config ─────────────────────────────────────────────────────
GOOGLE_FETCH_URL = "http://homeai-google-fetch:8011"
SEND_ACCOUNT = "info"
REPLY_TO = "info@malthousetintagel.com"
KITCHEN_EMAIL = "kitchen@malthousetintagel.com"

TEST_EMAIL = "pounana@gmail.com"
TEST_MODE = True  # Set to False for production


def psql(sql: str) -> str:
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


def send_email(to_email: str, subject: str, body: str) -> dict:
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
    today_str = today.isoformat()

    print(f"=== u160-breakfast-kitchen.py — {today_str} ===")

    # Query all breakfast orders for today
    orders = psql_json(f"""
        SELECT json_build_object(
            'id', bo.id,
            'guest_name', ab.guest_name,
            'room', ab.room,
            'dish', bo.dish,
            'hot_drink', bo.hot_drink,
            'allergies', bo.allergies,
            'notes', bo.notes,
            'guest_count', bes.guest_count
        ) AS row
        FROM breakfast_orders bo
        JOIN accommodation_bookings ab ON ab.id = bo.accommodation_booking_id
        JOIN breakfast_email_sends bes ON bes.email_token = bo.email_token
        WHERE bo.service_date = '{today_str}'::date
        ORDER BY bo.dish, ab.room
    """)

    if not orders:
        print("No breakfast orders for today.")
        subject = f"Breakfast orders for {today_str} — 0 orders"
        body = f"No breakfast pre-orders received for {today_str}.\n\n— The Malthouse"
        target = TEST_EMAIL if TEST_MODE else KITCHEN_EMAIL
        result = send_email(target, subject, body)
        print(f"Sent empty summary: {result}")
        return

    # Group by dish
    by_dish: dict[str, list[dict]] = defaultdict(list)
    total_orders = 0
    all_allergies: list[str] = []
    all_notes: list[str] = []

    for o in orders:
        row = o["row"]
        dish = row["dish"] or "Unknown"
        by_dish[dish].append(row)
        total_orders += 1
        if row.get("allergies"):
            all_allergies.append(f"{row['guest_name']} ({row['room']}): {row['allergies']}")
        if row.get("notes"):
            all_notes.append(f"{row['guest_name']} ({row['room']}): {row['notes']}")

    # Build email body
    lines = []
    lines.append(f"BREAKFAST ORDERS — {today_str}")
    lines.append(f"Total orders: {total_orders}")
    lines.append("=" * 50)
    lines.append("")

    for dish, items in sorted(by_dish.items()):
        lines.append(f"--- {dish} ({len(items)}) ---")
        for item in items:
            room = item["room"] or "?"
            name = item["guest_name"] or "Guest"
            drink = item.get("hot_drink") or ""
            details = f"  {name} — {room}"
            if drink:
                details += f" | Drink: {drink}"
            lines.append(details)
        lines.append("")

    if all_allergies:
        lines.append("=" * 50)
        lines.append("ALLERGIES / DIETARY:")
        for a in all_allergies:
            lines.append(f"  - {a}")
        lines.append("")

    if all_notes:
        lines.append("=" * 50)
        lines.append("NOTES:")
        for n in all_notes:
            lines.append(f"  - {n}")
        lines.append("")

    lines.append("— The Malthouse Breakfast System")

    body = "\n".join(lines)
    subject = f"Breakfast orders for {today_str} — {total_orders} orders"

    target = TEST_EMAIL if TEST_MODE else KITCHEN_EMAIL
    if TEST_MODE:
        print(f"TEST MODE: sending to {target} instead of {KITCHEN_EMAIL}")

    result = send_email(target, subject, body)
    print(f"Sent kitchen summary: {result.get('message_id', result)}")

    print("=== Done ===")


if __name__ == "__main__":
    main()
