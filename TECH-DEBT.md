# Home AI — Technical Debt & User Actions Tracker

> **SUPERSEDED (2026-07-02):** this file is a point-in-time tracker and is no
> longer the canonical debt list. Current tech debt is tracked by the R0-R5
> hygiene/hardening program; see `docs/TECH-DEBT-REVIEW-2026-06-20.md` for the
> reviewed baseline that program works from. Entries below are kept for
> history — do not add new items here without also reflecting them in the
> R0-R5 tracking.

Items that need user (Jo) attention — surfaced during build sessions. Updated by Claude Code each session. Items remain until resolved with `✓` prefix.

---

## Critical path (currently blocking work)

- [x] **nvidia-persistenced daemon won't start (build-dashboard GPU disabled)** *(surfaced 2026-05-23, resolved same day by host reboot)*
  - Reboot self-healed the daemon (active since 14:38 BST). GPU reservation restored on `build-dashboard`; `/api/hardware/vram-resident` confirmed returning live data. Root cause never diagnosed — flag for re-investigation if it recurs.

- [ ] **Vault sealed post-reboot** *(surfaced 2026-05-23, still active 2026-05-24)*
  - Bot/Telegram/email comms (`u29-instructions-poll`, `u33-bot-responder`, `u66-telegram-bot`) all fail at PG-password fetch because Vault is sealed. Cron logs show `Vault is sealed` 503s from vault-agent.
  - Action (Jo): `bash /home_ai/.claude/scripts/u13-vault-unseal.sh` (prompts for passphrase, feeds 3 keys).
  - Also blocks U225 T4b (Booking.com review email ingestion) and U221 (auto-unseal sprint).

- [ ] **U225 T4b — Booking.com review email ingestion** *(parked behind Vault unseal)*
  - Once Vault is up, write a poller (along the lines of `scripts/u29-instructions-poll.sh`) that pulls `noreply@booking.com` "Guest review for …" emails from the property mailbox, parses reviewer + rating + body via Haiku, INSERTs into `guest_reviews` with `source='booking_com'`. UI side already labels and lists Booking.com once data appears (see `app/comms/page.tsx`).



- [ ] **Gmail OAuth → Vault** *(blocks Step 11 activation)*
  - Goal: populate `secret/gmail/account1` with `oauth_client_id`, `oauth_client_secret`, `refresh_token`.
  - Action: follow `/home_ai/scripts/gmail-oauth-bootstrap.py` docstring. Google Cloud Console → enable Gmail API → create OAuth 2.0 Desktop client → download client_secret JSON → run script → paste printed `vault kv put` (with leading space).

- [ ] **Metabase admin + API key** *(blocks Step 12.4–12.7)*
  - Goal: an admin login + a Metabase API key in this session's env.
  - Action:
    1. Open `http://100.104.82.53:3000`. Complete wizard (or login if already done).
    2. Admin → Settings → Authentication → API Keys → Create. Group: Admin. Name: `step12-bootstrap`.
    3. In Claude Code: `! export MB_API_KEY=mb_...`
  - Notes: stash admin password in your password manager; don't paste it here.

---

## Operational

- [ ] **Recreate Metabase container to apply `MB_AI_FEATURES_ENABLED=false`**
  - Why: the env var is in `docker-compose.yml` but the live container was started before it was added. `docker restart` reuses frozen env; needs full recreate.
  - Action: next `./start.sh` will pick it up automatically. No standalone work needed.

- [ ] **n8n container has no host port mapping (`5678/tcp` only)**
  - Why: surfaced in Step 10 — container shows only `5678/tcp` not `0.0.0.0:5678->5678/tcp`. n8n is reachable via Docker network IP and via Caddy on Tailscale, but not via `localhost:5678` from the host.
  - Likely cause: container was started without compose's full mapping at some point.
  - Action: next `./start.sh` should recreate with the full mapping. If not, recreate manually: `docker compose up -d --force-recreate n8n` (after exporting all required env vars).

- [ ] **Master Router pre-activation check** *(this session 2026-05-06)*
  - Patched master-router.json to `SET LOCAL app.current_entity='all'` for events queries (RLS would otherwise return 0 rows). Re-imported.
  - Action when activating: confirm it claims real events on the first tick after Step 11 starts emitting.

---

## Phase 2+ (planned, do not slip)

- [ ] **rent_payments RLS policy** — table has RLS enabled with no policy = deny-all. Needs a JOIN-based policy via `tenancy_id → tenancies.entity_id` (or denormalised `entity_id` column) before rent pipeline build. Surfaced 2026-05-03.

- [ ] **`init_placeholder` HMAC bug** — `static_context_change` trigger writes `payload_signature='init_placeholder'` instead of real HMAC-SHA256. Violates the "always sign" build rule. Needs dedicated fix step (touches RLS-bypassing code paths — do not patch inline).

- [ ] **Vault auto-unseal** — `vault-autounseal.sh` + systemd. Phase 2 hardening.

- [ ] **Vault root token rotation + AppRole migration** — current setup uses long-lived root token. Replace with scoped tokens or AppRole. Includes rotating the n8n `vault-token-header` credential (id `0wPA4DCDuehPC9Mf`) once AppRole lands.

- [ ] **start.sh `--profile phase2`** — when Phase 2 services come online (garmin, etc.), add `VAULT_SERVICES_TOKEN` issuance and a profile flag.

- [ ] **Orphaned Vault key** — `secret/postgres-roles/metabase_db` (old, superseded by `metabase_app`). Remove once nothing references the old `METABASE_DB_PASSWORD` env var name.

- [ ] **Pin remaining `:latest` Docker images** — `postgres:latest`, `n8nio/n8n:latest`, `metabase/metabase:latest`, `grafana/grafana:latest`. Tracked separately in TaskList — Claude will draft pinned versions; user reviews and triggers recreate via start.sh.

- [ ] **Account / API registration tasks** *(from STRETCH §4)*:
  - NatWest Open Banking (1–2 week registration)
  - RBS Open Banking
  - Dext API key (api.dext.com)
  - GitHub PAT (Phase 5)
  - ICRTouch PLU per-flavour configuration in TouchOffice (Phase 2 Ice Cream Oracle)
  - WhatsApp blacklist numbers populated to static_context (Phase 4)
  - Garmin connectivity smoke test (creds already in Vault)

---

## Resolved this session (2026-05-06)

- ✓ **Step 10 — Master Router imported** (workflow `4Tyj7ImxpkZZmitf`, inactive). Credential id refreshed to live `iTuuNfsqHY49MGhk`. SET LOCAL patch applied.
- ✓ **Metabase `MB_AI_FEATURES_ENABLED: "false"`** added to docker-compose.yml (effective on next start.sh recreate).
- ✓ **Gmail OAuth bootstrap helper** at `/home_ai/scripts/gmail-oauth-bootstrap.py`.
