# Gmail OAuth — runbook for "robust in future"

## What failed (2026-05-16)

All 3 consumer-Gmail identities returned `invalid_grant: Token has been expired or revoked` from `oauth2.googleapis.com/token`:

- `jolyon.sandercock@gmail.com`
- `jolyboxbot@gmail.com`
- `pounana@gmail.com`

The 2 Workspace identities (`admin@malthousetintagel.com`, `info@malthousetintagel.com`) aren't in Vault yet — they go via the service account `sa-malthouse` with Domain-Wide Delegation (DWD) and don't have this failure mode.

## Why it failed

The Google Cloud project hosting the OAuth client is in **"Testing"** publishing status. Per Google's policy, refresh tokens issued by a Testing-status app **expire after 7 days**. No notification, no warning — just silent 400 on the next refresh.

Even after rotating tokens, this will fail again in 7 days unless the publishing status changes.

## The two-pronged fix

### A. Permanent fix — publish the OAuth app to "In production"

This survives 6 months per token (vs 7 days). For unverified apps using sensitive scopes (we use `gmail.modify` which is sensitive), Google shows a warning screen on first auth but issues durable tokens.

1. Google Cloud Console → APIs & Services → **OAuth consent screen**.
2. Confirm scopes match what `redo-google-oauth.sh rotate` sends: `gmail.modify`, `calendar`, `drive`, `spreadsheets`, `documents`.
3. Click **PUBLISH APP** (button changes the app from Testing → In production).
4. Confirm prompt. App can remain "unverified" — no verification submission required for our use (Jo is the only user).

### B. Workspace identities use DWD — they never have this problem

`admin@` and `info@` are `@malthousetintagel.com` (Google Workspace). The service account `sa-malthouse` can impersonate any Workspace user via DWD without per-user tokens.

To seed admin/info into Vault as Workspace-DWD identities:

```bash
# Generate creds file for an identity
cat > /tmp/google-admin.json <<EOF
{
  "email_address": "admin@malthousetintagel.com",
  "auth": "service_account",
  "impersonate_via": "sa-malthouse",
  "scopes": "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/spreadsheets https://www.googleapis.com/auth/documents"
}
EOF
docker cp /tmp/google-admin.json homeai-vault:/tmp/
docker exec -e VAULT_TOKEN=... homeai-vault vault kv put secret/google/admin @/tmp/google-admin.json
```

DWD must first be authorised in Google Workspace Admin Console (Security → Access and data control → API controls → Domain-wide delegation → Add new with the SA's client ID + scopes).

## Recovery now (Action B before Action A)

The immediate recovery for today is to rotate the 3 dead consumer tokens.

```bash
/home_ai/scripts/oauth/redo-google-oauth.sh diagnose     # confirm what's broken
/home_ai/scripts/oauth/redo-google-oauth.sh rotate bot   # interactive — paste code
/home_ai/scripts/oauth/redo-google-oauth.sh rotate jo
/home_ai/scripts/oauth/redo-google-oauth.sh rotate pounana
docker restart homeai-google-fetch
/home_ai/scripts/oauth/redo-google-oauth.sh diagnose     # verify OK
```

Each `rotate` prompts a URL — open it in a browser signed in as the matching mailbox, grant scopes, paste the one-time code back.

**THEN do Step A (publish app)** — otherwise we'll repeat this in 7 days.

## Monitoring

Add to cron so we get advance warning before a token dies (gives a week to act):

```cron
0 6 * * * /home_ai/scripts/oauth/redo-google-oauth.sh diagnose 2>&1 | grep -q FAIL && \
  bash /home_ai/.claude/scripts/notify-telegram.sh "Gmail OAuth token failed diagnose — run redo-google-oauth.sh rotate" "alert"
```

## Why we ended up here

We started with the OAuth app in Testing because Workspace verification needed a domain that was set up later. The 7-day expiry is silent — easy to miss. The app should have been promoted to "In production" the moment the bot account started sending real mail.

Once the app is published and `admin`/`info` are seeded via DWD, the only fragile surface is the 3 consumer accounts. Each gets a 6-month durable refresh token. The daily diagnose cron alerts ~30 days before any failure.
