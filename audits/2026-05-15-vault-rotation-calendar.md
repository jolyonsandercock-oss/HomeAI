# Vault rotation calendar

Generated 2026-05-15T20:33:13+01:00. Read-only.

Recommended rotation windows:
- 30d: API keys, OAuth tokens (`*api*`, `*token*`)
- 90d: Database passwords, admin passwords (`*password*`, `*admin*`, `*pw*`)
- 365d: Long-lived signing keys, HMAC keys, encryption keys (`*key*`, `*hmac*`, `*signing*`)

## Sorted by age (oldest first)

| secret/ path | created | last updated | age days | recommended window | next rotation due |
|---|---|---|---|---|---|
| telegram | 2026-05-01 | 2026-05-01 | 14 | 90 (default) | 76d |
| postgres | 2026-05-01 | 2026-05-01 | 14 | 90 (default) | 76d |
| encryption | 2026-05-01 | 2026-05-01 | 14 | 90 (default) | 76d |
| open-webui | 2026-05-01 | 2026-05-01 | 13 | 90 (default) | 77d |
| grafana | 2026-05-01 | 2026-05-01 | 13 | 90 (default) | 77d |
| n8n | 2026-05-05 | 2026-05-05 | 10 | 90 (default) | 80d |
| gmail/workspace | 2026-05-05 | 2026-05-06 | 9 | 90 (default) | 81d |
| signing | 2026-05-01 | 2026-05-08 | 7 | 365 (signing key) | 358d |
| redis | 2026-05-01 | 2026-05-08 | 7 | 90 (default) | 83d |
| postgres-roles | 2026-05-01 | 2026-05-08 | 7 | 90 (default) | 83d |
| gmail/personal1 | 2026-05-07 | 2026-05-08 | 7 | 90 (default) | 83d |
| anthropic | 2026-05-01 | 2026-05-08 | 7 | 90 (default) | 83d |
| google/sa-malthouse | 2026-05-09 | 2026-05-09 | 6 | 90 (default) | 84d |
| google/pounana | 2026-05-09 | 2026-05-09 | 6 | 90 (default) | 84d |
| google/oauth-client | 2026-05-09 | 2026-05-09 | 6 | 30 (API/token) | 24d |
| google/jo | 2026-05-09 | 2026-05-09 | 6 | 90 (default) | 84d |
| google/bot | 2026-05-09 | 2026-05-09 | 6 | 90 (default) | 84d |
| touchoffice | 2026-05-11 | 2026-05-11 | 4 | 90 (default) | 86d |
| searxng | 2026-05-11 | 2026-05-11 | 4 | 90 (default) | 86d |
| caterbook | 2026-05-11 | 2026-05-11 | 4 | 90 (default) | 86d |
| authelia/jwt | 2026-05-11 | 2026-05-11 | 4 | 90 (default) | 86d |
| authelia/encryption | 2026-05-11 | 2026-05-11 | 4 | 90 (default) | 86d |
| workforce | 2026-05-12 | 2026-05-12 | 3 | 90 (default) | 87d |
| sheets/cashing_up | 2026-05-12 | 2026-05-12 | 3 | 90 (default) | 87d |
| authelia/admin_initial | 2026-05-12 | 2026-05-12 | 3 | 90 (password) | 87d |
| samba/scanner | 2026-05-15 | 2026-05-15 | 0 | 90 (default) | 90d |
| paperless/webhook | 2026-05-15 | 2026-05-15 | 0 | 90 (default) | 90d |
| paperless/api | 2026-05-15 | 2026-05-15 | 0 | 30 (API/token) | 30d |
| paperless | 2026-05-15 | 2026-05-15 | 0 | 90 (default) | 90d |

## Summary

- Total Vault paths tracked: 29

_No rotation performed automatically — this is calendar-only. Use `vault kv put` with a new value when ready._
