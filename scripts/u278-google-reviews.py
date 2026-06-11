#!/usr/bin/env python3
"""u278-google-reviews.py — parse Google Business Profile review notifications
into guest_reviews (snag #59: google reviews had NO parser; latest stuck at
2026-05-23 while notifications kept arriving).

Source emails: businessprofile-noreply@google.com
  subject 'NAME left a review for The Olde Malthouse'
  body    '... new N-star review Read review NAME TEXT Reply to review ...'
Idempotent: ON CONFLICT (source, review_id) DO NOTHING.
Run inside bot-responder: docker exec -i homeai-bot-responder python3 - < this
"""
import asyncio
import html
import os
import re

import asyncpg

PG_DSN = os.environ.get("PG_DSN") or f"postgresql://postgres:{os.environ['PGPASS']}@homeai-postgres:5432/homeai"


def strip_html(t: str) -> str:
    return html.unescape(re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", t or "")))


async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity='all'")
    rows = await conn.fetch("""
        SELECT id, subject, body_text, received_at
          FROM emails
         WHERE from_address = 'businessprofile-noreply@google.com'
           AND subject ILIKE '%left a review%'
         ORDER BY received_at DESC LIMIT 200""")
    ins = skip = 0
    for r in rows:
        body = strip_html(r["body_text"])
        m_rating = re.search(r"new ([1-5])-star review", body)
        rating = int(m_rating.group(1)) if m_rating else None
        m_name = re.match(r"^(.*?) left a review", r["subject"] or "")
        reviewer = (m_name.group(1).strip() if m_name else "")[:80]
        m_text = re.search(r"Read review\s+(.*?)\s+Reply to review", body)
        text = (m_text.group(1).strip() if m_text else "")
        # body block starts with the reviewer's full name — drop it if present
        if reviewer and text.lower().startswith(reviewer.lower()):
            text = text[len(reviewer):].strip()
        # full display name (first token matches subject name) for dedup id
        review_id = "g-" + str(r["id"])
        if rating is None and not text:
            skip += 1
            continue
        n = await conn.fetchval("""
            INSERT INTO guest_reviews (review_id, source, location, rating, posted_at,
                                       reviewer_name, body, status)
            VALUES ($1, 'google', 'malthouse', $2, $3, $4, $5, 'approved')
            ON CONFLICT (source, review_id) DO NOTHING
            RETURNING 1""",
            review_id, rating, r["received_at"], reviewer,
            text[:2000] or "Review text not available")
        ins += 1 if n else 0
    await conn.close()
    print(f"google reviews: scanned={len(rows)} inserted={ins} unparseable={skip}")


asyncio.run(main())
