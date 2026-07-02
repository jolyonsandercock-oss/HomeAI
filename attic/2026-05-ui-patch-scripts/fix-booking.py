#!/usr/bin/env python3
"""Fix booking scraper SQL and clean up fake entries."""

path = "/home_ai/scripts/booking-scraper.py"

with open(path) as f:
    content = f.read()

old = """    rows = await conn.fetch(\"\"\"
        SELECT e.id, e.subject, e.body_text, e.received_at
        FROM emails e
        WHERE (e.from_address ILIKE '%booking.com%' OR e.subject ILIKE '%Guest review%')
          AND (e.subject ILIKE '%review%' OR e.subject ILIKE '%guest%')
          AND e.received_at > NOW() - INTERVAL '90 days'
          AND NOT EXISTS (SELECT 1 FROM guest_reviews gr WHERE gr.source='booking_com' AND gr.review_id = e.id::text)
        ORDER BY e.received_at DESC
        LIMIT 50
    \"\"\")"""

new = """    rows = await conn.fetch(\"\"\"
        SELECT e.id, e.subject, e.body_text, e.received_at
        FROM emails e
        WHERE e.from_address ILIKE '%booking.com%'
          AND e.subject ILIKE ANY (ARRAY[
            '%Guest review%',
            '%has left a review%',
            '%New review%',
            '%review for %'
          ])
          AND e.received_at > NOW() - INTERVAL '90 days'
          AND NOT EXISTS (SELECT 1 FROM guest_reviews gr WHERE gr.source='booking_com' AND gr.review_id = e.id::text)
        ORDER BY e.received_at DESC
        LIMIT 50
    \"\"\")"""

count = content.count(old)
print(f"Found {count} occurrences")

if count == 1:
    content = content.replace(old, new)
    with open(path, "w") as f:
        f.write(content)
    print("booking-scraper.py updated")
else:
    print("ERROR: expected exactly 1 match")
