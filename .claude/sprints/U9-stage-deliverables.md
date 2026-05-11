# Sprint U9 — Google Identity Foundation — CLOSED 2026-05-09

## ✓ Stages A–D complete

| Stage | Outcome |
|---|---|
| **A** Cloud Console | Project `homeai-495817`, OAuth client `371924275288-...`, service account `homeai-malthouse-dwd@homeai-495817.iam.gserviceaccount.com` (numeric ID `115578826670030318569`), 5 APIs enabled, 3 test users (jo/pounana/bot) |
| **B** Workspace DWD | SA Client ID `115578826670030318569` granted 5 scopes in admin.google.com; verified by impersonating info@ AND admin@ |
| **C** 3 consumer OAuth | Refresh tokens stored at `secret/google/{jo,pounana,bot}`; `/me` verified per account |
| **D** Migration + service | V21 applied (account rename, CHECK constraint, static_context, google_api_calls); Gmail Poller patched (`personal1` → `jo`); `homeai-google-fetch` Python sidecar deployed and verified end-to-end with all 5 identities |

## Live state
- 16 active Docker services (was 15; +`homeai-google-fetch`)
- `static_context.gmail.accounts` — 5 active identities
- `static_context.gmail.aliases` — 4 (kitchen@, cafe@, work@, invoices@)
- `static_context.email_routing` — 3 patterns (TouchOffice/ICRTouch/Caterbook)
- Selftest 52/52 PASS

## Vault paths
| Path | Contents |
|---|---|
| `secret/google/oauth-client` | Shared OAuth 2.0 client (id + secret) |
| `secret/google/jo` | Jolyon refresh_token + scopes |
| `secret/google/pounana` | Pounana refresh_token + scopes |
| `secret/google/bot` | jolyboxbot refresh_token + scopes |
| `secret/google/sa-malthouse` | Service account JSON for DWD |
| `secret/gmail/personal1` (legacy) | Old Jo OAuth — to be deleted after U10 |

## Scripts produced
| Script | Use |
|---|---|
| `/home_ai/.claude/scripts/store-google-identity.sh` | One-shot Vault writes for OAuth client + SA JSON |
| `/home_ai/.claude/scripts/verify-google-vault.sh` | Field-presence check + extract non-secret fields |
| `/home_ai/.claude/scripts/dwd-probe.sh` | Test DWD impersonation for any malthouse address |
| `/home_ai/.claude/scripts/google-oauth-bootstrap.py` | Run OAuth dance for 3 consumer accounts in one sitting |
| `/home_ai/.claude/scripts/test-google-tokens.sh` | Validate all 5 identities by hitting Gmail API |
| `/home_ai/.claude/scripts/restart-and-probe-google-fetch.sh` | One-shot recreate google-fetch + 5-account probe |

## Service: homeai-google-fetch
- **Image:** `home_ai-google-fetch:latest` (FastAPI + google-auth + google-api-python-client)
- **Networks:** ai-internal (postgres+vault), ai-egress (googleapis.com)
- **Endpoints:** `/healthz`, `/accounts`, `/messages?account=X`, `/message/<account>/<id>`
- **Token cache:** in-memory with TTL based on Google `expires_in`
- **Telemetry:** every API call → `google_api_calls` table

## Deferred to Sprint U10
- Multi-account Gmail Poller workflow (replace QMKzaCFrKBS4ewWm) — pure ingestion logic, hits google-fetch /messages + /message
- Cleanup of legacy `secret/gmail/personal1`
- Post-U10: build Calendar/Drive/Sheets/Docs use cases (digest enrichment, invoice file storage, cashing-up sheet, etc.)
