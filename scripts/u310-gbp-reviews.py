#!/usr/bin/env python3
"""u310-gbp-reviews.py — pull Google reviews via the Google Business Profile API.

Replaces the dead u133 Google scraper stub (it pointed at a Google Travel
*search* page with no review content). Jo owns the Malthouse listing, so the
Business Profile API is the sanctioned, unblocked route — no DataDome, no
browser.

Runs INSIDE homeai-google-fetch (has Vault, googleapis egress, and PG_DSN —
the same container the Gmail path uses). Invoke via the wrapper
u310-gbp-reviews.sh, which passes VAULT_TOKEN.

Vault secret/gbp fields (set once by Jo — see the setup walkthrough):
    client_id, client_secret, refresh_token
Optional cache (this script writes them back after first discovery):
    account_name   e.g. 'accounts/1234567890'
    location_name  e.g. 'locations/0987654321'

Dedup: review_id = 'g-web-' + md5('<reviewer>|<comment[:40]>'), matching the
convention u297-review-sweep-ingest.py uses. Insert is INSERT..SELECT..WHERE
NOT EXISTS (guest_reviews has no unique constraint on review_id). READ-ONLY
against Google. Idempotent. Prints OPS_ROWS=<inserted> for the ops-run wrapper.
"""
import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

VT = os.environ["VAULT_TOKEN"]
PG_DSN = os.environ["PG_DSN"]
STAR = {"ONE": 1, "TWO": 2, "THREE": 3, "FOUR": 4, "FIVE": 5, "STAR_RATING_UNSPECIFIED": None}

TOKEN_URL = "https://oauth2.googleapis.com/token"
ACCTS_URL = "https://mybusinessaccountmanagement.googleapis.com/v1/accounts"
# reviews live on the legacy v4 endpoint (still the current path for reviews)
V4 = "https://mybusinessbusinessinformation.googleapis.com/v1"
REVIEWS_HOST = "https://mybusiness.googleapis.com/v4"


def vault_get(path):
    r = urllib.request.urlopen(urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{path}", headers={"X-Vault-Token": VT}), timeout=10)
    return json.loads(r.read())["data"]["data"]


def vault_put(path, data):
    urllib.request.urlopen(urllib.request.Request(
        f"http://vault:8200/v1/secret/data/{path}",
        data=json.dumps({"data": data}).encode(),
        headers={"X-Vault-Token": VT, "Content-Type": "application/json"},
        method="POST"), timeout=10)


def api_get(url, tok):
    r = urllib.request.urlopen(urllib.request.Request(
        url, headers={"Authorization": f"Bearer {tok}"}), timeout=30)
    return json.loads(r.read())


def access_token(c):
    body = urllib.parse.urlencode({
        "client_id": c["client_id"], "client_secret": c["client_secret"],
        "refresh_token": c["refresh_token"], "grant_type": "refresh_token"}).encode()
    r = urllib.request.urlopen(urllib.request.Request(TOKEN_URL, data=body, method="POST"), timeout=30)
    return json.loads(r.read())["access_token"]


def resolve_location(c, tok):
    """Return (account_name, location_name), using cached values when present."""
    acct = c.get("account_name")
    loc = c.get("location_name")
    if acct and loc:
        return acct, loc
    if not acct:
        accts = api_get(ACCTS_URL, tok).get("accounts", [])
        if not accts:
            sys.exit("no Business Profile accounts visible to this credential")
        acct = accts[0]["name"]
    if not loc:
        url = (f"{V4}/{acct}/locations"
               "?readMask=name,title&pageSize=100")
        locs = api_get(url, tok).get("locations", [])
        match = [l for l in locs if "malthouse" in (l.get("title", "").lower())]
        chosen = (match or locs)
        if not chosen:
            sys.exit(f"no locations under {acct}")
        loc = chosen[0]["name"]
        print(f"resolved location: {chosen[0].get('title')} ({loc})")
    # write-back cache so future runs skip discovery
    merged = {**c, "account_name": acct, "location_name": loc}
    vault_put("gbp", merged)
    return acct, loc


def fetch_reviews(acct, loc, tok):
    out, page = [], None
    while True:
        url = f"{REVIEWS_HOST}/{acct}/{loc}/reviews?pageSize=50"
        if page:
            url += f"&pageToken={page}"
        d = api_get(url, tok)
        out.extend(d.get("reviews", []))
        page = d.get("nextPageToken")
        if not page:
            break
    return out


def esc(s):
    return (s or "").replace("'", "''")


async def _run():
    import asyncpg
    try:
        c = vault_get("gbp")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print("secret/gbp not configured yet — Google Business Profile setup "
                  "pending (see the plan's Phase A walkthrough).")
            print("OPS_ROWS=0")
            return
        raise
    missing = [k for k in ("client_id", "client_secret", "refresh_token") if not c.get(k)]
    if missing:
        print(f"secret/gbp missing fields {missing} — setup incomplete.")
        print("OPS_ROWS=0")
        return
    tok = access_token(c)
    acct, loc = resolve_location(c, tok)
    reviews = fetch_reviews(acct, loc, tok)
    print(f"fetched {len(reviews)} Google reviews for {loc}")

    conn = await asyncpg.connect(PG_DSN)
    try:
        await conn.execute("SET app.current_entity='all'; SET app.current_realm='owner';")
        inserted = 0
        for rv in reviews:
            rating = STAR.get(rv.get("starRating"))
            reviewer = (rv.get("reviewer") or {}).get("displayName") or "Google user"
            comment = rv.get("comment") or ""
            posted = (rv.get("createTime") or "")[:10] or None
            rid = "g-web-" + hashlib.md5(f"{reviewer}|{comment[:40]}".encode()).hexdigest()
            url = "https://search.google.com/local/reviews?placeid=" + loc
            status = await conn.execute("""
                INSERT INTO guest_reviews (review_id, source, location, rating, reviewer_name,
                       body, posted_at, scraped_at, status, entity_id, realm, review_url, raw_payload)
                SELECT $1,'google','malthouse',$2,$3,$4,$5::date,now(),'drafted',1,'work',$6,
                       '{"origin":"gbp-api"}'::jsonb
                WHERE NOT EXISTS (SELECT 1 FROM guest_reviews WHERE review_id=$1);""",
                rid, rating, reviewer, comment, posted, url)
            inserted += 1 if status.endswith(" 1") else 0
    finally:
        await conn.close()
    print(f"google reviews: inserted={inserted} (of {len(reviews)} fetched)")
    print(f"OPS_ROWS={inserted}")


def main():
    import asyncio
    asyncio.run(_run())


if __name__ == "__main__":
    main()
