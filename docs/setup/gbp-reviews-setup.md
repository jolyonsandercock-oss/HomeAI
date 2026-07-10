# Google reviews API — one-time setup (≈10 min, Jo)

The Google reviews sync (`scripts/u310-gbp-reviews.py`) is built and tested —
it's blocked only on a credential that has to be created under the Google
account that **manages the listing**. Everything below is done once; after it,
reviews sync automatically every morning.

## ⚠️ Use the RIGHT Google account: admin@malthousetintagel.com
Verified 2026-07-10 from the Business Profile notification emails: **The Olde
Malthouse** listing is managed by **admin@malthousetintagel.com** (your
Workspace account). Do the whole OAuth flow below **signed in as admin@**.

- Do NOT use jolyon.sandercock@gmail.com — that personal account manages a
  *different* listing (Swirl Tintagel, the ice cream), so it would sync the
  wrong reviews.
- We checked the shortcut of using our existing service-account delegation for
  admin@ (like the Gmail sync uses): it's blocked — DWD isn't authorised for
  the Business Profile scope, and Google's Business Profile API doesn't accept
  service-account callers anyway. So OAuth-as-admin@ is the route. The setup
  script doesn't care which account the token belongs to — just generate it
  while signed in as admin@.

## What you're creating
A refresh token that lets JolyBox read (only read) the Malthouse Google
Business Profile reviews via Google's official API — no scraping, no blocking.

## Steps

1. **Google Cloud Console** → https://console.cloud.google.com → create a
   project (or reuse one), then **APIs & Services → Library** → search
   **"Business Profile API"** → **Enable**. (If it asks you to request access,
   approve is instant for the account that manages the listing.)

2. **APIs & Services → OAuth consent screen** → User type **Internal** (admin@
   is a Workspace account, so Internal keeps it simplest) → fill app name
   "JolyBox" + admin@ as contact → Save. Scope needed:
   `.../auth/business.manage`. (If Internal isn't offered, use External and add
   `admin@malthousetintagel.com` as a test user.)

3. **APIs & Services → Credentials → Create credentials → OAuth client ID** →
   type **Desktop app** → Create. Note the **Client ID** and **Client secret**.

4. **Get the refresh token.** Easiest path — Google's OAuth Playground:
   - https://developers.google.com/oauthplayground
   - Top-right gear ⚙ → tick **"Use your own OAuth credentials"** → paste the
     Client ID + secret from step 3.
   - Left panel: in "Input your own scopes" paste
     `https://www.googleapis.com/auth/business.manage` → **Authorize APIs** →
     **sign in as admin@malthousetintagel.com** → allow.
   - **Exchange authorization code for tokens** → copy the **Refresh token**.

5. **Send me the three values** (Client ID, Client secret, Refresh token) —
   reply to this session or drop them in the bank-page definitions box. I'll
   store them in Vault (`secret/gbp`), never in code, and run the first sync
   live so you can see the reviews land. From then on it's a daily 07:00 cron.

## What happens after
- First run auto-discovers your listing and caches it.
- Reviews land in `guest_reviews` (source=google), visible on the reviews
  dashboard alongside TripAdvisor/Booking/Expedia.
- The dead old Google scraper stub gets retired.

## Note
The Client secret and refresh token are sensitive — treat them like a password.
If you'd rather not paste them in chat, tell me and I'll set up a Vault write
path you can post them to directly.
