#!/usr/bin/env python3
"""u279-expedia-reviews.py — parse Expedia review notifications into guest_reviews.

Source emails: from noreply@expediapartnercentral.com, subject 'You have a new review'.
The Expedia email DOES contain the full review — the content sits AFTER a large CSS/<style>
block (an earlier "notification-only" read was wrong: it only looked at the CSS preamble).
Structure of the stripped body:
    ...appears on Expedia Group sites. <rating> <label> <review text> <reviewer> <date> It looks like...
e.g. "10.0 Excellent It was a very good experience... Michael Jun 25, 2026".

Rating is Expedia's /10 scale → stored as integer, like booking_com (also /10). If the
review can't be parsed, fall back to a placeholder so nothing is silently lost.
Dedup: review_id = 'exp-<email_id>' (match only the ORIGINAL from expedia, not Jo's forwards).
Idempotent: ON CONFLICT (source, review_id) DO UPDATE — re-running upgrades earlier
placeholders to the parsed review.
Run inside bot-responder: docker exec -i homeai-bot-responder python3 - < this
"""
import asyncio
import html
import os
import re
from datetime import datetime
import asyncpg

PG_DSN = os.environ.get("PG_DSN") or f"postgresql://postgres:{os.environ['PGPASS']}@homeai-postgres:5432/homeai"
LABELS = r"Exceptional|Excellent|Wonderful|Very Good|Good|Okay|Mediocre|Fair|Poor|Disappointing|Average|Horrible|Terrible"
PLACEHOLDER = "Expedia review notification — open Partner Central to read & respond"


def strip_html(t: str) -> str:
    t = re.sub(r"(?is)<(style|head|script)[^>]*>.*?</\1>", " ", t or "")
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", t))).strip()


def parse_review(body: str):
    """Return (rating:int|None, reviewer:str, text:str, posted:date|None)."""
    m_rate = re.search(r"Expedia Group sites\.\s*([\d]+(?:\.[\d]+)?)", body)
    m_who = re.search(r"([A-Z][a-z]+)\s+([A-Z][a-z]{2}\s\d{1,2},\s\d{4})\s+(?:It looks like|Take a minute|View and reply)", body)
    if not (m_rate and m_who):
        return None, "", "", None
    rating = int(round(float(m_rate.group(1))))            # /10 scale, like booking_com
    reviewer = m_who.group(1)
    try:
        posted = datetime.strptime(m_who.group(2), "%b %d, %Y").date()
    except ValueError:
        posted = None
    seg = body[m_rate.end():m_who.start()].strip()
    seg = re.sub(rf"^(?:{LABELS})\s+", "", seg, flags=re.I)  # drop the leading rating label
    return rating, reviewer, seg.strip(), posted


async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity='all'")
    rows = await conn.fetch("""
        SELECT id, received_at, body_text
          FROM emails
         WHERE from_address ILIKE '%expediapartnercentral.com%'
           AND subject ILIKE '%new review%'
         ORDER BY received_at DESC LIMIT 200""")
    done = parsed = 0
    for r in rows:
        rating, reviewer, text, posted = parse_review(strip_html(r["body_text"]))
        if text:
            parsed += 1
        review_id = "exp-" + str(r["id"])
        await conn.execute("""
            INSERT INTO guest_reviews (review_id, source, location, rating, posted_at,
                                       reviewer_name, body, status)
            VALUES ($1, 'expedia', 'malthouse', $2, $3, $4, $5, 'approved')
            ON CONFLICT (source, review_id) DO UPDATE SET
              rating        = EXCLUDED.rating,
              reviewer_name = EXCLUDED.reviewer_name,
              body          = EXCLUDED.body,
              posted_at     = EXCLUDED.posted_at,
              status        = 'approved'""",
            review_id, rating, (posted or r["received_at"].date()),
            reviewer[:80], (text or PLACEHOLDER)[:2000])
        done += 1
    await conn.close()
    print(f"expedia reviews: scanned={len(rows)} written={done} fully-parsed={parsed}")


asyncio.run(main())
