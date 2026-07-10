# Google reviews API — one-time setup (≈10 min, Jo)

The Google reviews sync (`scripts/u310-gbp-reviews.py`) is built and tested —
it's blocked only on a credential that has to be created under your Google
account, because it reads reviews for the listing **you** own. Everything below
is done once; after it, reviews sync automatically every morning.

## What you're creating
A refresh token that lets JolyBox read (only read) the Malthouse Google
Business Profile reviews via Google's official API — no scraping, no blocking.

## Steps

1. **Google Cloud Console** → https://console.cloud.google.com → create a
   project (or reuse one), then **APIs & Services → Library** → search
   **"Business Profile API"** → **Enable**. (If it asks you to request access,
   approve is instant for the account that manages the listing.)

2. **APIs & Services → OAuth consent screen** → User type **External** →
   fill app name "JolyBox" + your email → **Add test user**:
   `jolyon.sandercock@gmail.com` (the account that manages the Malthouse
   listing) → Save. Scope needed: `.../auth/business.manage`.

3. **APIs & Services → Credentials → Create credentials → OAuth client ID** →
   type **Desktop app** → Create. Note the **Client ID** and **Client secret**.

4. **Get the refresh token.** Easiest path — Google's OAuth Playground:
   - https://developers.google.com/oauthplayground
   - Top-right gear ⚙ → tick **"Use your own OAuth credentials"** → paste the
     Client ID + secret from step 3.
   - Left panel: in "Input your own scopes" paste
     `https://www.googleapis.com/auth/business.manage` → **Authorize APIs** →
     sign in as the listing-manager Google account → allow.
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
