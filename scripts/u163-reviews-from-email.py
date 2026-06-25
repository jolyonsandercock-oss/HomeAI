#!/usr/bin/env python3
"""
U163 — review ingestion via notification emails (not web scraping).

TripAdvisor + Google both email when a new review lands. Parsing those
emails is reliable, low-cost, and avoids the DataDome / consent-wall
mess of scraping the public pages.

Walks recent Gmail across inboxes (admin, info, jo, pounana), filters
on subject patterns, extracts (reviewer, rating, body, source, location)
via Haiku, upserts into guest_reviews keyed by (source, review_id).

Idempotent — re-running won't duplicate.

Designed to run inside homeai-playwright (has urllib + asyncpg).
"""
import asyncio
import asyncpg
import base64
import hashlib
import html
import json
import os
import re
import time
import urllib.parse
import urllib.request
import urllib.error


PG_DSN            = os.environ["PG_DSN"]
ANTHROPIC_API_KEY = os.environ["ANTHROPIC_API_KEY"]
DAYS_BACK         = int(os.environ.get("DAYS_BACK", "180"))

GMAIL_QUERIES = [
    # (account, query, source_hint) — hint, when set, deterministically tags the source.
    # Expedia first so its hint wins over the generic "new review" admin query below
    # ("You have a new review" also matches that generic query).
    ("admin",   'newer_than:{d}d from:noreply@expediapartnercentral.com subject:"You have a new review"', "expedia"),
    ("admin",   'newer_than:{d}d (subject:"left a review" OR subject:"new review")',     None),
    ("info",    'newer_than:{d}d (from:tripadvisor.com OR from:tripadvisor.co.uk)',      "tripadvisor"),
    ("pounana", 'newer_than:{d}d (from:tripadvisor.com OR from:tripadvisor.co.uk)',      "tripadvisor"),
    ("jo",      'newer_than:{d}d (subject:"left a review" OR subject:"new review")',     None),
]


def fetch_msg_body(account: str, msg_id: str) -> str:
    url = f"http://google-fetch:8011/message/{account}/{msg_id}"
    r = urllib.request.urlopen(url, timeout=20)
    msg = json.loads(r.read())

    def extract(p):
        out = []
        d = p.get("body", {}).get("data", "")
        if d:
            try: out.append(base64.urlsafe_b64decode(d + "==").decode("utf-8", "ignore"))
            except Exception: pass
        for x in p.get("parts", []):
            out.extend(extract(x))
        return out

    text = "\n".join(extract(msg.get("payload", {})))
    clean = re.sub(r"<[^>]+>", " ", text)
    clean = html.unescape(clean)
    clean = re.sub(r"\s+", " ", clean).strip()

    # Headers
    hdrs = {h["name"]: h["value"] for h in msg.get("payload", {}).get("headers", [])}
    return {
        "from":    hdrs.get("From", ""),
        "subject": hdrs.get("Subject", ""),
        "date":    hdrs.get("Date", ""),
        "body":    clean[:5000],
    }


def haiku_extract(email_body: dict) -> dict | None:
    """Use Haiku to extract structured review from a notification email."""
    prompt = f"""You are parsing a "new review" notification email from TripAdvisor or Google.

Subject: {email_body['subject']}
From: {email_body['from']}
Date: {email_body['date']}
Body (first 3000 chars):
{email_body['body'][:3000]}

Extract JSON with these fields (use null when unknown):
{{
  "source": "tripadvisor" | "google" | "expedia",
  "location": "malthouse" | "sandwich" | null,
  "reviewer_name": string | null,
  "rating": integer 1-5 | null,
  "body_text": string (excerpt of the actual review text if present, null if rating-only),
  "review_url": string | null,
  "is_review_notification": true | false  // false if it's not actually a review email
}}

Return ONLY the JSON, no preamble.
"""
    payload = {
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 500,
        "messages": [{"role": "user", "content": prompt}]
    }
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(payload).encode(),
        headers={
            "x-api-key":         ANTHROPIC_API_KEY,
            "anthropic-version": "2023-06-01",
            "content-type":      "application/json",
        }
    )
    # U245: retry/cooldown on 529/overloaded + transient network before giving up.
    resp = None
    for _att in range(6):
        try:
            resp = json.loads(urllib.request.urlopen(req, timeout=30).read())
            break
        except urllib.error.HTTPError as e:
            if e.code in (408, 409, 429, 500, 502, 503, 529) and _att < 5:
                time.sleep(min(60, 2 * (2 ** _att))); continue
            print(f"    haiku err: {e}")
            return None
        except Exception as e:
            if _att < 5:
                time.sleep(min(60, 2 * (2 ** _att))); continue
            print(f"    haiku err: {e}")
            return None
    try:
        text = resp.get("content", [{}])[0].get("text", "")
        m = re.search(r"\{[\s\S]*\}", text)
        if not m:
            return None
        return json.loads(m.group(0))
    except Exception as e:
        print(f"    haiku err: {e}")
        return None


async def upsert_review(conn, msg_id: str, account: str, extracted: dict, raw_subject: str, source_hint=None):
    extracted = extracted or {}
    # A source_hint means we matched via an explicit per-source query, so trust it's a
    # review notification even if Haiku was unsure (Expedia mail is CSS-heavy, hard to parse).
    if not source_hint and not extracted.get("is_review_notification"):
        return "skip"
    source = source_hint or extracted.get("source")
    if source not in ("tripadvisor", "google", "expedia"):
        return "skip_source"
    location = extracted.get("location") or "malthouse"
    if location not in ("malthouse", "sandwich"):
        location = "malthouse"

    # review_id = stable hash. Expedia's subject is ALWAYS "You have a new review", so
    # include msg_id for expedia to avoid same-subject collisions. Keep the original seed
    # for other sources so their existing dedup keys (and rows) are unchanged.
    if source == "expedia":
        seed = f"expedia|{msg_id}|{extracted.get('reviewer_name','?')}|{raw_subject[:80]}"
    else:
        seed = f"{source}|{extracted.get('reviewer_name','?')}|{raw_subject[:80]}"
    review_id = hashlib.sha1(seed.encode()).hexdigest()[:32]

    # Never silently drop an Expedia review if Haiku couldn't extract the body.
    body_val = extracted.get("body_text")
    if source == "expedia" and not body_val:
        body_val = "Expedia review notification — open Partner Central to view details"

    await conn.execute("SET app.current_entity = 'all'")
    await conn.execute("SELECT home_ai.set_realm('work')")
    res = await conn.execute(
        """INSERT INTO guest_reviews
             (review_id, source, location, rating, reviewer_name, body,
              posted_at, review_url, raw_payload, status, realm, entity_id)
           VALUES ($1, $2, $3, $4, $5, $6, NOW(), $7, $8, 'new', 'work', 1)
           ON CONFLICT (source, review_id) DO UPDATE SET
             rating = EXCLUDED.rating,
             body   = COALESCE(EXCLUDED.body, guest_reviews.body),
             scraped_at = NOW()""",
        review_id, source, location, extracted.get("rating"),
        extracted.get("reviewer_name"), body_val,
        extracted.get("review_url"),
        json.dumps({"gmail_msg_id": msg_id, "account": account,
                    "subject": raw_subject, "extracted": extracted})
    )
    return "inserted" if "INSERT" in res else "updated"


async def main():
    conn = await asyncpg.connect(PG_DSN)
    summary = {"queries": 0, "msgs_seen": 0, "inserted": 0, "updated": 0,
               "skip": 0, "errors": 0}

    seen_msgs = set()

    for account, query_tmpl, source_hint in GMAIL_QUERIES:
        query = query_tmpl.format(d=DAYS_BACK)
        url = ("http://google-fetch:8011/messages?account=" + account
               + "&max_results=50&q=" + urllib.parse.quote(query))
        try:
            r = urllib.request.urlopen(url, timeout=20)
            o = json.loads(r.read())
            msgs = o.get("messages", [])
        except Exception as e:
            print(f"  query {account}: {e}")
            summary["errors"] += 1
            continue
        print(f"\n── {account} ({len(msgs)} msgs)")
        summary["queries"] += 1

        for m in msgs:
            mid = m["id"]
            if mid in seen_msgs:
                continue
            seen_msgs.add(mid)
            summary["msgs_seen"] += 1

            try:
                body = fetch_msg_body(account, mid)
            except Exception as e:
                print(f"  fetch {mid}: {e}")
                summary["errors"] += 1
                continue

            subject = body["subject"].lower()
            # Skip non-review-shaped subjects to save Haiku tokens
            if not any(k in subject for k in ("review", "rating", "bubble", "feedback")):
                summary["skip"] += 1
                continue

            extracted = haiku_extract(body)
            if not extracted:
                summary["errors"] += 1
                continue

            outcome = await upsert_review(conn, mid, account, extracted, body["subject"], source_hint)
            summary[outcome] = summary.get(outcome, 0) + 1
            print(f"  {mid}  {body['subject'][:70]} → {outcome}")

    print(f"\n== summary: {summary}")
    await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
