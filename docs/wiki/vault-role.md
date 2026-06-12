# Vault — what it holds, who reads it, what breaks when it seals

HashiCorp Vault (`homeai-vault`, :8200) is the single secret store: KV v2 under
`secret/` — service creds (postgres, postgres-roles, telegram, workforce,
caterbook, touchoffice, britishgas, trail), API keys (anthropic), OAuth tokens
(google identities), signing secrets (breakfast links, payload HMAC).

**Access patterns** (in order of preference):
1. Containers get a `VAULT_TOKEN` env at start and read over the internal
   network (`http://vault:8200/v1/secret/data/<path>`).
2. Host scripts harvest a token from a running container
   (`docker inspect … VAULT_TOKEN`) — never store tokens in files.
3. `start.sh` fetches infra secrets at compose-up and exports them for
   variable substitution (POSTGRES_PASSWORD etc.); a missing secret degrades
   loudly, not silently.
Some secrets are deliberately mirrored into `/home_ai/.env` (gitignored) for
compose/cron substitution — Vault stays canonical; the mirror is convenience.

**Sealing is the system's single biggest failure mode** (2026-05-26 incident:
~80% of ingest silently dead). Mitigations now layered: age identity-file
autounseal; a host-level `vault-watchdog` systemd timer that pages Telegram on
seal-state change (host-level because the Telegram bot's own creds live in
Vault — the circular dependency is broken by keeping the watchdog outside the
container stack); n8n's token auto-renews (`vault-renewer`). Token TTL/renewal
gotchas: long-lived service tokens need `-self` renewal flags; psql/cron jobs
that cache a token must tolerate rotation.

Rule of thumb: if a pipeline silently produces nothing, check seal state
FIRST (`vault status`), then per-service tokens. Never write a secret to a
tracked file — the pre-push entropy scan exists because filename-based
ignores missed hex secrets in YAML once.
