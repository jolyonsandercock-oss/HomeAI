I am maintaining the Home AI system. Read AGENTS.md and SPEC.md for full context.

We just completed a system-wide deep dive and found several issues. Start at the top of the priority list below, one item at a time. For each: read the relevant SPEC.md section, propose a fix before implementing, then execute.

---

## PRIORITY 1 — Vault is down

`docker compose ps` shows `homeai-vault` is not running, but `homeai-vault-agent` is up. The agent can't function without the server. All pipelines that fetch HMAC signing keys from Vault will fail.

Check: `docker compose logs homeai-vault --tail 100`
Likely cause: Vault is sealed after the last restart. Unseal it.

---

## PRIORITY 2 — PAYLOAD_HMAC_KEY is blank

`docker compose config` shows PAYLOAD_HMAC_KEY defaulting to a blank string across multiple services. Every event INSERT requires a valid HMAC-SHA256 signature (Section 2.2 of SPEC). With a blank key, signatures are either broken or bypassed.

Check: is the key set in `.env` or does it come from Vault? If from Vault, Priority 1 may fix this. If set directly, verify the value is non-empty and consistent across services.

---

## PRIORITY 3 — 58 dead letters + 28% event failure rate

Query run:
```
SELECT pipeline, COUNT(*) FROM dead_letter WHERE resolved=false GROUP BY pipeline;
-- All 58 from: stale_lease_recovery_v3

SELECT status, COUNT(*) FROM events GROUP BY status;
-- failed: 2,185 | pending: 148 | processing: 8 | processed: 5,512
```

Investigate root cause:
- Why is `stale_lease_recovery_v3` generating dead letters? Check the pipeline definition in n8n.
- Are the 8 `processing` events orphaned leases? If so, reset them to `pending`.
- Replay dead letters with `/replay-event` (Section 4.6 of SPEC).
- If Vault was down (Priority 1), that could be the root cause — pipelines can't sign payloads without the HMAC key.

---

## PRIORITY 4 — 6 stale data sources (8+ hours alerting)

The freshness watcher (`u165`) has been alerting every 15 minutes since 02:45 today. TouchOffice bridge log shows last data from May 15 — 20 days stale.

Check:
- TouchOffice scraper: `docker compose logs homeai-playwright --tail 50`
- Is the ICRTouch Z-report email still arriving? Check recent emails in the events table.
- Caterbook scraper: same check.
- If scrapers are failing, inspect the Playwright service and scraper scripts at `/home_ai/services/playwright/scrapers/touchoffice.py`

---

## PRIORITY 5 — 148 pending events (router may be stuck)

The Master Router polls every 30 seconds using `SELECT FOR UPDATE SKIP LOCKED` (Section 4.3 of SPEC). With 148 pending events and only 8 in processing, the router may not be running.

Check:
- `docker compose logs homeai-n8n --tail 50` — any errors?
- Is the Master Router workflow active? Check n8n UI or API.
- Check system.state: `SELECT value FROM static_context WHERE key='system.state';` — we saw it was `running` but `paused_at` still has a timestamp. Verify the router is actually claiming events.

---

## PRIORITY 6 — REDIS_PASSWORD unset

Redis is running without authentication on the Docker network. Any compromised container can read/write.

Set REDIS_PASSWORD in `.env` (or Vault) and update the Redis service config to require it.

---

## BONUS — Remove obsolete `version` from docker-compose.yml

Docker Compose warns: "the attribute `version` is obsolete, it will be ignored, please remove it." Remove the `version:` line from `/home_ai/docker-compose.yml`.

---

## Context for each step

- We're running on P620, Ubuntu 22.04, Docker Compose
- Vault is at `http://vault:8200` inside Docker network
- n8n is at `http://n8n:5678`
- Database: `postgres:5432`, database `homeai`, user `postgres`
- All secrets should be in Vault, not .env files
- Pipelines must be idempotent and HMAC-signed (SPEC 4.4)
- Never write secrets to files — Vault only (AGENTS.md build rules)

Work through priorities 1-6 in order. Propose a fix before implementing. Report back after each fix.
