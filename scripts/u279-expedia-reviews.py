#!/usr/bin/env python3
"""u279-expedia-reviews.py — surface Expedia review notifications in guest_reviews.

Source emails: from noreply@expediapartnercentral.com, subject 'You have a new review'.
UNLIKE Google/TripAdvisor, the Expedia notification is NOTIFICATION-ONLY — its body
("A guest who recently stayed ... has published a review that now appears on Expedia
Group") carries NO rating, reviewer name, or review text; you must open Partner Central
to read it. So this inserts one PLACEHOLDER review per notification (rating NULL, body =
open-Partner-Central) so it surfaces in the reviews section as needing a response.
Fabricating a rating/text would be a data-integrity violation — the data isn't in the email.

Dedup: review_id = 'exp-<email_id>'. We match only the ORIGINAL Expedia email (from
expediapartnercentral.com), never Jo's forwards (which are from jolyon/admin addresses),
so each genuine review maps to exactly one row.
Idempotent: ON CONFLICT (source, review_id) DO NOTHING.
Run inside bot-responder: docker exec -i homeai-bot-responder python3 - < this
"""
import asyncio
import os
import asyncpg

PG_DSN = os.environ.get("PG_DSN") or f"postgresql://postgres:{os.environ['PGPASS']}@homeai-postgres:5432/homeai"
PLACEHOLDER = "Expedia review notification — open Partner Central to read & respond"


async def main():
    conn = await asyncpg.connect(PG_DSN)
    await conn.execute("SET app.current_entity='all'")
    rows = await conn.fetch("""
        SELECT id, received_at
          FROM emails
         WHERE from_address ILIKE '%expediapartnercentral.com%'
           AND subject ILIKE '%new review%'
         ORDER BY received_at DESC LIMIT 200""")
    ins = 0
    for r in rows:
        review_id = "exp-" + str(r["id"])     # one notification = one review
        n = await conn.fetchval("""
            INSERT INTO guest_reviews (review_id, source, location, rating, posted_at,
                                       reviewer_name, body, status)
            VALUES ($1, 'expedia', 'malthouse', NULL, $2, '', $3, 'new')
            ON CONFLICT (source, review_id) DO NOTHING
            RETURNING 1""",
            review_id, r["received_at"], PLACEHOLDER)
        ins += 1 if n else 0
    await conn.close()
    print(f"expedia reviews: scanned={len(rows)} placeholder-inserted={ins}")


asyncio.run(main())
