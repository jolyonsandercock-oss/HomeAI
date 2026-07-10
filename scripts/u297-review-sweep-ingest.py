#!/usr/bin/env python3
"""u297-review-sweep-ingest.py — ingest the cloud review-sweep snapshot.

A daily cloud routine (review-sweep-cloud-fetch, 05:45 UTC) fetches the public
TripAdvisor/Expedia listings — which the host cannot reach (DataDome 403 at
IP/TLS level, verified 2026-07-05) — and force-pushes a single-file snapshot
to the `review-sweep` branch: data/review-sweep/latest.json. This script
(cron 07:15) fetches that branch and upserts missing reviews into
guest_reviews.

Dedup, two layers:
  1. review_id = '<src>-web-' + md5('<reviewer>|<title>')  (matches the manual
     2026-07-05 inserts; PG md5() == python hexdigest).
  2. web-vs-email overlap: the email pipelines insert anonymous rows for (only)
     top-rated reviews; a web review is skipped as a probable duplicate when an
     existing same-source row in the same month shares a 30-char text fragment.
     Skips are logged, never silent.

Usage: u297-review-sweep-ingest.py [--file PATH]   (--file = test without git)
"""
import hashlib
import json
import subprocess
import sys

REPO = "/home_ai"
REMOTE = "off-host-backup"
BRANCH = "review-sweep"
SNAPSHOT = "data/review-sweep/latest.json"
PREFIX = {"tripadvisor": "ta-web-", "expedia": "exp-web-", "google": "g-web-",
          "booking_com": "bk-web-"}
LISTING_URL = {
    ("tripadvisor", "restaurant"): "https://www.tripadvisor.co.uk/Restaurant_Review-g186245-d1536289",
    ("tripadvisor", "hotel"): "https://www.tripadvisor.co.uk/Hotel_Review-g186245-d677960",
    ("expedia", "hotel"): "https://www.expedia.co.uk/Tintagel-Hotels-The-Olde-Malthouse.h121330906.Hotel-Information",
    ("booking_com", "hotel"): "https://www.booking.com/reviews/gb/hotel/ye-olde-malthouse-inn.en-gb.html",
}


def psql(sql: str) -> str:
    r = subprocess.run(
        ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres",
         "-d", "homeai", "-v", "ON_ERROR_STOP=1", "-tA"],
        input=f"SET app.current_entity='all'; SET app.current_realm='owner';\n{sql}",
        capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        sys.exit(f"psql failed:\n{r.stderr}")
    return r.stdout.strip()


def esc(s):
    return (s or "").replace("'", "''")


def load_snapshot_draft() -> dict | None:
    """Primary delivery path since 2026-07-10: the cloud routine cannot push
    git branches (4 consecutive silent failures), so it now leaves the JSON
    snapshot as a Gmail DRAFT in Jo's account, subject 'review-sweep-snapshot'.
    Read the newest one via google-fetch (hop through homeai-bot-responder —
    the only container with google-fetch DNS reachability). Drafts accumulate
    one per day; newest wins."""
    py = (
        "import json, urllib.request, urllib.parse, base64, sys\n"
        "q = urllib.parse.urlencode({'account':'jo','q':'in:draft subject:review-sweep-snapshot','max_results':5})\n"
        "msgs = json.loads(urllib.request.urlopen('http://google-fetch:8011/messages?'+q, timeout=30).read())\n"
        "msgs = msgs.get('messages', msgs) or []\n"
        "if not msgs: print('NODRAFT'); sys.exit(0)\n"
        "newest = max(msgs, key=lambda m: int(m.get('internal_date') or 0))\n"
        "full = json.loads(urllib.request.urlopen(f\"http://google-fetch:8011/message/jo/{newest['id']}\", timeout=30).read())\n"
        "def body_text(p):\n"
        "    if p.get('mimeType','').startswith('text/plain') and p.get('body',{}).get('data'):\n"
        "        return base64.urlsafe_b64decode(p['body']['data'] + '=' * (-len(p['body']['data']) % 4)).decode('utf-8','replace')\n"
        "    for c in p.get('parts',[]) or []:\n"
        "        t = body_text(c)\n"
        "        if t: return t\n"
        "    return None\n"
        "t = body_text(full.get('payload', full))\n"
        "print(t if t else 'NOBODY')\n"
    )
    r = subprocess.run(["docker", "exec", "-i", "homeai-bot-responder", "python3", "-"],
                       input=py, capture_output=True, text=True, timeout=90)
    out = (r.stdout or "").strip()
    if r.returncode != 0 or not out or out in ("NODRAFT", "NOBODY"):
        print(f"draft path: {out or r.stderr.strip()[:120] or 'failed'}")
        return None
    # strip accidental markdown fences before parsing
    if out.startswith("```"):
        out = out.strip("`\n")
        out = out[out.find("{"):]
    try:
        snap = json.loads(out[out.find("{"):])
    except Exception as e:
        print(f"draft path: body not parseable JSON ({e})")
        return None
    return snap


def load_snapshot() -> dict:
    if len(sys.argv) > 2 and sys.argv[1] == "--file":
        return json.load(open(sys.argv[2]))
    snap = load_snapshot_draft()
    if snap is not None:
        print("snapshot source: gmail draft")
        return snap
    # legacy fallback: the git branch relay (never worked from the cloud env,
    # kept in case delivery moves back to git)
    f = subprocess.run(["git", "-C", REPO, "fetch", REMOTE, BRANCH],
                       capture_output=True, text=True, timeout=120)
    if f.returncode != 0:
        print(f"no snapshot delivered yet (no draft, no {BRANCH} branch on {REMOTE})")
        print("OPS_ROWS=0")
        sys.exit(0)
    s = subprocess.run(["git", "-C", REPO, "show", f"FETCH_HEAD:{SNAPSHOT}"],
                       capture_output=True, text=True, timeout=30)
    if s.returncode != 0:
        sys.exit(f"snapshot file missing on branch: {s.stderr.strip()}")
    print("snapshot source: git branch")
    return json.loads(s.stdout)


def month_date(d):
    if not d:
        return None
    d = str(d).strip()
    if len(d) == 7:            # YYYY-MM -> mid-month convention
        return f"{d}-15"
    return d[:10]


def main():
    snap = load_snapshot()
    inserted = skipped_id = skipped_dup = bad = 0
    for listing in snap.get("listings", []):
        src = listing.get("source")
        if listing.get("status") != "ok":
            print(f"listing {src}/{listing.get('listing')}: status={listing.get('status')} — skipped")
            continue
        url = LISTING_URL.get((src, listing.get("listing")), "")
        for rv in listing.get("reviews", []):
            reviewer, title = rv.get("reviewer"), rv.get("title")
            rating, text = rv.get("rating"), rv.get("text")
            if not isinstance(rating, (int, float)) or not (reviewer or title):
                bad += 1
                continue
            rid = PREFIX.get(src, f"{src}-web-") + hashlib.md5(
                f"{reviewer or ''}|{title or ''}".encode()).hexdigest()
            posted = month_date(rv.get("date"))
            if not posted:
                bad += 1
                continue
            body = f"{title} — {text}" if title and text else (text or title or "")
            frag = esc((text or title or "")[:30])
            exists = psql(f"SELECT 1 FROM guest_reviews WHERE review_id='{rid}' LIMIT 1;")
            if exists:
                skipped_id += 1
                continue
            # web-vs-email month+fragment overlap
            if len(frag) >= 15:
                dup = psql(f"""SELECT review_id FROM guest_reviews
                    WHERE source='{esc(src)}'
                      AND date_trunc('month', posted_at) = date_trunc('month', DATE '{posted}')
                      AND body ILIKE '%{frag}%' LIMIT 1;""")
                if dup:
                    skipped_dup += 1
                    print(f"  probable email-dup, skipped: {src} {reviewer!r} {rating} ~{posted} (matches {dup})")
                    continue
            psql(f"""INSERT INTO guest_reviews (review_id, source, location, rating,
                       reviewer_name, body, posted_at, scraped_at, status, entity_id,
                       realm, review_url, raw_payload)
                 VALUES ('{rid}', '{esc(src)}', 'malthouse', {int(rating)},
                       '{esc(reviewer)}', '{esc(body)}', DATE '{posted}', now(),
                       'drafted', 1, 'work', '{esc(url)}',
                       '{{"origin":"review-sweep-cloud","date_precision":"month"}}'::jsonb);""")
            inserted += 1
            scale = rv.get("scale") or 5
            top = (scale == 5 and rating >= 5) or (scale == 10 and rating >= 9)
            print(f"  {'NEW' if top else 'NEW-SUB-TOP'}: {src} {reviewer!r} {rating}/{scale} {posted} {(title or '')[:50]!r}")
    print(f"review-sweep ingest: inserted={inserted} known={skipped_id} email-dups={skipped_dup} unparseable={bad}")
    print(f"OPS_ROWS={inserted}")


if __name__ == "__main__":
    main()
